import Foundation
import Testing
@testable import ActivityCore

private func app(_ id: String = "/Applications/Slack.app", memory: UInt64 = 0, cpu: Double = 0) -> AppGroup {
    var process = ProcessSample(pid: 7, ppid: 1, uid: 501, name: "Slack", path: id + "/Contents/MacOS/Slack", startTime: .distantPast)
    process.memory = memory
    process.cpuPercent = cpu
    return AppGroup(id: id, name: "Slack", kind: .app, bundlePath: id, bundleID: "com.tinyspeck.slackmacgap", mainPID: 7, processes: [process])
}

@Suite("Insights")
struct InsightTests {
    let baseline = HistoryStore.Baseline(appID: "/Applications/Slack.app", averageCPU: 3, averageMemory: 600_000_000,
                                         typicalPeakMemory: 800_000_000, windows: 200)

    @Test func memoryFarAboveNormalIsFlagged() {
        let anomalies = AnomalyDetector.detect(apps: [app(memory: 2_400_000_000)], baselines: [baseline.appID: baseline], recentCPU: [:])
        #expect(anomalies.first?.kind == .memory)
        #expect(anomalies.first?.title.contains("4.0×") == true)
    }

    @Test func normalUsageAndThinHistoryStayQuiet() {
        #expect(AnomalyDetector.detect(apps: [app(memory: 700_000_000)], baselines: [baseline.appID: baseline], recentCPU: [:]).isEmpty)
        let thin = HistoryStore.Baseline(appID: baseline.appID, averageCPU: 1, averageMemory: 100_000_000, typicalPeakMemory: 100_000_000, windows: 5)
        #expect(AnomalyDetector.detect(apps: [app(memory: 3_000_000_000)], baselines: [thin.appID: thin], recentCPU: [:]).isEmpty)
    }

    @Test func sustainedCPUAboveNormal() {
        let anomalies = AnomalyDetector.detect(apps: [app(cpu: 60)], baselines: [baseline.appID: baseline],
                                               recentCPU: [baseline.appID: Array(repeating: 55, count: 40)])
        #expect(anomalies.contains { $0.kind == .cpu })
    }

    @Test func steadyGrowthIsALeak() {
        let start = Date()
        let points = (0..<24).map { (date: start.addingTimeInterval(Double($0) * 300), memory: 1e9 + Double($0) * 50_000_000) }
        let forecast = LeakDetector.forecast(points)
        #expect(forecast != nil)
        #expect(abs((forecast?.growthPerHour ?? 0) - 600_000_000) < 1_000_000)   // 50 MB per 5 min
        #expect(forecast!.hours(until: forecast!.current + 1.2e9)! > 1.9)
    }

    @Test func noisyOrFlatMemoryIsNotALeak() {
        let start = Date()
        let flat = (0..<24).map { (date: start.addingTimeInterval(Double($0) * 300), memory: 1e9 + Double($0 % 3) * 80_000_000) }
        #expect(LeakDetector.forecast(flat) == nil)
    }
}

@Suite("Automations")
struct AutomationTests {
    @Test func memoryRuleFiresOnceWithinCooldown() {
        let engine = AutomationEngine()
        let rule = AutomationRule(trigger: .appMemoryAbove(appID: "/Applications/Slack.app", appName: "Slack", gigabytes: 2), action: .quitTriggeringApp)
        var snapshot = SystemSnapshot()
        snapshot.apps = [app(memory: 3 * 1_073_741_824)]
        let now = Date()
        #expect(engine.evaluate([rule], snapshot: snapshot, servers: [], now: now).count == 1)
        #expect(engine.evaluate([rule], snapshot: snapshot, servers: [], now: now.addingTimeInterval(60)).isEmpty)
        #expect(engine.evaluate([rule], snapshot: snapshot, servers: [], now: now.addingTimeInterval(3700)).count == 1)
    }

    @Test func cpuRuleNeedsTheFullDuration() {
        let engine = AutomationEngine()
        let rule = AutomationRule(trigger: .appCPUAbove(appID: "/Applications/Slack.app", appName: "Slack", percent: 80, minutes: 5), action: .notify)
        var busy = SystemSnapshot()
        busy.apps = [app(cpu: 120)]
        var calm = SystemSnapshot()
        calm.apps = [app(cpu: 5)]
        let t = Date()
        #expect(engine.evaluate([rule], snapshot: busy, servers: [], now: t).isEmpty)
        #expect(engine.evaluate([rule], snapshot: busy, servers: [], now: t.addingTimeInterval(200)).isEmpty)
        _ = engine.evaluate([rule], snapshot: calm, servers: [], now: t.addingTimeInterval(250))   // resets
        #expect(engine.evaluate([rule], snapshot: busy, servers: [], now: t.addingTimeInterval(320)).isEmpty)
        #expect(engine.evaluate([rule], snapshot: busy, servers: [], now: t.addingTimeInterval(640)).count == 1)
    }

    @Test func idleServerRuleCountsObservedInactivityOnly() {
        let engine = AutomationEngine()
        let rule = AutomationRule(trigger: .devServerIdle(hours: 24), action: .stopDevServer)
        let t = Date()
        // Up for two days with almost no CPU ("barely used"), but it worked ten minutes ago.
        var server = DevServer(pid: 4242, name: "node", command: "vite", ports: [5173], directory: "/tmp/site",
                               startTime: t.addingTimeInterval(-48 * 3600), memory: 0, cpuPercent: 0, cpuTime: 10,
                               lastActive: t.addingTimeInterval(-600), pids: [4242])
        #expect(engine.evaluate([rule], snapshot: SystemSnapshot(), servers: [server], now: t).isEmpty)
        // Never seen working, but only watched for an hour: not yet.
        server.lastActive = nil
        #expect(engine.evaluate([rule], snapshot: SystemSnapshot(), servers: [server], now: t.addingTimeInterval(3600)).isEmpty)
        // Watched and quiet for more than a day: now it may ask.
        #expect(engine.evaluate([rule], snapshot: SystemSnapshot(), servers: [server], now: t.addingTimeInterval(25 * 3600)).count == 1)
    }

    @Test func disabledRulesDoNothing() {
        var rule = AutomationRule(trigger: .batteryBelow(percent: 50), action: .notify)
        rule.enabled = false
        var snapshot = SystemSnapshot()
        var battery = BatteryStats()
        battery.percent = 10
        snapshot.battery = battery
        #expect(AutomationEngine().evaluate([rule], snapshot: snapshot, servers: [], now: Date()).isEmpty)
    }
}

@Suite("Uninstall safety")
struct UninstallSafetyTests {
    @Test func bundleMetadataCannotEscapeLibraryFolders() {
        #expect(StorageScanner.isSafeFolderName("com.tinyspeck.slackmacgap"))
        #expect(StorageScanner.isSafeFolderName("Visual Studio Code"))
        for bad in ["", "..", "../../Documents", ".hidden", "a/b", "AC/DC", " Slack", "x:y"] {
            #expect(!StorageScanner.isSafeFolderName(bad), "\(bad) must be rejected")
        }
    }
}
