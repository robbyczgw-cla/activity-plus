import ActivityCore
import Foundation
import Observation
import UserNotifications

/// Everything that consumes the live stream besides the views: history, alerts, dev servers, volume.
@MainActor @Observable
final class AppServices {
    static let shared = AppServices()

    let history = HistoryStore()
    private(set) var alerts: [AppAlert] = []
    private(set) var projects = ProjectScanner.Result()
    private(set) var projectsScannedAt: Date?

    var alertSettings: AlertSettings {
        didSet {
            engine.settings = alertSettings
            if let data = try? JSONEncoder().encode(alertSettings) { UserDefaults.standard.set(data, forKey: "alertSettings") }
        }
    }

    @ObservationIgnored private let engine: AlertEngine
    @ObservationIgnored private let scanner = ProjectScanner()
    @ObservationIgnored private let scanQueue = DispatchQueue(label: "at.hifiteam.activityplus.projects", qos: .utility)
    @ObservationIgnored private var scanning = false
    @ObservationIgnored private var lastScan = Date.distantPast
    @ObservationIgnored private lazy var volume = AppVolumeController()

    private init() {
        let stored = UserDefaults.standard.data(forKey: "alertSettings").flatMap { try? JSONDecoder().decode(AlertSettings.self, from: $0) }
        let settings = stored ?? AlertSettings()
        alertSettings = settings
        engine = AlertEngine(settings: settings)
        alerts = Self.loadAlertLog()
    }

    var volumeController: AppVolumeController { volume }

    func attach(to monitor: Monitor) {
        history.prune()
        monitor.observers.append { [weak self] snapshot in
            MainActor.assumeIsolated { self?.handle(snapshot) }
        }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func handle(_ snapshot: SystemSnapshot) {
        history.record(snapshot)
        scanner.observe(snapshot.apps.flatMap(\.processes), at: snapshot.date)

        let fresh = engine.evaluate(snapshot)
        if !fresh.isEmpty {
            alerts.insert(contentsOf: fresh, at: 0)
            if alerts.count > 200 { alerts.removeLast(alerts.count - 200) }
            saveAlertLog()
            fresh.forEach(notify)
        }

        if Date().timeIntervalSince(lastScan) >= 5 { scanProjects(snapshot) }
    }

    func scanProjects(_ snapshot: SystemSnapshot? = nil) {
        guard !scanning else { return }
        scanning = true
        lastScan = Date()
        let processes = (snapshot ?? Monitor.shared.snapshot).apps.flatMap(\.processes)
        let scanner = scanner
        scanQueue.async {
            let result = scanner.scan(processes)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.projects = result
                    self.projectsScannedAt = Date()
                    self.scanning = false
                }
            }
        }
    }

    func clearAlerts() {
        alerts = []
        saveAlertLog()
    }

    func ignore(appID: String) {
        alertSettings.ignoredApps.insert(appID)
    }

    // MARK: Notifications

    private func notify(_ alert: AppAlert) {
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.detail
        content.sound = .default
        content.threadIdentifier = alert.kind.rawValue
        let request = UNNotificationRequest(identifier: alert.id.uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private static var logURL: URL {
        supportFolder.appendingPathComponent("alerts.json")
    }

    private static var supportFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Activity+", isDirectory: true)
    }

    private static func loadAlertLog() -> [AppAlert] {
        guard let data = try? Data(contentsOf: logURL) else { return [] }
        return (try? JSONDecoder().decode([AppAlert].self, from: data)) ?? []
    }

    private func saveAlertLog() {
        if let data = try? JSONEncoder().encode(alerts) { try? data.write(to: Self.logURL, options: .atomic) }
    }
}
