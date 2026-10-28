import Foundation
import Testing
@testable import ActivityCore

private func app(_ name: String, cpu: Double = 0, memory: UInt64 = 0, gpu: Double = 0, disk: Double = 0) -> AppGroup {
    var p = ProcessSample(pid: Int32(abs(name.hashValue % 30_000) + 100), ppid: 1, uid: 501, name: name, path: nil, startTime: Date(timeIntervalSince1970: 0))
    p.cpuPercent = cpu; p.memory = memory; p.gpuPercent = gpu; p.diskReadRate = disk
    return AppGroup(id: "tool:\(name)", name: name, kind: .tool, bundlePath: nil, bundleID: nil, mainPID: p.pid, processes: [p])
}

private func sample(at seconds: Double, interval: Double = 5, cpu: Double = 10, pressure: MemoryPressure = .normal,
                    thermal: ThermalLevel = .nominal, swapOut: Double = 0, apps: [AppGroup] = []) -> SystemSnapshot {
    var s = SystemSnapshot()
    s.date = Date(timeIntervalSince1970: 1_000_000 + seconds)
    s.interval = interval
    s.cpu.user = cpu
    s.memory.pressure = pressure
    s.memory.swapOutRate = swapOut
    s.memory.swapUsed = 4_000_000_000
    s.thermal = thermal
    s.apps = apps
    return s
}

@Suite("Slow moments")
struct SlowMomentTests {
    @Test func busyProcessorForHalfAMinuteIsAMoment() throws {
        var detector = SlowMomentDetector()
        var found: [SlowMoment] = []
        let busy = [app("Compiler", cpu: 600), app("Editor", cpu: 40), app("Clock", cpu: 1)]
        for t in stride(from: 0.0, through: 40, by: 5) {
            if let m = detector.observe(sample(at: t, cpu: 95, apps: busy)) { found.append(m) }
        }
        for t in stride(from: 45.0, through: 70, by: 5) {
            if let m = detector.observe(sample(at: t, cpu: 20)) { found.append(m) }
        }
        let moment = try #require(found.first)
        #expect(found.count == 1)
        #expect(moment.duration == 45)
        #expect(moment.causes.map(\.kind) == [.cpu])
        #expect(moment.causes[0].apps.map(\.name) == ["Compiler", "Editor"])
        #expect(moment.causes[0].apps[0].value == 600)
        #expect(moment.causes[0].peak == 95)
        #expect(moment.severity == .noticeable)
    }

    @Test func shortSpikeIsIgnored() {
        var detector = SlowMomentDetector()
        var found: [SlowMoment] = []
        for t in stride(from: 0.0, through: 10, by: 5) {
            if let m = detector.observe(sample(at: t, cpu: 99)) { found.append(m) }
        }
        for t in stride(from: 15.0, through: 60, by: 5) {
            if let m = detector.observe(sample(at: t, cpu: 5)) { found.append(m) }
        }
        #expect(found.isEmpty)
    }

    /// One calm sample in the middle does not split the moment in two.
    @Test func shortDipKeepsOneMoment() {
        var detector = SlowMomentDetector()
        var found: [SlowMoment] = []
        for t in stride(from: 0.0, through: 100, by: 5) {
            let calm = t == 50
            if let m = detector.observe(sample(at: t, pressure: calm ? .warning : .critical, apps: [app("Browser", memory: 6_000_000_000)])) { found.append(m) }
        }
        if let m = detector.close() { found.append(m) }
        #expect(found.count == 1)
        #expect(found.first?.causes.first?.kind == .memory)
        #expect(found.first?.severity == .severe)
        #expect(found.first?.causes.first?.apps.first?.name == "Browser")
    }

    @Test func causesAreRankedAndCappedAtThree() throws {
        var detector = SlowMomentDetector()
        var found: [SlowMoment] = []
        var s = sample(at: 0)
        for t in stride(from: 0.0, through: 60, by: 5) {
            s = sample(at: t, cpu: 97, pressure: .critical, thermal: .serious, swapOut: 50_000_000,
                       apps: [app("Render", cpu: 400, memory: 3_000_000_000, gpu: 80, disk: 900_000_000)])
            s.gpu = GPUStats(); s.gpu?.utilization = 99
            s.disk.readRate = 900_000_000
            if let m = detector.observe(s, hanging: [(id: "tool:Viewer", name: "Viewer")]) { found.append(m) }
        }
        let closed = detector.close()
        let moment = try #require(closed)
        #expect(found.isEmpty)
        #expect(moment.causes.count == 3)
        // Memory and a hang weigh most, then heat.
        #expect(moment.causes.map(\.kind) == [.memory, .hang, .thermal])
        #expect(moment.causes[1].title.contains("Viewer"))
        #expect(moment.severity == .severe)
    }

    @Test func sleepEndsAMoment() throws {
        var detector = SlowMomentDetector()
        for t in stride(from: 0.0, through: 30, by: 5) { _ = detector.observe(sample(at: t, cpu: 99)) }
        // The next sample arrives after the Mac slept for an hour.
        let after = detector.observe(sample(at: 3630, interval: 3600, cpu: 99))
        let moment = try #require(after)
        #expect(moment.end == Date(timeIntervalSince1970: 1_000_030))
    }

    @Test func storedMomentsComeBackNewestFirst() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("slow-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = HistoryStore(url: url)
        let now = Date()
        let cause = SlowMoment.Cause(kind: .swap, seconds: 40, peak: 30_000_000, apps: [.init(appID: "tool:Build", name: "Build", value: 2e9)])
        store.recordSlowMoment(SlowMoment(start: now.addingTimeInterval(-7200), end: now.addingTimeInterval(-7100), severity: .bad, causes: [cause]))
        store.recordSlowMoment(SlowMoment(start: now.addingTimeInterval(-600), end: now.addingTimeInterval(-560), severity: .noticeable, causes: [cause]))
        store.recordSlowMoment(SlowMoment(start: now.addingTimeInterval(-9 * 86_400), end: now.addingTimeInterval(-9 * 86_400 + 30), severity: .bad, causes: []))
        let moments = store.slowMoments(since: now.addingTimeInterval(-7 * 86_400))
        #expect(moments.count == 2)
        #expect(moments[0].severity == .noticeable)
        #expect(moments[1].causes.first?.apps.first?.name == "Build")
        #expect(moments[1].causes.first?.appsLine.hasPrefix("Build ") == true)
    }
}

@Suite("Wakes while asleep")
struct SleepWakeTests {
    // Neutral sample lines in pmset's layout: date (25 chars), space, type column padded to 20, tab, text.
    static let log: [Substring] = [
        "2026-03-02 01:00:00 +0100 Sleep               \tEntering Sleep state due to 'Maintenance Sleep':TCPKeepAlive=active Using Batt (Charge:80%) 900 secs",
        "2026-03-02 01:00:02 +0100 Wake Requests       \t[process=mDNSResponder request=Maintenance deltaSecs=7198 wakeAt=2026-03-02 03:00:00 info=\"upkeep wake\"] [*process=dasd request=SleepService deltaSecs=898 wakeAt=2026-03-02 01:15:00 info=\"com.apple.dasd:501:com.example.sync.refresh\"]",
        "2026-03-02 01:14:58 +0100 Assertions          \tPID 712(mDNSResponder) Created MaintenanceWake \"mDNSResponder:maintenance\" 00:00:00  id:0x1 [System: PrevIdle]",
        "2026-03-02 01:15:00 +0100 Assertions          \tPID 88(powerd) Created InternalPreventSleep \"PM configd - Wait for Device enumeration\" 00:00:00  id:0x2 [System: PrevIdle]",
        "2026-03-02 01:15:00 +0100 DarkWake            \tDarkWake from Deep Idle [CDNP] : due to NUB.SPMISw3IRQ nub-spmi0.0x02 rtc/SleepService Using BATT (Charge:80%) 4 secs    ",
        "2026-03-02 01:15:01 +0100 Assertions          \tPID 901(cloudd) Created SystemIsActive \"NSURLSessionTask 1\" 00:00:00  id:0x3 [System: PrevIdle]",
        "2026-03-02 01:15:02 +0100 Assertions          \tPID 901(cloudd) Created SystemIsActive \"NSURLSessionTask 2\" 00:00:00  id:0x4 [System: PrevIdle]",
        "2026-03-02 01:15:04 +0100 Sleep               \tEntering Sleep state due to 'Sleep Service Back to Sleep':TCPKeepAlive=active Using Batt (Charge:80%) 600 secs",
        "2026-03-02 01:15:05 +0100 Wake Requests       \t[process=mDNSResponder request=Maintenance deltaSecs=6295 wakeAt=2026-03-02 03:00:00 info=\"upkeep wake\"]",
        "2026-03-02 01:25:04 +0100 DarkWake            \tDarkWake from Deep Idle [CDNP] : due to smc.sysState.Wake(0x70070000) wifibt SMC.OutboxNotEmpty E_RX_IP_PACKET ARPT/ Using BATT (Charge:80%) 6 secs    ",
        "2026-03-02 01:25:10 +0100 Sleep               \tEntering Sleep state due to 'Maintenance Sleep':TCPKeepAlive=active Using Batt (Charge:80%) 1200 secs",
        "2026-03-02 01:45:10 +0100 DarkWake            \tDarkWake from Deep Idle [CDNP] : due to smc.sysState.Wake(0x70070000) wifibt SMC.OutboxNotEmpty bluetooth-pcie/ Using BATT (Charge:79%) 3 secs    ",
        "2026-03-02 07:30:00 +0100 Wake                \tWake from Deep Idle [CDNVA] : due to smc.sysState.Wake(0x70070000) lid SMC.OutboxNotEmpty/HID Activity Using BATT (Charge:78%)",
        "2026-03-03 02:00:00 +0100 DarkWake            \tDarkWake from Deep Idle [CDNP] : due to NUB.SPMISw3IRQ nub-spmi0.0x02 rtc/Maintenance Using AC (Charge:100%) 10 secs    ",
    ]

    static let since = Date(timeIntervalSince1970: 0)

    @Test func classifiesReasons() {
        #expect(SleepWakes.cause(of: "NUB.SPMISw3IRQ nub-spmi0.0x02 rtc/SleepService") == .backgroundTask)
        #expect(SleepWakes.cause(of: "NUB.SPMISw3IRQ nub-spmi0.0x02 rtc/Maintenance") == .maintenance)
        #expect(SleepWakes.cause(of: "smc.sysState.Wake(0x70070000) wifibt SMC.OutboxNotEmpty E_TKO_NO_RESPONSE ARPT/") == .keepAlive)
        #expect(SleepWakes.cause(of: "smc.sysState.Wake(0x70070000) wifibt SMC.OutboxNotEmpty E_PFN_NET_FOUND ARPT/") == .wifiFound)
        #expect(SleepWakes.cause(of: "smc.sysState.Wake(0x70070000) wifibt SMC.OutboxNotEmpty E_CONNECTION_LOSS ARPT/") == .wifiChange)
        #expect(SleepWakes.cause(of: "smc.sysState.Wake(0x70070000) wifibt SMC.OutboxNotEmpty/") == .network)
        #expect(SleepWakes.cause(of: "smc.sysState.Wake(0x70070000) acdetach SMC.OutboxNotEmpty/") == .power)
        #expect(SleepWakes.cause(of: "smc.sysState.Wake(0x70070000) lid SMC.OutboxNotEmpty/Notification") == .lid)
        #expect(SleepWakes.cause(of: "EC.XHC1 (User)") == .usb)
        #expect(SleepWakes.cause(of: "something new") == .unknown)
    }

    @Test func parsesDarkWakesWithRequesterAndHolders() throws {
        let result = SleepWakes.parse(lines: Self.log, since: Self.since)
        #expect(result.wakes.count == 4)   // the full wake in the morning is not a dark wake
        let first = try #require(result.wakes.first)
        #expect(first.cause == .backgroundTask)
        #expect(first.duration == 4)
        #expect(first.batteryPercent == 80)
        #expect(first.requester?.process == "dasd")
        #expect(first.requester?.label == "dasd (com.example.sync.refresh)")
        #expect(first.holders == ["mDNSResponder": 1, "cloudd": 2])   // powerd's own assertions are left out
        #expect(result.wakes[1].cause == .networkPacket)
        #expect(result.wakes[1].requester == nil)
        #expect(result.wakes[2].cause == .bluetooth)
        #expect(result.sleeps.map(\.seconds) == [900, 600, 1200])
    }

    @Test func groupsIntoNightsNoonToNoon() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 3600)!
        let result = SleepWakes.parse(lines: Self.log, since: Self.since)
        let nights = SleepWakes.nights(result.wakes, sleeps: result.sleeps, calendar: calendar)
        #expect(nights.count == 2)
        #expect(nights[0].wakes.count == 1)   // the night into March 3
        #expect(nights[1].wakes.count == 3)
        #expect(nights[1].asleep == 2700)
        let processes = SleepWakes.processes(in: nights[1].wakes)
        #expect(processes.first?.name == "cloudd" || processes.first?.name == "dasd (com.example.sync.refresh)")
        #expect(processes.count == 3)
    }

    @Test func busyAppsAfterAWakeComeFromTheNextWindow() {
        let result = SleepWakes.parse(lines: Self.log, since: Self.since)
        let wake = result.wakes[0]
        let windows = [
            // Written before the wake: not counted.
            FanSpinUps.AppWindow(end: wake.date.addingTimeInterval(-60), apps: [.init(appID: "a", name: "Old", cpu: 50, gpu: 0)]),
            // The first window after it, written at the next wake.
            FanSpinUps.AppWindow(end: result.wakes[1].date.addingTimeInterval(2), apps: [
                .init(appID: "b", name: "Sync", cpu: 30, gpu: 0), .init(appID: "c", name: "Activity+", cpu: 9, gpu: 0),
                .init(appID: "d", name: "Idle", cpu: 1, gpu: 0),
            ]),
        ]
        let busy = SleepWakes.busyAfter([wake], windows: windows, ignoring: ["Activity+"])
        #expect(busy.map(\.name) == ["Sync"])
        #expect(busy.first?.averageCPU == 30)
    }

    @Test func relevantLinesOnly() {
        #expect(SleepWakes.isRelevant(Self.log[0]))
        #expect(SleepWakes.isRelevant("2026-03-02 01:15:01 +0100 Assertions          \tPID 901(cloudd) Created SystemIsActive \"x\""))
        #expect(!SleepWakes.isRelevant("2026-03-02 01:15:01 +0100 Assertions          \tPID 901(cloudd) Released SystemIsActive \"x\""))
        #expect(!SleepWakes.isRelevant("DriverReason:ARPT - DriverDetails:"))
        #expect(!SleepWakes.isRelevant("2026-03-02 01:15:01 +0100 Kernel Client Acks  \tDelays to Wake notifications"))
    }
}

@Suite("Apps macOS stopped")
struct AppStopTests {
    let date = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func memoryLimitKillOfAService() throws {
        let stop = try #require(AppStops.parse(message: "[osservice<com.example.indexd(501)>:7059] termination reported by launchd (1, 7, 9)", date: date))
        #expect(stop.kind == .service)
        #expect(stop.identifier == "com.example.indexd")
        #expect(stop.name == "indexd")
        #expect(stop.pid == 7059)
        #expect(stop.reason == .memoryLimit)
        #expect(stop.isMemory)
        #expect(stop.reasonPhrase == "for using too much memory")
    }

    @Test func appsLoseTheirInstanceNumbers() throws {
        let stop = try #require(AppStops.parse(message: "[app<application.com.example.Editor.30257551.30257607(501)>:812] termination reported by launchd (1, 4, 9)", date: date))
        #expect(stop.kind == .app)
        #expect(stop.identifier == "com.example.Editor")
        #expect(stop.reason == .memoryPressure)
    }

    @Test func helperIsTracedToItsApp() throws {
        let message = "[xpcservice<com.apple.WebKit.WebContent([app<application.com.example.Browser.704756.705352(501)>:75173])(501)>{vt hash: 0}{definition:com.apple.WebKit.WebContent[standard][client]}:75815:75815] termination reported by launchd (1, 7, 9)"
        let stop = try #require(AppStops.parse(message: message, date: date))
        #expect(stop.kind == .appService)
        #expect(stop.hostBundleID == "com.example.Browser")
        #expect(stop.name == "WebContent")
        #expect(stop.pid == 75815)
    }

    @Test func ordinaryEndingsAreLeftOut() {
        for tuple in ["(0, 0, 0)", "(2, 9, 9)", "(2, 15, 15)", "(15, 0, 9)", "(1, 9, 9)", "(1, 17, 9)"] {
            #expect(AppStops.parse(message: "[anon<tool>(501):44] termination reported by launchd \(tuple)", date: date) == nil)
        }
        #expect(AppStops.parse(message: "[anon<tool>(501):44] termination reported by proc_exit", date: date) == nil)
        #expect(AppStops.parse(message: "[anon<tool>(501):44] termination reported by launchd (4, 1, 9)", date: date)?.reason == .hang)
        #expect(AppStops.parse(message: "[anon<tool>(501):44] termination reported by launchd (3, 2, 9)", date: date)?.reason == .codeSigning)
    }

    @Test func parsesLogShowOutput() throws {
        let ndjson = """
            {"timestamp":"2026-03-02 14:02:11.123456+0100","eventMessage":"[osservice<com.example.indexd(501)>:7059] termination reported by launchd (1, 7, 9)","processImagePath":"/usr/libexec/runningboardd"}
            {"timestamp":"2026-03-02 14:05:00.000001+0100","eventMessage":"[anon<tool>(501):44] termination reported by launchd (2, 9, 9)"}
            {"count":2,"finished":1}
            """
        let stops = AppStops.parse(ndjson: Data(ndjson.utf8))
        #expect(stops.count == 1)
        let stop = try #require(stops.first)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 3600)!
        #expect(calendar.component(.hour, from: stop.date) == 14)
        #expect(calendar.component(.minute, from: stop.date) == 2)
    }

    @Test func storedOnceAndGrouped() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("stops-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = HistoryStore(url: url)
        let now = Date()
        let a = AppStop(date: now.addingTimeInterval(-60), pid: 10, name: "indexd", identifier: "com.example.indexd", hostBundleID: nil, kind: .service, namespace: 1, code: 7)
        let b = AppStop(date: now.addingTimeInterval(-30), pid: 11, name: "indexd", identifier: "com.example.indexd", hostBundleID: nil, kind: .service, namespace: 1, code: 7)
        let c = AppStop(date: now.addingTimeInterval(-20), pid: 12, name: "WebContent", identifier: "com.apple.WebKit.WebContent", hostBundleID: "com.example.Browser", kind: .appService, namespace: 1, code: 7)
        store.recordAppStops([a, b])
        store.recordAppStops([b, c])   // b read twice
        let stops = store.appStops(since: now.addingTimeInterval(-3600))
        #expect(stops.count == 3)
        #expect(stops.first?.hostBundleID == "com.example.Browser")
        let groups = AppStops.grouped(stops) { $0.hostBundleID ?? $0.name }
        #expect(groups.map(\.stops.count) == [2, 1])
        #expect(groups[0].name == "indexd")
    }
}
