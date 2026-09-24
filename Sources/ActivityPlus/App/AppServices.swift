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
        if Date().timeIntervalSince(lastSlowRefresh) >= 60 { refreshSlowData() }
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

    // MARK: Accessories, totals, navigation

    private(set) var accessories: [DeviceBattery] = []
    private(set) var today = HistoryStore.Totals()
    private(set) var week = HistoryStore.Totals()
    /// A page the main window should show next (set by the menu bar panel).
    var requestedPage: String?
    @ObservationIgnored private var lastSlowRefresh = Date.distantPast
    @ObservationIgnored private var lowBatteryWarned: [String: Date] = [:]

    /// Work that only needs doing about once a minute.
    private func refreshSlowData() {
        lastSlowRefresh = Date()
        let store = history
        let startOfDay = Calendar.current.startOfDay(for: Date())
        Task.detached(priority: .utility) {
            let devices = DeviceBatterySampler.sample()
            let today = store.totals(since: startOfDay)
            let week = store.totals(since: Date().addingTimeInterval(-7 * 86_400))
            await MainActor.run {
                self.accessories = devices
                self.today = today
                self.week = week
                self.warnAboutLowAccessories(devices)
            }
        }
    }

    private func warnAboutLowAccessories(_ devices: [DeviceBattery]) {
        guard alertSettings.enabled, alertSettings.systemAlerts else { return }
        for device in devices where device.lowest <= 15 {
            if let last = lowBatteryWarned[device.name], Date().timeIntervalSince(last) < 6 * 3600 { continue }
            lowBatteryWarned[device.name] = Date()
            let alert = AppAlert(date: Date(), kind: .accessory, appID: nil, appName: device.name,
                                 title: "\(device.name) is almost empty", detail: "\(device.lowest) % battery left.")
            alerts.insert(alert, at: 0)
            saveAlertLog()
            notify(alert)
        }
    }

    // MARK: Startup items & storage (extras)

    private(set) var startupItems: [StartupItem] = []
    private(set) var startupScannedAt: Date?
    private(set) var storage: [AppDiskUsage] = []
    private(set) var storageProgress: (fraction: Double, item: String)?
    private(set) var storageScannedAt: Date?
    @ObservationIgnored private var storageScanner: StorageScanner?

    func scanStartupItems() {
        Task.detached(priority: .utility) {
            let items = StartupItemsScanner.scan()
            await MainActor.run {
                self.startupItems = items
                self.startupScannedAt = Date()
            }
        }
    }

    func scanStorage() {
        guard storageProgress == nil else { return }
        let scanner = StorageScanner()
        storageScanner = scanner
        storageProgress = (0, "")
        Task.detached(priority: .utility) {
            let result = scanner.scan { fraction, item in
                Task { @MainActor in
                    if AppServices.shared.storageProgress != nil { AppServices.shared.storageProgress = (fraction, item) }
                }
            }
            await MainActor.run {
                self.storage = Self.deduplicated(result)
                self.storageProgress = nil
                self.storageScannedAt = Date()
            }
        }
    }

    /// Two copies of an app (e.g. two Godot versions) share one set of Library folders.
    /// Count each folder once, for the first (largest) app, and tell same-named apps apart by folder.
    static func deduplicated(_ apps: [AppDiskUsage]) -> [AppDiskUsage] {
        var seen: Set<String> = []
        let names = Dictionary(grouping: apps, by: \.name).filter { $0.value.count > 1 }.keys
        return apps.compactMap { app in
            var copy = app
            copy.locations = app.locations.filter { $0.kind == .bundle || seen.insert($0.path).inserted }
            guard !copy.locations.isEmpty else { return nil }
            if names.contains(app.name), let bundle = app.bundlePath {
                let folder = (bundle as NSString).deletingLastPathComponent.replacingOccurrences(of: NSHomeDirectory(), with: "~")
                let file = ((bundle as NSString).lastPathComponent as NSString).deletingPathExtension
                copy = AppDiskUsage(id: app.id, name: file == app.name ? "\(app.name) (\(folder))" : file,
                                    bundlePath: app.bundlePath, bundleID: app.bundleID, lastUsed: app.lastUsed, locations: copy.locations)
            }
            return copy
        }
        .sorted { $0.totalBytes > $1.totalBytes }
    }

    func cancelStorageScan() {
        storageScanner?.cancel()
    }

    /// Removes trashed locations from the cached results so the list updates without a rescan.
    func didTrash(_ paths: Set<String>) {
        storage = storage.map { app in
            var copy = app
            copy.locations.removeAll { paths.contains($0.path) }
            return copy
        }.filter { !$0.locations.isEmpty }
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
