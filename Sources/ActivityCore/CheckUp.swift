import Foundation

// The scheduled "Mac check-up": a calm look at the Mac that only reports. Nothing here cleans, quits or
// changes anything; every finding points to the page where the user can act on it.

/// How often the check-up runs.
public enum CheckUpFrequency: String, Codable, CaseIterable, Sendable {
    case off, weekly, biweekly, monthly

    public var title: String {
        switch self {
        case .off: String(localized: "Off")
        case .weekly: String(localized: "Weekly")
        case .biweekly: String(localized: "Every two weeks")
        case .monthly: String(localized: "Monthly")
        }
    }
}

/// When the check-up is due. Runs on Monday (the first Monday for "Monthly") at a chosen time; a Mac that was
/// off or asleep at that moment catches up the next time Activity+ is running.
public struct CheckUpSchedule: Sendable, Equatable {
    public var frequency: CheckUpFrequency
    /// Minutes after midnight, local time.
    public var minuteOfDay: Int

    public static let defaultMinuteOfDay = 9 * 60

    public init(frequency: CheckUpFrequency = .weekly, minuteOfDay: Int = CheckUpSchedule.defaultMinuteOfDay) {
        self.frequency = frequency
        self.minuteOfDay = min(max(minuteOfDay, 0), 24 * 60 - 1)
    }

    /// Two-weekly runs skip a Monday that comes less than this long after the last run.
    static let biweeklyGap: TimeInterval = 12 * 86_400

    private var components: DateComponents {
        var c = DateComponents()
        c.hour = minuteOfDay / 60
        c.minute = minuteOfDay % 60
        c.weekday = 2   // Monday
        return c
    }

    /// The first Monday of the month `monthOffset` months away from the one containing `date`, at the chosen time.
    private func firstMonday(monthOffset: Int, from date: Date, calendar: Calendar) -> Date? {
        guard let month = calendar.date(byAdding: .month, value: monthOffset, to: date) else { return nil }
        var c = calendar.dateComponents([.year, .month], from: month)
        (c.day, c.hour, c.minute) = (1, minuteOfDay / 60, minuteOfDay % 60)
        guard let first = calendar.date(from: c) else { return nil }
        let weekday = calendar.component(.weekday, from: first)   // 1 = Sunday
        return calendar.date(byAdding: .day, value: (2 - weekday + 7) % 7, to: first)
    }

    /// The most recent scheduled moment at or before `now`; nil when the check-up is off.
    public func latestSlot(now: Date, calendar: Calendar = .current) -> Date? {
        guard frequency != .off else { return nil }
        if frequency == .monthly {
            if let this = firstMonday(monthOffset: 0, from: now, calendar: calendar), this <= now { return this }
            return firstMonday(monthOffset: -1, from: now, calendar: calendar)
        }
        let probe = now.addingTimeInterval(1)   // `nextDate` is exclusive: a slot exactly at `now` counts
        return calendar.nextDate(after: probe, matching: components, matchingPolicy: .nextTime, direction: .backward)
    }

    /// True when a scheduled moment has passed since the last run. With no run on record it is not due:
    /// the caller starts counting from now instead of surprising a new user with a check-up at first launch.
    public func isDue(lastRun: Date?, now: Date, calendar: Calendar = .current) -> Bool {
        guard let slot = latestSlot(now: now, calendar: calendar), let lastRun else { return false }
        guard lastRun < slot else { return false }
        if frequency == .biweekly, slot.timeIntervalSince(lastRun) < Self.biweeklyGap { return false }
        return true
    }

    /// The next scheduled moment after `now` (and after the last run, with the two-week gap), for the Settings line.
    public func nextRun(lastRun: Date?, now: Date, calendar: Calendar = .current) -> Date? {
        guard frequency != .off else { return nil }
        var cursor = now
        for step in 0..<14 {
            let next: Date? = frequency == .monthly
                ? firstMonday(monthOffset: step, from: now, calendar: calendar)
                : calendar.nextDate(after: cursor, matching: components, matchingPolicy: .nextTime)
            guard let slot = next else { return nil }
            cursor = slot
            if slot <= now { continue }
            if let lastRun {
                if slot <= lastRun { continue }
                if frequency == .biweekly, slot.timeIntervalSince(lastRun) < Self.biweeklyGap { continue }
            }
            return slot
        }
        return nil
    }
}

/// One thing the check-up found, with where to deal with it.
public struct CheckUpFinding: Codable, Sendable, Identifiable, Equatable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case backup, security, crashes, ssd, trash, growth, largeFiles, startup, uptime
    }

    /// The page that handles the finding.
    public enum Destination: String, Codable, Sendable {
        case cleanUp, storage, diagnosis, startupItems, disk, overview

        /// Sidebar page key (see `SidebarItem.pages`).
        public var pageKey: String {
            switch self {
            case .cleanUp, .storage: "storage"
            case .diagnosis: "diagnosis"
            case .startupItems: "startup"
            case .disk: "metric:disk"
            case .overview: "overview"
            }
        }

        public var buttonTitle: String {
            switch self {
            case .cleanUp: String(localized: "Review in Clean up")
            case .storage: String(localized: "Open Storage")
            case .diagnosis: String(localized: "Open Why Is It Slow?")
            case .startupItems: String(localized: "Open Startup Items")
            case .disk: String(localized: "Open Disk")
            case .overview: String(localized: "Open Overview")
            }
        }
    }

    public var id: String { kind.rawValue }
    public let kind: Kind
    /// 0...100, higher first.
    public let score: Int
    /// One sentence for the card.
    public let title: String
    /// A line or two of evidence and what it means.
    public let detail: String
    /// A short phrase for the notification ("no backup for 9 days").
    public let summary: String
    public let destination: Destination

    public init(kind: Kind, score: Int, title: String, detail: String, summary: String, destination: Destination) {
        (self.kind, self.score, self.title, self.detail, self.summary, self.destination) = (kind, score, title, detail, summary, destination)
    }
}

/// Everything the check-up measured, as plain values. Gathering is done by the app; this type keeps the
/// decisions (what is worth mentioning, in which order, in which words) testable.
public struct CheckUpInput: Sendable {
    public struct Growth: Sendable {
        /// The earlier map the latest one was compared with.
        public var since: Date
        /// Growth of the whole mapped folder (negative: it shrank).
        public var totalDelta: Int64
        public var changes: [DiskGrowth.Change]
        public init(since: Date, totalDelta: Int64, changes: [DiskGrowth.Change]) {
            (self.since, self.totalDelta, self.changes) = (since, totalDelta, changes)
        }
    }

    /// Safe items (caches, logs, developer leftovers) of apps that are not open.
    public var reclaimableBytes: UInt64 = 0
    public var reclaimableItems = 0
    /// Large and old files, which are never ticked by default.
    public var lookFirstBytes: UInt64 = 0
    public var lookFirstItems = 0
    public var growth: Growth?
    public var crashes: [CrashSummary] = []
    /// 7 or 30: the window the crash counts are taken from.
    public var crashWindowDays = 7
    public var backup: TimeMachineInfo?
    public var security: [SecurityCheck] = []
    public var orphanedStartupItems = 0
    /// Years the internal SSD lasts at the current pace; nil when it cannot be projected.
    public var ssdYearsLeft: Double?
    public var uptime: TimeInterval = 0
    public var now = Date()

    public init() {}
}

/// The result of one run, as shown on the card and kept for the next launch.
public struct CheckUpReport: Codable, Sendable, Equatable {
    public var date: Date
    public var findings: [CheckUpFinding]
    /// Parts that could not be checked (no size map yet, for instance), in plain words.
    public var notChecked: [String]

    public init(date: Date, findings: [CheckUpFinding], notChecked: [String] = []) {
        (self.date, self.findings, self.notChecked) = (date, findings, notChecked)
    }

    public static func load(from url: URL) -> CheckUpReport? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(CheckUpReport.self, from: data)
    }

    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

public enum CheckUp {
    // Thresholds: below these a finding would be noise.
    static let minReclaimable: UInt64 = 1_000_000_000
    static let minLargeFiles: UInt64 = 2_000_000_000
    static let minGrowth: Int64 = 1_000_000_000
    static let minCrashes = 3
    static let staleBackupDays = 7
    static let longUptimeDays = 14
    static let ssdNotableYears = 5.0

    /// All findings worth mentioning, most useful first.
    public static func findings(from input: CheckUpInput) -> [CheckUpFinding] {
        let all = [backup(input), security(input), crashes(input), ssd(input), trash(input), growth(input),
                   largeFiles(input), startup(input), uptime(input)].compactMap { $0 }
        let order = CheckUpFinding.Kind.allCases
        return all.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            return (order.firstIndex(of: $0.kind) ?? 0) < (order.firstIndex(of: $1.kind) ?? 0)
        }
    }

    /// Title and body of the notification: the three most useful findings in one line.
    /// Nil when there is nothing to say (a calm check-up stays quiet).
    public static func notification(for findings: [CheckUpFinding]) -> (title: String, body: String)? {
        guard !findings.isEmpty else { return nil }
        let title = findings.count == 1
            ? String(localized: "Mac check-up: one thing to look at")
            : String(localized: "Mac check-up: \(findings.count) things to look at")
        let line = findings.prefix(3).map(\.summary).joined(separator: " · ")
        return (title, line.prefix(1).uppercased() + line.dropFirst())
    }

    /// "12 GB" rather than "12.0 GB" in running text.
    static func shortSize(_ bytes: UInt64) -> String {
        Format.storage(bytes).replacingOccurrences(of: #"[.,]0 "#, with: " ", options: .regularExpression)
    }

    // MARK: Individual checks

    private static func backup(_ input: CheckUpInput) -> CheckUpFinding? {
        guard let info = input.backup, !info.destinations.isEmpty, !info.needsFullDiskAccess, !info.progress.running else { return nil }
        let place = info.destinations.first?.name ?? String(localized: "Time Machine")
        guard let last = info.lastBackup else {
            return CheckUpFinding(kind: .backup, score: 95,
                                  title: String(localized: "Time Machine has not made a backup yet"),
                                  detail: String(localized: "A backup disk is set up (\(place)), but no backup is on record. Connect the disk and let the first one finish."),
                                  summary: String(localized: "no backup yet"), destination: .overview)
        }
        let days = TimeMachine.daysSince(last, now: input.now)
        guard days >= staleBackupDays else { return nil }
        var detail = String(localized: "The last Time Machine backup to \(place) was on \(last.formatted(date: .abbreviated, time: .omitted)).")
        if !info.destinationReachable { detail += " " + String(localized: "The backup disk is not connected.") }
        return CheckUpFinding(kind: .backup, score: days >= 30 ? 95 : 85,
                              title: String(localized: "No backup for \(days) days"), detail: detail,
                              summary: String(localized: "no backup for \(days) days"), destination: .overview)
    }

    private static func security(_ input: CheckUpInput) -> CheckUpFinding? {
        let encrypting = String(localized: "Encrypting")
        let off = input.security.filter { $0.level == .warning && $0.state != encrypting }
        guard !off.isEmpty else { return nil }
        // The firewall is off on a fresh Mac, so on its own it ranks below the others.
        let onlyFirewall = off.allSatisfy { $0.kind == .firewall }
        let score = onlyFirewall ? 50 : 80
        if off.count == 1, let check = off.first {
            let state = check.state.lowercased()
            return CheckUpFinding(kind: .security, score: score,
                                  title: String(localized: "\(check.title) is \(state)"), detail: check.detail,
                                  summary: String(localized: "\(check.title) is \(state)"), destination: .overview)
        }
        let names = off.map(\.title).formatted(.list(type: .and))
        return CheckUpFinding(kind: .security, score: score,
                              title: String(localized: "\(off.count) security checks are off"),
                              detail: String(localized: "\(names). The Security card on the Overview explains each one."),
                              summary: String(localized: "\(off.count) security checks are off"), destination: .overview)
    }

    private static func crashes(_ input: CheckUpInput) -> CheckUpFinding? {
        let window = input.crashWindowDays
        func count(_ s: CrashSummary) -> Int { window <= 7 ? s.crashes7 : s.crashes30 }
        let repeated = input.crashes.filter { count($0) >= minCrashes }.sorted { count($0) != count($1) ? count($0) > count($1) : $0.appName < $1.appName }
        guard let top = repeated.first else { return nil }
        let n = count(top)
        let score = 70 + min(n, 10)
        if repeated.count == 1 {
            return CheckUpFinding(kind: .crashes, score: score,
                                  title: String(localized: "\(top.appName) crashed \(n) times in the last \(window) days"),
                                  detail: top.lastReason + " " + String(localized: "Updating the app, or looking at its report, is a good start."),
                                  summary: String(localized: "\(top.appName) crashed \(n) times"), destination: .diagnosis)
        }
        let list = repeated.prefix(5).map { "\($0.appName) (\(count($0))×)" }.formatted(.list(type: .and))
        return CheckUpFinding(kind: .crashes, score: score,
                              title: String(localized: "\(repeated.count) apps crashed repeatedly in the last \(window) days"),
                              detail: list,
                              summary: String(localized: "\(top.appName) crashed \(n) times"), destination: .diagnosis)
    }

    private static func ssd(_ input: CheckUpInput) -> CheckUpFinding? {
        guard let years = input.ssdYearsLeft, years < ssdNotableYears else { return nil }
        let rounded = years < 1 ? String(localized: "under a year") : String(localized: "about \(Int(years.rounded())) years")
        return CheckUpFinding(kind: .ssd, score: years < 2 ? 75 : 45,
                              title: String(localized: "At the current pace the SSD lasts \(rounded)"),
                              detail: String(localized: "That is the point where the drive reaches its rated endurance, not the day it fails. The Disk page shows which apps write the most."),
                              summary: String(localized: "SSD wear: \(rounded) left at this pace"), destination: .disk)
    }

    private static func trash(_ input: CheckUpInput) -> CheckUpFinding? {
        guard input.reclaimableBytes >= minReclaimable else { return nil }
        let size = shortSize(input.reclaimableBytes)
        let gb = Int(input.reclaimableBytes / 1_000_000_000)
        return CheckUpFinding(kind: .trash, score: 40 + min(gb, 30),
                              title: String(localized: "\(size) could go to the Trash"),
                              detail: String(localized: "Caches, logs and developer leftovers of apps that are not open, \(input.reclaimableItems) items. Apps rebuild them by themselves. Nothing is ticked or moved until you choose it in Clean up."),
                              summary: String(localized: "\(size) could go to the Trash"), destination: .cleanUp)
    }

    private static func growth(_ input: CheckUpInput) -> CheckUpFinding? {
        guard let growth = input.growth, growth.totalDelta >= minGrowth else { return nil }
        let size = shortSize(UInt64(growth.totalDelta))
        let since = growth.since.formatted(date: .abbreviated, time: .omitted)
        let top = growth.changes.filter(\.grew).prefix(3).map { "\($0.path) (+\(Format.storage(UInt64($0.delta))))" }
        var detail = String(localized: "Since the size map of \(since), your files grew by \(size).")
        if !top.isEmpty { detail += " " + top.formatted(.list(type: .and)) + "." }
        return CheckUpFinding(kind: .growth, score: 35 + min(Int(growth.totalDelta / 1_000_000_000), 20),
                              title: String(localized: "Your home folder grew by \(size) since \(since)"), detail: detail,
                              summary: String(localized: "home folder grew by \(size)"), destination: .storage)
    }

    private static func largeFiles(_ input: CheckUpInput) -> CheckUpFinding? {
        guard input.lookFirstBytes >= minLargeFiles else { return nil }
        let size = shortSize(input.lookFirstBytes)
        let gb = Int(input.lookFirstBytes / 1_000_000_000)
        return CheckUpFinding(kind: .largeFiles, score: 30 + min(gb / 2, 10),
                              title: String(localized: "\(size) in large or old files"),
                              detail: String(localized: "\(input.lookFirstItems) items such as installers, old downloads and very large files. Check each one before you move it to the Trash; none is ticked."),
                              summary: String(localized: "\(size) in large or old files"), destination: .cleanUp)
    }

    private static func startup(_ input: CheckUpInput) -> CheckUpFinding? {
        let n = input.orphanedStartupItems
        guard n > 0 else { return nil }
        return CheckUpFinding(kind: .startup, score: 30,
                              title: String(localized: "\(n) leftover startup items"),
                              detail: String(localized: "Background items whose app or program is gone. They do nothing and only add entries to the log at every login. Startup Items shows each one."),
                              summary: String(localized: "\(n) leftover startup items"), destination: .startupItems)
    }

    private static func uptime(_ input: CheckUpInput) -> CheckUpFinding? {
        let days = Int(input.uptime / 86_400)
        guard days > longUptimeDays else { return nil }
        return CheckUpFinding(kind: .uptime, score: days > 30 ? 35 : 25,
                              title: String(localized: "Your Mac has not restarted in \(days) days"),
                              detail: String(localized: "A restart clears memory that apps have not given back and applies waiting updates."),
                              summary: String(localized: "up for \(days) days"), destination: .diagnosis)
    }
}
