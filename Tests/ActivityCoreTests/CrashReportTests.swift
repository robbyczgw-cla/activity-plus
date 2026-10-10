import Foundation
import Testing
@testable import ActivityCore

@Suite("Crash reports")
struct CrashReportTests {
    static let ips = """
    {"app_name":"Google Chrome","timestamp":"2026-10-08 13:55:48.00 +0200","app_version":"154.0.8037.98","bundleID":"com.google.Chrome","is_first_party":0,"bug_type":"309","os_version":"macOS 27.0 (26A428)","name":"Google Chrome","incident_id":"BFCF507A-1BDB-43D0-B659-EEEABACC850F"}
    {"procName":"Google Chrome","captureTime":"2026-10-08 13:55:47.0994 +0200","bundleInfo":{"CFBundleShortVersionString":"154.0.8037.98","CFBundleIdentifier":"com.google.Chrome"},"exception":{"codes":"0x0000000000000001, 0x0000000000000000","rawCodes":[1,0],"type":"EXC_BAD_ACCESS","signal":"SIGSEGV","subtype":"KERN_INVALID_ADDRESS at 0x0000000000000000"},"termination":{"flags":0,"code":11,"namespace":"SIGNAL","indicator":"Segmentation fault: 11","byProc":"exc handler","byPid":23775},"faultingThread":0,"threads":[]}
    """

    static let abort = """
    {"app_name":"ExampleTool","timestamp":"2026-10-08 13:18:18.00 +0200","bundleID":"","bug_type":"309","name":"ExampleTool"}
    {"procName":"ExampleTool","exception":{"type":"EXC_CRASH","signal":"SIGABRT"},"termination":{"flags":0,"code":6,"namespace":"SIGNAL","indicator":"Abort trap: 6"}}
    """

    static let legacy = """
    Process:               Safari [411]
    Path:                  /Applications/Safari.app/Contents/MacOS/Safari
    Identifier:            com.apple.Safari
    Version:               17.0 (19616)
    Date/Time:             2026-10-01 09:30:12.123 +0200

    Exception Type:        EXC_BAD_INSTRUCTION (SIGILL)
    Termination Reason:    Namespace SIGNAL, Code 4 Illegal instruction: 4
    """

    @Test func readsAnIPSCrash() throws {
        let report = try #require(CrashReportParser.parse(path: "/x/Google Chrome-2026-10-08-135548.ips", text: Self.ips, modified: Date(timeIntervalSince1970: 0)))
        #expect(report.kind == .crash)
        #expect(report.appName == "Google Chrome")
        #expect(report.bundleID == "com.google.Chrome")
        #expect(report.appVersion == "154.0.8037.98")
        #expect(report.exceptionType == "EXC_BAD_ACCESS")
        #expect(report.signal == "SIGSEGV")
        #expect(report.reason == "EXC_BAD_ACCESS — the app read memory it shouldn't")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 2 * 3600)!
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: report.date)
        #expect((parts.year, parts.month, parts.day, parts.hour, parts.minute, parts.second) == (2026, 10, 8, 13, 55, 48))
    }

    @Test func emptyBundleIDBecomesNilAndAbortIsExplained() throws {
        let report = try #require(CrashReportParser.parse(path: "/x/ExampleTool-2026-10-08-131819.ips", text: Self.abort, modified: Date()))
        #expect(report.bundleID == nil)
        #expect(report.reason.hasPrefix("SIGABRT"))
    }

    @Test func readsALegacyTextCrash() throws {
        let report = try #require(CrashReportParser.parse(path: "/x/Safari_2026-10-01-093012_Mac.crash", text: Self.legacy, modified: Date()))
        #expect(report.kind == .crash)
        #expect(report.appName == "Safari")
        #expect(report.bundleID == "com.apple.Safari")
        #expect(report.exceptionType == "EXC_BAD_INSTRUCTION")
        #expect(report.signal == "SIGILL")
        #expect(report.terminationNamespace == "SIGNAL")
    }

    @Test func hangAndResourceReportsHaveTheirOwnKind() throws {
        let hang = "Process: Notes [99]\nIdentifier: com.apple.Notes\nDate/Time: 2026-10-02 10:00:00.000 +0200\nEvent: hang\n"
        #expect(CrashReportParser.parse(path: "/x/Notes_2026-10-02-100000_Mac.hang", text: hang, modified: Date())?.kind == .hang)
        let diag = "Date/Time: 2026-10-04 19:48:30.879 +0200\nCommand: Arc\nIdentifier: company.thebrowser.Browser\nEvent: disk writes\n"
        let report = try #require(CrashReportParser.parse(path: "/x/Arc_2026-10-04-214710_Mac.diag", text: diag, modified: Date()))
        #expect(report.kind == .resource)
        #expect(report.appName == "Arc")
    }

    @Test func simulatedFaultsAndGarbageAreSkipped() {
        let fault = "{\"app_name\":\"steam_osx\",\"is_simulated\":1,\"bug_type\":\"309\"}\n{}"
        #expect(CrashReportParser.parse(path: "/x/ExcUserFault_steam_osx-2026-10-06-144713.ips", text: fault, modified: Date()) == nil)
        #expect(CrashReportParser.parse(path: "/x/a.ips", text: "not json", modified: Date()) == nil)
        #expect(CrashReportParser.parse(path: "/x/readme.txt", text: "hello", modified: Date()) == nil)
    }

    @Test func jetsamAndWatchdogGetPlainReasons() {
        #expect(CrashReportParser.plainReason(exceptionType: nil, signal: nil, namespace: "JETSAM", indicator: nil).contains("too much memory"))
        #expect(CrashReportParser.plainReason(exceptionType: "EXC_CRASH", signal: "SIGKILL", namespace: "WATCHDOG", indicator: nil).contains("watchdog"))
        #expect(CrashReportParser.plainReason(exceptionType: "EXC_SOMETHING_NEW", signal: nil, namespace: nil, indicator: nil) == "EXC_SOMETHING_NEW")
    }

    @Test func jetsamEventNamesTheLargestProcess() throws {
        let text = "{\"bug_type\":\"298\",\"timestamp\":\"2026-10-05 08:00:00.00 +0200\"}\n{\"largestProcess\":\"Final Cut Pro\"}"
        let report = try #require(CrashReportParser.parse(path: "/x/JetsamEvent-2026-10-05-080000.ips", text: text, modified: Date()))
        #expect(report.appName == "Final Cut Pro")
        #expect(report.reason.contains("jetsam"))
    }

    // MARK: Counting

    private func report(_ app: String, _ kind: CrashReport.Kind = .crash, daysAgo: Double, secondsExtra: Double = 0, now: Date) -> CrashReport {
        CrashReport(path: "/r/\(app)-\(daysAgo)-\(secondsExtra)", appName: app, bundleID: nil, date: now.addingTimeInterval(-daysAgo * 86_400 + secondsExtra), kind: kind,
                    exceptionType: "EXC_BAD_ACCESS")
    }

    @Test func countsSevenAndThirtyDayWindows() {
        let now = Date()
        let reports = [report("Arc", daysAgo: 1, now: now), report("Arc", daysAgo: 3, now: now), report("Arc", daysAgo: 20, now: now),
                       report("Arc", .hang, daysAgo: 2, now: now), report("Arc", daysAgo: 45, now: now),
                       report("Mail", daysAgo: 6.9, now: now)]
        let summaries = CrashReports.summarize(reports, now: now)
        #expect(summaries.map(\.appName) == ["Arc", "Mail"])
        let arc = summaries[0]
        #expect((arc.crashes7, arc.crashes30, arc.hangs7, arc.hangs30) == (2, 3, 1, 1))
        #expect(arc.latestReportPath.contains("Arc-1.0"))
        #expect(arc.lastReason.hasPrefix("EXC_BAD_ACCESS"))
    }

    @Test func reportsWrittenWithinSecondsAreOneIncident() {
        let now = Date()
        // A browser and its helpers going down together: three files within 4 seconds, then a real second crash.
        let reports = [report("Google Chrome", daysAgo: 1, secondsExtra: 0, now: now),
                       report("Google Chrome Helper (Renderer)", daysAgo: 1, secondsExtra: 2, now: now),
                       report("Google Chrome", daysAgo: 1, secondsExtra: 4, now: now),
                       report("Google Chrome", daysAgo: 1, secondsExtra: 400, now: now)]
        let summary = CrashReports.summarize(reports, now: now)
        #expect(summary.count == 1)
        #expect(summary[0].appName == "Google Chrome")
        #expect(summary[0].crashes7 == 2)
    }

    @Test func resourceWarningsAloneDoNotMakeAnEntry() {
        let now = Date()
        #expect(CrashReports.summarize([report("Arc", .resource, daysAgo: 1, now: now)], now: now).isEmpty)
    }

    @Test func scanReadsAFolderOfReports() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("crash-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Self.ips.write(to: dir.appendingPathComponent("Chrome.ips"), atomically: true, encoding: .utf8)
        try "hello".write(to: dir.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        // The sample is dated Oct 2026; scan relative to a "now" just after it.
        let now = CrashReportParser.parseDate("2026-10-09 12:00:00 +0200")!
        let found = CrashReports.scan(directories: [dir.path, "/does/not/exist"], now: now, days: 30)
        // The file was just written, so it is inside the modification window of `now` only when `now` is real time.
        #expect(found.count <= 1)
        let real = CrashReports.scan(directories: [dir.path], now: Date(), days: 3650)
        #expect(real.count == 1)
    }

    @Test func diagnosisNamesAppsThatCrashedThreeTimes() {
        var input = DiagnosisInput(snapshot: SystemSnapshot(), recentCPU: [], recentAppCPU: [:])
        let now = Date()
        input.crashSummaries = CrashReports.summarize((0..<3).map { report("Steam", daysAgo: Double($0) + 0.5, now: now) }
            + [report("Mail", daysAgo: 1, now: now), report("Mail", daysAgo: 2, now: now)], now: now)
        let findings = Diagnostician.diagnose(input).findings.filter { $0.id.hasPrefix("crashes-") }
        #expect(findings.map { $0.id } == ["crashes-Steam"])
    }
}
