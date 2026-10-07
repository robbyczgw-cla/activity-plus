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
        case done(GPUCauseAnalysis, Date, [String])
        case failed(String)
    }

    private(set) var state: State = .idle
    @ObservationIgnored private var task: Task<Void, Never>?
    /// Apps this run hid; shown again whatever happens (cancel, error, quit).
    @ObservationIgnored private var hiddenByUs: [NSRunningApplication] = []

    private static let baselineSeconds = 3.0
    private static let stepSeconds = 2.5
    private static let settleSeconds = 0.8
    nonisolated private static let maxApps = 12

    var isRunning: Bool { if case .running = state { true } else { false } }

    /// One app as the user knows it, with every process that owns one of its windows.
    struct Candidate {
        let name: String
        let bundleID: String?
        let processes: [NSRunningApplication]
    }

    /// Apps with at least one window on the current screen, largest windows first. Windows owned by
    /// helper processes (Steam's interface lives in "Steam Helper") count for the app responsible for them.
    static func candidates(limit: Int = maxApps) -> [Candidate] {
        let own = ProcessInfo.processInfo.processIdentifier
        let windows = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        var area: [pid_t: Double] = [:]
        var owners: [pid_t: Set<pid_t>] = [:]
        for window in windows {
            guard (window[kCGWindowLayer as String] as? Int) == 0,
                  let pid = window[kCGWindowOwnerPID as String] as? pid_t, pid != own,
                  let bounds = window[kCGWindowBounds as String] as? [String: Double]
            else { continue }
            let app = ProcessOwner.responsiblePID(for: pid).flatMap { $0 == own ? nil : $0 } ?? pid
            area[app, default: 0] += (bounds["Width"] ?? 0) * (bounds["Height"] ?? 0)
            owners[app, default: []].insert(pid)
        }
        return area.sorted { $0.value > $1.value }.compactMap { pid, _ -> Candidate? in
            let processes = ([pid] + (owners[pid] ?? [])).uniqued().compactMap { NSRunningApplication(processIdentifier: $0) }
                .filter { $0.activationPolicy != .prohibited && !$0.isHidden }
            guard !processes.isEmpty else { return nil }
            let main = NSRunningApplication(processIdentifier: pid)
            let name = main?.localizedName ?? processes[0].localizedName ?? "App"
            return Candidate(name: name, bundleID: main?.bundleIdentifier ?? processes[0].bundleIdentifier, processes: processes)
        }
        .prefix(limit).map { $0 }
    }

    /// Rough length of a run, for the confirmation dialog.
    static func estimatedSeconds(apps: Int) -> Int {
        Int(baselineSeconds + Double(apps + 1) * 2 * (stepSeconds + settleSeconds) + 1)
    }

    func start() {
        guard !isRunning else { return }
        task = Task { await run() }
    }

    func cancel() {
        task?.cancel()
    }

    /// Shows every app this run hid. Safe to call any time (also from applicationWillTerminate).
    /// `hide()` and `unhide()` report failure on macOS 27 even when they work, so their results are ignored.
    func restore() {
        for app in hiddenByUs where !app.isTerminated { app.unhide() }
    }

    /// Restores, then checks: an app still hidden gets activated, which always shows it.
    private func restoreAndVerify() async {
        restore()
        try? await Task.sleep(for: .seconds(0.4))
        for app in hiddenByUs where !app.isTerminated && app.isHidden {
            NSApp.yieldActivation(to: app)
            app.activate()
        }
        try? await Task.sleep(for: .seconds(0.3))
        hiddenByUs.removeAll { $0.isTerminated || !$0.isHidden }
    }

    private func run() async {
        let apps = Self.candidates()
        guard !apps.isEmpty else { state = .failed("No app has a window on this screen."); return }
        guard let server = GPUClientTime.snapshot().values.first(where: { $0.name == "WindowServer" })?.pid else {
            state = .failed("WindowServer's GPU time is not readable on this Mac.")
            return
        }
        let frontmost = NSWorkspace.shared.frontmostApplication
        let total = apps.count + 2
        var steps: [GPUCauseAnalysis.Step] = []
        var floor: Double?
        var cancelled = false

        do {
            state = .running(step: 1, total: total, label: "Measuring with every window visible")
            var visible = try await measure(server, seconds: Self.baselineSeconds)

            // Each app is compared with the measurement right before it, so a load that changes
            // during the run (an app that stays quiet after being shown again) does not blur the rest.
            for (index, app) in apps.enumerated() {
                state = .running(step: index + 2, total: total, label: "Hiding \(app.name)")
                let hidden = try await measureHidden(app.processes, server: server)
                let shownAgain = try await measure(server, seconds: Self.stepSeconds)
                steps.append(.init(name: app.name, bundleID: app.bundleID, before: visible, hidden: hidden, shownAgain: shownAgain))
                visible = shownAgain
            }

            state = .running(step: total, total: total, label: "Hiding all of them at once")
            floor = try await measureHidden(apps.flatMap(\.processes), server: server)
        } catch {
            cancelled = true
        }

        await restoreAndVerify()
        if let frontmost, !frontmost.isTerminated {
            NSApp.yieldActivation(to: frontmost)
            frontmost.activate()
        }
        task = nil

        if !hiddenByUs.isEmpty {
            let names = hiddenByUs.compactMap(\.localizedName).joined(separator: ", ")
            hiddenByUs = []
            state = .failed("Activity+ could not show these apps again: \(names). Click them in the Dock to bring them back.")
        } else if cancelled {
            state = .idle
        } else {
            let unmeasured = Self.candidates(limit: .max).filter { c in !apps.contains { $0.name == c.name } }.map(\.name)
            state = .done(GPUCauseAnalysis(steps: steps, floor: floor), Date(), unmeasured)
        }
    }

    /// Hides the processes, measures WindowServer, and shows them again.
    private func measureHidden(_ processes: [NSRunningApplication], server: pid_t) async throws -> Double {
        for app in processes where !app.isTerminated && !app.isHidden {
            app.hide()
            hiddenByUs.append(app)
        }
        defer { restore() }
        try await Task.sleep(for: .seconds(Self.settleSeconds))
        let hidden = try await measure(server, seconds: Self.stepSeconds)
        restore()
        try await Task.sleep(for: .seconds(Self.settleSeconds))
        return hidden
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

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
