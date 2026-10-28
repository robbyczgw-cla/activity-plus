import Foundation
import Testing
@testable import ActivityCore

@Suite("Mac check-up")
struct CheckUpTests {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    // 2026-11-02 is a Monday.

    @Test func weeklyIsDueOnceAMondaySlotHasPassed() {
        let schedule = CheckUpSchedule(frequency: .weekly, minuteOfDay: 9 * 60)
        let lastRun = date(2026, 10, 26, 9, 1)
        #expect(!schedule.isDue(lastRun: lastRun, now: date(2026, 11, 2, 8, 59), calendar: calendar))
        #expect(schedule.isDue(lastRun: lastRun, now: date(2026, 11, 2, 9, 0), calendar: calendar))
        // The Mac was off on Monday: caught up on Wednesday.
        #expect(schedule.isDue(lastRun: lastRun, now: date(2026, 11, 4, 17, 0), calendar: calendar))
        // Once run, not again that week.
        #expect(!schedule.isDue(lastRun: date(2026, 11, 4, 17, 1), now: date(2026, 11, 8, 23, 0), calendar: calendar))
        #expect(schedule.isDue(lastRun: date(2026, 11, 4, 17, 1), now: date(2026, 11, 9, 9, 0), calendar: calendar))
    }

    @Test func offAndNeverRunAreNotDue() {
        let now = date(2026, 11, 4, 12)
        #expect(!CheckUpSchedule(frequency: .off).isDue(lastRun: date(2026, 1, 1), now: now, calendar: calendar))
        #expect(CheckUpSchedule(frequency: .off).latestSlot(now: now, calendar: calendar) == nil)
        // No run on record: the caller starts counting from now.
        #expect(!CheckUpSchedule(frequency: .weekly).isDue(lastRun: nil, now: now, calendar: calendar))
    }

    @Test func biweeklySkipsTheNextMonday() {
        let schedule = CheckUpSchedule(frequency: .biweekly, minuteOfDay: 9 * 60)
        let ran = date(2026, 11, 2, 9, 0)
        #expect(!schedule.isDue(lastRun: ran, now: date(2026, 11, 9, 10), calendar: calendar))
        #expect(schedule.isDue(lastRun: ran, now: date(2026, 11, 16, 9, 0), calendar: calendar))
        // A catch-up on Tuesday still leaves two weeks to the Monday after next.
        let late = date(2026, 11, 3, 10)
        #expect(!schedule.isDue(lastRun: late, now: date(2026, 11, 9, 10), calendar: calendar))
        #expect(schedule.isDue(lastRun: late, now: date(2026, 11, 16, 9, 0), calendar: calendar))
    }

    @Test func monthlyRunsOnTheFirstMonday() {
        let schedule = CheckUpSchedule(frequency: .monthly, minuteOfDay: 8 * 60 + 30)
        let slot = schedule.latestSlot(now: date(2026, 11, 20, 12), calendar: calendar)
        #expect(slot == date(2026, 11, 2, 8, 30))
        #expect(!schedule.isDue(lastRun: date(2026, 11, 2, 8, 31), now: date(2026, 11, 20), calendar: calendar))
        #expect(schedule.isDue(lastRun: date(2026, 11, 2, 8, 31), now: date(2026, 12, 7, 9), calendar: calendar))
    }

    @Test func nextRunForTheSettingsLine() {
        let weekly = CheckUpSchedule(frequency: .weekly, minuteOfDay: 9 * 60)
        #expect(weekly.nextRun(lastRun: date(2026, 11, 2, 9, 1), now: date(2026, 11, 4, 12), calendar: calendar) == date(2026, 11, 9, 9))
        let biweekly = CheckUpSchedule(frequency: .biweekly, minuteOfDay: 9 * 60)
        #expect(biweekly.nextRun(lastRun: date(2026, 11, 2, 9, 1), now: date(2026, 11, 4, 12), calendar: calendar) == date(2026, 11, 16, 9))
        #expect(CheckUpSchedule(frequency: .off).nextRun(lastRun: nil, now: Date(), calendar: calendar) == nil)
    }

    // MARK: Findings

    private func crash(_ name: String, week: Int, month: Int) -> CrashSummary {
        CrashSummary(appName: name, bundleID: nil, crashes7: week, crashes30: month, hangs7: 0, hangs30: 0, resource30: 0,
                     lastDate: Date(), lastKind: .crash, lastReason: "SIGABRT", latestReportPath: "/x")
    }

    private func backupInfo(daysAgo: Int?, now: Date, reachable: Bool = true) -> TimeMachineInfo {
        var info = TimeMachineInfo()
        info.destinations = [.init(name: "Backup Disk", kind: "Local")]
        info.lastBackup = daysAgo.map { now.addingTimeInterval(-Double($0) * 86_400) }
        info.destinationReachable = reachable
        return info
    }

    @Test func aCalmMacHasNoFindings() {
        var input = CheckUpInput()
        input.backup = backupInfo(daysAgo: 1, now: input.now)
        input.security = [SecurityStatus.parseFileVault("FileVault is On."), SecurityStatus.parseSIP("System Integrity Protection status: enabled.")]
        input.crashes = [crash("Notes", week: 1, month: 2)]
        input.reclaimableBytes = 400_000_000
        input.uptime = 3 * 86_400
        input.ssdYearsLeft = 30
        #expect(CheckUp.findings(from: input).isEmpty)
        #expect(CheckUp.notification(for: []) == nil)
    }

    @Test func orderingPutsBackupAndSecurityBeforeSpace() {
        var input = CheckUpInput()
        input.backup = backupInfo(daysAgo: 9, now: input.now)
        input.reclaimableBytes = 12_400_000_000
        input.reclaimableItems = 14
        input.crashes = [crash("Chat", week: 4, month: 6)]
        input.security = [SecurityStatus.parseFileVault("FileVault is Off.")]
        input.orphanedStartupItems = 2
        input.uptime = 20 * 86_400
        let kinds = CheckUp.findings(from: input).map(\.kind)
        #expect(kinds == [.backup, .security, .crashes, .trash, .startup, .uptime])
    }

    @Test func notificationNamesTheThreeMostUsefulLines() throws {
        var input = CheckUpInput()
        input.backup = backupInfo(daysAgo: 9, now: input.now)
        input.reclaimableBytes = 12_000_000_000
        input.crashes = [crash("Chat", week: 4, month: 4)]
        input.uptime = 40 * 86_400
        let findings = CheckUp.findings(from: input)
        #expect(findings.count == 4)
        let note = try #require(CheckUp.notification(for: findings))
        #expect(note.title.contains("4"))
        #expect(note.body == "No backup for 9 days · Chat crashed 4 times · 12 GB could go to the Trash")
    }

    @Test func backupRules() {
        var input = CheckUpInput()
        input.backup = backupInfo(daysAgo: 6, now: input.now)
        #expect(CheckUp.findings(from: input).isEmpty)
        input.backup = backupInfo(daysAgo: 40, now: input.now, reachable: false)
        let finding = CheckUp.findings(from: input).first
        #expect(finding?.kind == .backup)
        #expect(finding?.detail.contains("not connected") == true)
        input.backup = backupInfo(daysAgo: nil, now: input.now)
        #expect(CheckUp.findings(from: input).first?.summary == "no backup yet")
        // Not set up, or macOS would not tell: nothing to say.
        input.backup = TimeMachineInfo()
        #expect(CheckUp.findings(from: input).isEmpty)
        var blocked = backupInfo(daysAgo: 50, now: input.now)
        blocked.needsFullDiskAccess = true
        input.backup = blocked
        #expect(CheckUp.findings(from: input).isEmpty)
        // A backup that is running right now is no reason to nag.
        var running = backupInfo(daysAgo: 50, now: input.now)
        running.progress = .init(running: true)
        input.backup = running
        #expect(CheckUp.findings(from: input).isEmpty)
    }

    @Test func crashesNeedThreeInTheWindow() {
        var input = CheckUpInput()
        input.crashes = [crash("A", week: 2, month: 5), crash("B", week: 3, month: 3)]
        input.crashWindowDays = 7
        var finding = CheckUp.findings(from: input).first
        #expect(finding?.summary == "B crashed 3 times")
        #expect(finding?.title.contains("B crashed 3 times in the last 7 days") == true)
        input.crashWindowDays = 30
        finding = CheckUp.findings(from: input).first
        #expect(finding?.summary == "A crashed 5 times")
        #expect(finding?.detail.contains("B (3×)") == true)
        input.crashes = [crash("A", week: 2, month: 2)]
        #expect(CheckUp.findings(from: input).isEmpty)
    }

    @Test func securityOffIsOneFindingAndTheFirewallAloneRanksLower() {
        var input = CheckUpInput()
        input.security = [SecurityStatus.parseFirewall("Firewall is disabled. (State = 0)")]
        let firewall = CheckUp.findings(from: input).first
        #expect(firewall?.title == "Firewall is off")
        input.security = [SecurityStatus.parseFirewall("Firewall is disabled. (State = 0)"), SecurityStatus.parseGatekeeper("assessments disabled")]
        let both = CheckUp.findings(from: input).first
        #expect(both?.title == "2 security checks are off")
        #expect((both?.score ?? 0) > (firewall?.score ?? 0))
        // Unknown answers are not "off".
        input.security = [SecurityStatus.parseFileVault("???")]
        #expect(CheckUp.findings(from: input).isEmpty)
    }

    @Test func growthAndSsdAndLongUptime() {
        var input = CheckUpInput()
        let change = DiskGrowth.Change(path: "Library/Caches", oldBytes: 1_000_000_000, newBytes: 9_000_000_000)
        input.growth = .init(since: Date(timeIntervalSince1970: 0), totalDelta: 8_000_000_000, changes: [change])
        input.ssdYearsLeft = 1.4
        input.uptime = 15 * 86_400
        let findings = CheckUp.findings(from: input)
        #expect(findings.map(\.kind) == [.ssd, .growth, .uptime])
        #expect(findings[1].detail.contains("Library/Caches (+8"))
        input.growth = .init(since: Date(), totalDelta: 500_000_000, changes: [])
        input.ssdYearsLeft = 12
        #expect(CheckUp.findings(from: input).map(\.kind) == [.uptime])
    }

    @Test func largeFilesNeedTwoGigabytesAndPointToCleanUp() {
        var input = CheckUpInput()
        input.lookFirstBytes = 1_900_000_000
        #expect(CheckUp.findings(from: input).isEmpty)
        input.lookFirstBytes = 6_000_000_000
        input.lookFirstItems = 5
        let finding = CheckUp.findings(from: input).first
        #expect(finding?.kind == .largeFiles)
        #expect(finding?.destination == .cleanUp)
        #expect(finding?.destination.pageKey == "storage")
    }

    @Test func reportRoundTrips() throws {
        let report = CheckUpReport(date: Date(timeIntervalSince1970: 1_000_000), findings: [
            CheckUpFinding(kind: .trash, score: 50, title: "t", detail: "d", summary: "s", destination: .cleanUp),
        ], notChecked: ["x"])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("checkup-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try report.save(to: url)
        #expect(CheckUpReport.load(from: url) == report)
    }
}
