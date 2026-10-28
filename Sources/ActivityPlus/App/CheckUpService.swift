import ActivityCore
import AppKit
import Foundation
import Observation
import UserNotifications

/// The scheduled Mac check-up: gathers in the background, keeps the latest report, sends one notification.
/// It only looks. Nothing is ticked, moved to the Trash, quit or changed.
///
/// ACTIVITYPLUS_CHECKUP_NOW=1 runs one check-up a few seconds after launch (and notifies), without touching the
/// saved schedule state, so testing never shifts the real schedule.
@MainActor @Observable
final class CheckUpService {
    static let shared = CheckUpService()

    static let frequencyKey = "checkupFrequency"
    static let timeKey = "checkupTime"
    static let lastRunKey = "checkupLastRun"

    private(set) var report: CheckUpReport?
    private(set) var running = false

    @ObservationIgnored private let launchedAt = Date()
    @ObservationIgnored private var lastAttempt = Date.distantPast

    private static var debugNow: Bool { ProcessInfo.processInfo.environment["ACTIVITYPLUS_CHECKUP_NOW"] != nil }
    /// Snapshot and debug runs share their defaults with the installed app, so they leave the schedule alone.
    private static var leavesScheduleAlone: Bool { debugNow || SnapshotRunner.isActive }

    private init() {
        report = CheckUpReport.load(from: Self.reportURL)
    }

    // MARK: Schedule

    static var schedule: CheckUpSchedule {
        let defaults = UserDefaults.standard
        let frequency = defaults.string(forKey: frequencyKey).flatMap(CheckUpFrequency.init(rawValue:)) ?? .weekly
        let minute = defaults.object(forKey: timeKey) as? Int ?? CheckUpSchedule.defaultMinuteOfDay
        return CheckUpSchedule(frequency: frequency, minuteOfDay: minute)
    }

    static var lastRun: Date? {
        let seconds = UserDefaults.standard.double(forKey: lastRunKey)
        return seconds > 0 ? Date(timeIntervalSince1970: seconds) : nil
    }

    /// Called once from AppServices.
    func start() {
        guard Self.debugNow else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            self.run(scheduled: true)
        }
    }

    /// Called about once a minute with the other slow work. Runs a check-up that is due, also one missed while the Mac was off.
    func tick() {
        guard !Self.leavesScheduleAlone, !running else { return }
        let schedule = Self.schedule
        guard schedule.frequency != .off else { return }
        let now = Date()
        // Let the launch settle first; a check-up is never urgent.
        guard now.timeIntervalSince(launchedAt) > 90, now.timeIntervalSince(lastAttempt) > 3600 else { return }
        guard !ProcessInfo.processInfo.isLowPowerModeEnabled else { return }
        guard let last = Self.lastRun else {
            // First launch with the check-up on: count from now, so there is no check-up before the first Monday.
            UserDefaults.standard.set(now.timeIntervalSince1970, forKey: Self.lastRunKey)
            return
        }
        if schedule.isDue(lastRun: last, now: now) { run(scheduled: true) }
    }

    // MARK: Running

    func run(scheduled: Bool = false) {
        guard !running else { return }
        running = true
        lastAttempt = Date()

        let services = AppServices.shared
        let snapshot = Monitor.shared.snapshot
        let diskIndex = services.diskIndex
        let source = Source(
            apps: services.storage,
            uptime: snapshot.uptime,
            drive: snapshot.drives.first { $0.isInternal && $0.nvmeHealth != nil },
            history: services.history,
            customRoot: diskIndex.customHome != nil,
            loadedIndex: diskIndex.selection == .home ? diskIndex.index : nil,
            loadedGrowth: diskIndex.selection == .home && !diskIndex.growth.isEmpty ? diskIndex.growth : nil,
            running: CleanupModel.currentRunningBundleIDs(),
            crashWindowDays: Self.schedule.frequency == .weekly || !scheduled ? 7 : 30,
            growthNewerThan: scheduled ? Self.lastRun : nil)

        Task.detached(priority: .utility) {
            let (input, notChecked) = Self.gather(source)
            let report = CheckUpReport(date: input.now, findings: CheckUp.findings(from: input), notChecked: notChecked)
            await MainActor.run { CheckUpService.shared.finish(report, scheduled: scheduled) }
        }
    }

    private func finish(_ report: CheckUpReport, scheduled: Bool) {
        self.report = report
        running = false
        if !Self.leavesScheduleAlone {
            try? report.save(to: Self.reportURL)
            UserDefaults.standard.set(report.date.timeIntervalSince1970, forKey: Self.lastRunKey)
        } else if let url = Self.debugReportURL {
            try? report.save(to: url)
        }
        if scheduled, !SnapshotRunner.isActive, let note = CheckUp.notification(for: report.findings) {
            let content = UNMutableNotificationContent()
            content.title = note.title
            content.body = note.body
            content.threadIdentifier = "checkup"
            content.userInfo = ["checkup": true]
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "checkup", content: content, trigger: nil))
        }
    }

    // MARK: Gathering

    /// What the background work needs from the main actor, captured up front.
    private struct Source: @unchecked Sendable {
        var apps: [AppDiskUsage]
        var uptime: TimeInterval
        var drive: DriveInfo?
        var history: HistoryStore
        var customRoot: Bool
        var loadedIndex: DiskIndex?
        var loadedGrowth: [DiskGrowth.Summary]?
        var running: Set<String>
        var crashWindowDays: Int
        /// A scheduled run mentions growth only when a newer map exists than at the last check-up.
        var growthNewerThan: Date?
    }

    private nonisolated static func gather(_ source: Source) -> (CheckUpInput, [String]) {
        var input = CheckUpInput()
        var notChecked: [String] = []
        input.uptime = source.uptime
        input.crashWindowDays = source.crashWindowDays

        // Space: the same sources as Clean up. Large files come from the cached map; a new home scan is never started.
        var entries = CleanupPlan.entries(from: SystemDataBreakdown.measure()) + CleanupPlan.macOSInstallers()
            + CleanupPlan.entries(fromApps: source.apps)
        var map = source.loadedIndex
        var summaries = source.loadedGrowth
        if map == nil, !source.customRoot {
            let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
            map = DiskIndex.load(from: DiskIndexModel.homeCacheURL).flatMap { $0.root.standardizedFileURL.path == home ? $0 : nil }
        }
        if summaries == nil, !source.customRoot, map != nil {
            summaries = DiskGrowth.History.load(from: DiskIndexModel.homeGrowthURL).summaries
        }
        if let map {
            // A test map (ACTIVITYPLUS_DISK_ROOT) is not the home folder: the scan would also read the real device backups.
            if !source.customRoot {
                entries += CleanupPlan.entries(from: LargeFilesScanner().scan(index: map, progress: { _, _ in }))
            }
        } else {
            notChecked.append(String(localized: "Large and old files and what grew were not checked: there is no size map of your home folder yet. Scan it once in Storage, Explore."))
        }
        let fileManager = FileManager.default
        let merged = CleanupPlan.merge(entries).filter { entry in
            entry.item.urls.contains { fileManager.fileExists(atPath: $0.path) } && !CleanupPlan.isBlocked(entry, running: source.running)
        }
        let safe = merged.filter { $0.item.safety == .safeToClear }
        input.reclaimableBytes = safe.reduce(0) { $0 + $1.item.bytes }
        input.reclaimableItems = safe.count
        let large = merged.filter { $0.section == .largeOld }
        input.lookFirstBytes = large.reduce(0) { $0 + $1.item.bytes }
        input.lookFirstItems = large.count

        // What grew between the last two maps.
        if let summaries, summaries.count >= 2, let latest = summaries.last {
            let older = summaries[summaries.count - 2]
            if source.growthNewerThan.map({ latest.date > $0 }) ?? true {
                input.growth = CheckUpInput.Growth(
                    since: older.date, totalDelta: Int64(clamping: latest.totalBytes) - Int64(clamping: older.totalBytes),
                    changes: DiskGrowth.changes(from: older, to: latest, limit: 5))
            }
        }

        input.crashes = CrashReports.summarize(CrashReports.scan(), now: input.now)
        input.backup = TimeMachine.read()
        input.security = SecurityStatus.read()
        input.orphanedStartupItems = StartupItemsScanner.scan().filter { $0.orphan != nil }.count
        if let health = source.drive?.nvmeHealth {
            let daily = source.history.dailyWrites(days: 7)
            input.ssdYearsLeft = SSDWear.projection(percentUsed: health.percentageUsed, dataWrittenTB: health.dataWrittenTB,
                                                    bytesPerDay: daily.bytesPerDay)?.yearsLeft
        }
        return (input, notChecked)
    }

    // MARK: Files

    private static var supportFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Activity+", isDirectory: true)
    }

    private static var reportURL: URL { debugReportURL ?? supportFolder.appendingPathComponent("checkup.json") }

    /// Test and snapshot runs with their own history database keep the report next to it, not in the real support folder.
    private static var debugReportURL: URL? {
        ProcessInfo.processInfo.environment["ACTIVITYPLUS_HISTORY_DB"].map {
            URL(fileURLWithPath: $0).deletingLastPathComponent().appendingPathComponent("checkup.json")
        }
    }
}
