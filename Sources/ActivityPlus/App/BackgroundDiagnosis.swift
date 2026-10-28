import ActivityCore
import AppKit
import Foundation
import Observation

/// Background diagnosis that needs no sampling of its own: slow moments found in the live samples, and the apps
/// macOS stopped, read from the unified log every 30 minutes.
@MainActor @Observable
final class BackgroundDiagnosis {
    static let shared = BackgroundDiagnosis()

    /// Bumped when a slow moment or new app stops were stored, so cards and History reload.
    private(set) var revision = 0
    private(set) var checkingStops = false
    /// When the system log was last read up to, and whether that worked.
    private(set) var stopsCheckedAt: Date? = UserDefaults.standard.object(forKey: "systemLog.checkedUntil") as? Date
    private(set) var stopsCheckFailed = false

    @ObservationIgnored private var detector = SlowMomentDetector()
    @ObservationIgnored private weak var services: AppServices?
    @ObservationIgnored private var stopsTimer: Timer?
    @ObservationIgnored private var started = false

    /// Snapshots and tests use a throwaway history and must not spend minutes reading the system log.
    /// Settings → Performance can switch it off: the first read costs a minute or more of CPU.
    private var readsSystemLog: Bool {
        ProcessInfo.processInfo.environment["ACTIVITYPLUS_SNAPSHOTS"] == nil
            && ProcessInfo.processInfo.environment["ACTIVITYPLUS_HISTORY_DB"] == nil
            && (UserDefaults.standard.object(forKey: "perf.systemLog") as? Bool ?? true)
    }

    func start(services: AppServices) {
        guard !started else { return }
        started = true
        self.services = services
        Monitor.shared.observers.append { [weak self] snapshot in
            MainActor.assumeIsolated { self?.observe(snapshot) }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.finishMoment() }
        }
        guard readsSystemLog else { return }
        // First look a little after launch, then every 30 minutes; each look reads only what is new.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(90))
            self?.checkStops()
        }
        stopsTimer = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkStops() }
        }
    }

    // MARK: Slow moments

    private func observe(_ snapshot: SystemSnapshot) {
        let hanging = services?.hangs.current.values.map { (id: $0.bundleID ?? $0.name, name: $0.name) } ?? []
        if let moment = detector.observe(snapshot, hanging: hanging) { store(moment) }
    }

    private func finishMoment() {
        if let moment = detector.close() { store(moment) }
    }

    private func store(_ moment: SlowMoment) {
        services?.history.recordSlowMoment(moment)
        revision += 1
    }

    // MARK: Apps macOS stopped

    /// Reads the system log since the last look (at most 24 hours back) in the background.
    func checkStops() {
        guard let services, !checkingStops else { return }
        checkingStops = true
        let store = services.history
        let since = (stopsCheckedAt ?? .distantPast).addingTimeInterval(-60)
        let started = Date()
        Task.detached(priority: .background) {
            let stops = AppStops.read(since: since, timeout: 600)
            if let stops { store.recordAppStops(stops) }
            await MainActor.run {
                self.checkingStops = false
                self.stopsCheckFailed = stops == nil
                guard let stops else { return }
                self.stopsCheckedAt = started
                UserDefaults.standard.set(started, forKey: "systemLog.checkedUntil")
                if !stops.isEmpty { self.revision += 1 }
            }
        }
    }

    /// A readable name: the app for an app or one of its helpers, the service name otherwise.
    static func displayName(_ stop: AppStop) -> String {
        if let host = stop.hostBundleID { return appName(bundleID: host) ?? AppStops.shortName(host) }
        if stop.kind == .app { return appName(bundleID: stop.identifier) ?? stop.name }
        return stop.name
    }

    /// "web content", "a helper (…)" for stops of an app's helper process.
    static func helperNote(_ stop: AppStop) -> String? {
        guard stop.hostBundleID != nil else { return nil }
        if stop.name.localizedCaseInsensitiveContains("WebContent") { return String(localized: "a web page") }
        if stop.name.localizedCaseInsensitiveContains("GPU") { return String(localized: "its graphics helper") }
        return String(localized: "its helper \(stop.name)")
    }

    static func appName(bundleID: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    static func icon(_ stop: AppStop) -> NSImage? {
        guard let id = stop.hostBundleID ?? (stop.kind == .app ? stop.identifier : nil),
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}

/// A moment the History page should show when it opens next (set by "Slow moments" on the Diagnosis page).
@MainActor
enum HistoryFocus {
    static var pending: Date?

    /// The shortest range that still contains the date.
    static func range(for date: Date) -> HistoryStore.Range {
        let age = Date().timeIntervalSince(date)
        return HistoryStore.Range.allCases.first { age < $0.seconds * 0.95 } ?? .days30
    }
}
