import ActivityCore
import AppKit
import Observation

/// Finds the app behind WindowServer's GPU load: hides each app with visible windows for a moment,
/// measures how far WindowServer's GPU time drops, and shows everything again.
@MainActor @Observable
final class GPUCauseFinder {
    static let shared = GPUCauseFinder()

    enum State: Equatable {
        case idle
        case running(step: Int, total: Int, label: String)
        case done(GPUCauseAnalysis, Date)
        case failed(String)
    }

    private(set) var state: State = .idle
    @ObservationIgnored private var task: Task<Void, Never>?
    /// Apps this run hid; shown again whatever happens (cancel, error, quit).
    @ObservationIgnored private var hiddenByUs: [NSRunningApplication] = []

    private static let baselineSeconds = 3.0
    private static let stepSeconds = 2.5
    private static let settleSeconds = 0.8
    private static let maxApps = 10

    var isRunning: Bool { if case .running = state { true } else { false } }

    /// Regular apps with at least one window on the current screen, largest windows first.
    static func candidates() -> [NSRunningApplication] {
        let own = ProcessInfo.processInfo.processIdentifier
        let windows = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        var area: [pid_t: Double] = [:]
        for window in windows {
            guard (window[kCGWindowLayer as String] as? Int) == 0,
                  let pid = window[kCGWindowOwnerPID as String] as? pid_t, pid != own,
                  let bounds = window[kCGWindowBounds as String] as? [String: Double]
            else { continue }
            area[pid, default: 0] += (bounds["Width"] ?? 0) * (bounds["Height"] ?? 0)
        }
        return area.sorted { $0.value > $1.value }
            .compactMap { NSRunningApplication(processIdentifier: $0.key) }
            .filter { $0.activationPolicy == .regular && !$0.isHidden }
            .prefix(maxApps).map { $0 }
    }

    /// Rough length of a run, for the confirmation dialog.
    static func estimatedSeconds(apps: Int) -> Int {
        Int(2 * baselineSeconds + Double(apps + 1) * (stepSeconds + settleSeconds * 2) + 1)
    }

    func start() {
        guard !isRunning else { return }
        task = Task { await run() }
    }

    func cancel() {
        task?.cancel()
    }

    /// Shows every app this run hid. Safe to call any time (also from applicationWillTerminate).
    func restore() {
        for app in hiddenByUs where !app.isTerminated { app.unhide() }
        hiddenByUs = []
    }

    private func run() async {
        let apps = Self.candidates()
        guard !apps.isEmpty else { state = .failed("No app has a window on this screen."); return }
        guard let server = GPUClientTime.snapshot().values.first(where: { $0.name == "WindowServer" })?.pid else {
            state = .failed("WindowServer's GPU time is not readable on this Mac.")
            return
        }
        let frontmost = NSWorkspace.shared.frontmostApplication
        let total = apps.count + 3
        defer {
            restore()
            frontmost?.activate()
            task = nil
        }

        do {
            state = .running(step: 1, total: total, label: "Measuring with every window visible")
            let before = try await measure(server, seconds: Self.baselineSeconds)

            var steps: [GPUCauseAnalysis.Step] = []
            for (index, app) in apps.enumerated() {
                let name = app.localizedName ?? app.bundleIdentifier ?? "App"
                state = .running(step: index + 2, total: total, label: "Hiding \(name)")
                guard !app.isTerminated else { continue }
                hide([app])
                try await Task.sleep(for: .seconds(Self.settleSeconds))
                let hidden = try await measure(server, seconds: Self.stepSeconds)
                restore()
                try await Task.sleep(for: .seconds(Self.settleSeconds))
                steps.append(.init(name: name, bundleID: app.bundleIdentifier, hiddenPercent: hidden))
            }

            state = .running(step: total - 1, total: total, label: "Hiding all of them at once")
            hide(apps)
            try await Task.sleep(for: .seconds(Self.settleSeconds))
            let floor = try await measure(server, seconds: Self.stepSeconds)
            restore()
            try await Task.sleep(for: .seconds(Self.settleSeconds))

            state = .running(step: total, total: total, label: "Measuring again with every window visible")
            let after = try await measure(server, seconds: Self.baselineSeconds)

            state = .done(GPUCauseAnalysis(before: before, after: after, steps: steps, floor: floor), Date())
        } catch {
            state = .idle
        }
    }

    private func hide(_ apps: [NSRunningApplication]) {
        for app in apps where !app.isTerminated && !app.isHidden {
            if app.hide() { hiddenByUs.append(app) }
        }
    }

    private func measure(_ pid: pid_t, seconds: Double) async throws -> Double {
        let start = GPUClientTime.snapshot()
        let clock = ContinuousClock.now
        try await Task.sleep(for: .seconds(seconds))
        let elapsed = ContinuousClock.now - clock
        let end = GPUClientTime.snapshot()
        let actual = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        return GPUClientTime.percent(pid: pid, from: start, to: end, seconds: actual)
    }
}
