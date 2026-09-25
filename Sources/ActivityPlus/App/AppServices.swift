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
    /// Apps that stopped responding (beachball), from WindowServer's own flag.
    @ObservationIgnored let hangs = HangDetector()

    private init() {
        let stored = UserDefaults.standard.data(forKey: "alertSettings").flatMap { try? JSONDecoder().decode(AlertSettings.self, from: $0) }
        let settings = stored ?? AlertSettings()
        alertSettings = settings
        engine = AlertEngine(settings: settings)
        alerts = Self.loadAlertLog()
        loadAutomations()
    }

    var volumeController: AppVolumeController { volume }

    func attach(to monitor: Monitor) {
        hangs.onHangEnded = { [weak self] hang in
            // Short stutters happen all the time; only report real freezes.
            guard hang.duration >= 5 else { return }
            self?.record(AppAlert(date: Date(), kind: .hang, appID: nil, appName: hang.name,
                                  title: "\(hang.name) stopped responding",
                                  detail: "It froze for \(Int(hang.duration)) seconds at \(hang.started.formatted(date: .omitted, time: .shortened))."))
        }
        history.prune()
        monitor.observers.append { [weak self] snapshot in
            MainActor.assumeIsolated { self?.handle(snapshot) }
        }
        NotificationHandler.shared.install()
    }

    private func handle(_ snapshot: SystemSnapshot) {
        history.record(snapshot)
        // The scanner's state is only touched on its own queue (scan() runs there too).
        let scanner = scanner
        let processes = snapshot.apps.flatMap(\.processes)
        let date = snapshot.date
        scanQueue.async { scanner.observe(processes, at: date) }

        engine.evaluate(snapshot).forEach(record)

        if Date().timeIntervalSince(lastScan) >= 5 { scanProjects(snapshot) }
        runAutomations(snapshot)
        hangs.poll()
        if Date().timeIntervalSince(lastSlowRefresh) >= 60 {
            refreshSlowData()
            refreshInsights()
            notifyWeeklyReportIfDue()
        }
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
            record(AppAlert(date: Date(), kind: .accessory, appID: nil, appName: device.name,
                            title: "\(device.name) is almost empty", detail: "\(device.lowest) % battery left."))
        }
    }

    // MARK: Insights: unusual activity, leaks, weekly report

    private(set) var anomalies: [Anomaly] = []
    private(set) var leaks: [String: LeakForecast] = [:]
    @ObservationIgnored private var baselines: [String: HistoryStore.Baseline] = [:]
    @ObservationIgnored private var baselinesLoadedAt = Date.distantPast
    @ObservationIgnored private var insightNotified: [String: Date] = [:]

    private func refreshInsights() {
        let store = history
        if Date().timeIntervalSince(baselinesLoadedAt) > 1800 {
            baselinesLoadedAt = Date()
            // Normal = the last 7 days up to the start of today, so today's odd behavior does not become normal.
            let today = Calendar.current.startOfDay(for: Date())
            Task.detached(priority: .utility) {
                let loaded = store.baselines(from: today.addingTimeInterval(-7 * 86_400), to: today)
                await MainActor.run { self.baselines = loaded }
            }
        }
        let monitor = Monitor.shared
        var found = AnomalyDetector.detect(apps: monitor.snapshot.apps, baselines: baselines,
                                           recentCPU: monitor.history.appCPU.mapValues(\.values))

        // Leak forecast for the five biggest apps: 2 h of 5-minute averages plus the live value.
        let candidates = monitor.snapshot.apps.filter { $0.kind != .system }.sorted { $0.memory > $1.memory }.prefix(5)
        let since = Date().addingTimeInterval(-2 * 3600)
        var forecasts: [String: LeakForecast] = [:]
        for app in candidates {
            var points = store.appSeries(app.id, since: since).map { (date: $0.date, memory: $0.memory) }
            points.append((Date(), Double(app.memory)))
            if let forecast = LeakDetector.forecast(points) {
                forecasts[app.id] = forecast
                let perHour = Format.memory(UInt64(forecast.growthPerHour))
                let inTwoHours = Format.memory(UInt64(forecast.projected(hours: 2)))
                found.append(Anomaly(appID: app.id, appName: app.name, kind: .leak,
                                     title: "\(app.name) looks like it is leaking memory",
                                     detail: "It grows by about \(perHour) per hour and will be at \(inTwoHours) in 2 hours. Restarting it frees the memory.",
                                     factor: forecast.growthPerHour / 1e8))
            }
        }
        leaks = forecasts
        anomalies = found

        guard alertSettings.enabled else { return }
        for anomaly in found where !alertSettings.ignoredApps.contains(anomaly.appID) {
            if let last = insightNotified[anomaly.id], Date().timeIntervalSince(last) < 3 * 3600 { continue }
            insightNotified[anomaly.id] = Date()
            record(AppAlert(date: Date(), kind: anomaly.kind == .leak ? .leak : .unusual, appID: anomaly.appID,
                            appName: anomaly.appName, title: anomaly.title, detail: anomaly.detail))
        }
    }

    func weeklyReport(current: Bool = false) async -> WeeklyReport {
        let store = history
        let bounds = WeeklyReport.weekBounds(current: current)
        return await Task.detached(priority: .utility) {
            WeeklyReport.build(from: store, start: bounds.start, end: bounds.end)
        }.value
    }

    /// Monday from 9:00: one notification with last week's summary.
    private func notifyWeeklyReportIfDue() {
        let now = Date()
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = .current
        guard calendar.component(.weekday, from: now) == 2, calendar.component(.hour, from: now) >= 9,
              UserDefaults.standard.object(forKey: "weeklyReportEnabled") as? Bool ?? true else { return }
        let week = calendar.component(.weekOfYear, from: now)
        guard UserDefaults.standard.integer(forKey: "weeklyReportNotifiedWeek") != week else { return }
        UserDefaults.standard.set(week, forKey: "weeklyReportNotifiedWeek")
        Task {
            let report = await weeklyReport()
            guard !report.topEnergy.isEmpty else { return }
            record(AppAlert(date: Date(), kind: .weekly, appID: nil, appName: "Weekly report",
                            title: "Your Mac last week", detail: report.headline))
        }
    }

    /// Adds an alert to the log and shows it as a notification.
    func record(_ alert: AppAlert) {
        alerts.insert(alert, at: 0)
        if alerts.count > 200 { alerts.removeLast(alerts.count - 200) }
        saveAlertLog()
        notify(alert)
    }

    // MARK: Automations

    var automationRules: [AutomationRule] = [] {
        didSet {
            if let data = try? JSONEncoder().encode(automationRules) { UserDefaults.standard.set(data, forKey: "automationRules") }
        }
    }
    /// Matches waiting for the user's OK (also offered as notification buttons).
    private(set) var pendingAutomations: [AutomationMatch] = []
    private(set) var automationLog: [(date: Date, text: String)] = []
    @ObservationIgnored private let automationEngine = AutomationEngine()

    private func loadAutomations() {
        if let data = UserDefaults.standard.data(forKey: "automationRules"),
           let rules = try? JSONDecoder().decode([AutomationRule].self, from: data) {
            automationRules = rules
        }
    }

    private func runAutomations(_ snapshot: SystemSnapshot) {
        guard !automationRules.isEmpty else { return }
        let servers = projects.projects.flatMap(\.servers)
        for match in automationEngine.evaluate(automationRules, snapshot: snapshot, servers: servers) {
            if match.rule.mode == .automatic || match.rule.action == .notify {
                perform(match)
            } else {
                pendingAutomations.removeAll { $0.id == match.id }
                pendingAutomations.insert(match, at: 0)
                NotificationHandler.shared.askAboutAutomation(match)
            }
        }
    }

    func approve(_ matchID: String) {
        guard let match = pendingAutomations.first(where: { $0.id == matchID }) else { return }
        pendingAutomations.removeAll { $0.id == matchID }
        perform(match)
    }

    func dismiss(_ matchID: String) {
        pendingAutomations.removeAll { $0.id == matchID }
    }

    private func perform(_ match: AutomationMatch) {
        var done: String
        switch (match.rule.action, match.target) {
        case (.notify, _):
            done = match.reason
        case (.quitTriggeringApp, .app(let app)):
            ProcessActions.quit(app, force: false)
            done = "Asked \(app.name) to quit. \(match.reason)"
        case (.quitApp(let appID, let name), _):
            if let app = Monitor.shared.snapshot.apps.first(where: { $0.id == appID }) {
                ProcessActions.quit(app, force: false)
                done = "Asked \(name) to quit. \(match.reason)"
            } else {
                done = "\(name) was not running. \(match.reason)"
            }
        case (.stopDevServer, .server(let server)):
            ProjectScanner.stop(server)
            done = "Stopped \(server.command) and freed \(Format.memory(server.memory)). \(match.reason)"
            scanProjects()
        default:
            done = match.reason
        }
        automationLog.insert((Date(), done), at: 0)
        if automationLog.count > 100 { automationLog.removeLast() }
        record(AppAlert(date: Date(), kind: .automation, appID: nil, appName: "Automation",
                        title: match.rule.action == .notify ? match.rule.summary : "Automation ran", detail: done))
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
