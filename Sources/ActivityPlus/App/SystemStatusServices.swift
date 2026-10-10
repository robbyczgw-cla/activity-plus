import ActivityCore
import Foundation
import Observation

/// Time Machine state for the Backup card and the "no backup for a week" alert.
/// Read at launch, every 30 minutes, when the card appears, and every 10 s while a backup is running and the card is visible.
@MainActor @Observable
final class BackupWatcher {
    static let shared = BackupWatcher()

    private(set) var info: TimeMachineInfo?
    private(set) var readAt: Date?

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var reading = false
    @ObservationIgnored private var visible = 0
    @ObservationIgnored private weak var services: AppServices?
    @ObservationIgnored private var lastWarned: Date? = UserDefaults.standard.object(forKey: "backupWarnedAt") as? Date

    private init() {}

    /// Called once from AppServices; keeps the alert check going while the window is closed.
    func start(services: AppServices) {
        self.services = services
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func cardAppeared() {
        visible += 1
        if readAt.map({ Date().timeIntervalSince($0) > 60 }) ?? true { refresh() }
    }

    func cardDisappeared() { visible = max(0, visible - 1) }

    private func tick() {
        let since = readAt.map { Date().timeIntervalSince($0) } ?? .infinity
        let running = info?.progress.running ?? false
        if since >= 1800 || (running && visible > 0 && since >= 10) { refresh() }
    }

    func refresh() {
        guard !reading else { return }
        reading = true
        Task.detached(priority: .utility) {
            let result = TimeMachine.read()
            await MainActor.run {
                self.info = result
                self.readAt = Date()
                self.reading = false
                self.warnIfStale(result)
            }
        }
    }

    /// Off by default only through the system alerts switch: it is on in Settings → Alerts → "Low memory, full disk, overheating".
    private func warnIfStale(_ info: TimeMachineInfo) {
        guard let services, services.alertSettings.enabled, services.alertSettings.systemAlerts,
              TimeMachine.isStale(info), let last = info.lastBackup else { return }
        if let lastWarned, Date().timeIntervalSince(lastWarned) < 3 * 86_400 { return }
        lastWarned = Date()
        UserDefaults.standard.set(lastWarned, forKey: "backupWarnedAt")
        let days = TimeMachine.daysSince(last)
        let place = info.destinations.first?.name ?? String(localized: "Time Machine")
        services.record(AppAlert(date: Date(), kind: .backup, appID: nil, appName: String(localized: "Backup"),
                                 title: String(localized: "No backup for \(days) days"),
                                 detail: String(localized: "The last Time Machine backup to \(place) was \(days) days ago.")
                                     + (info.destinationReachable ? "" : " " + String(localized: "Connect the backup disk to continue."))))
    }
}

/// The four security checks. Read when the card appears, at most once a minute; they change rarely.
@MainActor @Observable
final class SecurityModel {
    static let shared = SecurityModel()

    private(set) var checks: [SecurityCheck] = []
    @ObservationIgnored private var readAt: Date?
    @ObservationIgnored private var reading = false

    private init() {}

    func refresh(force: Bool = false) {
        if !force, let readAt, Date().timeIntervalSince(readAt) < 60 { return }
        guard !reading else { return }
        reading = true
        Task.detached(priority: .utility) {
            let result = SecurityStatus.read()
            await MainActor.run {
                self.checks = result
                self.readAt = Date()
                self.reading = false
            }
        }
    }
}
