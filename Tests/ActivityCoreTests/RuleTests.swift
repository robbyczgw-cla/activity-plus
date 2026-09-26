import Foundation
import Testing
@testable import ActivityCore

private func snapshot(at date: Date, appCPU: Double = 0, appMemory: UInt64 = 100_000_000,
                      pressure: MemoryPressure = .normal, swap: UInt64 = 0) -> SystemSnapshot {
    var s = SystemSnapshot()
    s.date = date
    s.interval = 2
    s.memory.total = 16 * 1_073_741_824
    s.memory.pressure = pressure
    s.memory.swapUsed = swap
    s.disk.total = 1_000_000_000_000
    s.disk.free = 500_000_000_000
    s.cpu.perCore = Array(repeating: 10, count: 8)
    var process = ProcessSample(pid: 42, ppid: 1, uid: 501, name: "Busy", path: "/Applications/Busy.app/Contents/MacOS/Busy", startTime: .distantPast)
    process.cpuPercent = appCPU
    process.memory = appMemory
    s.apps = [AppGroup(id: "/Applications/Busy.app", name: "Busy", kind: .app, bundlePath: "/Applications/Busy.app",
                       bundleID: "com.example.busy", mainPID: 42, processes: [process])]
    return s
}

@Suite("Alerts")
struct AlertTests {
    @Test func sustainedCPUFiresOnceThenCoolsDown() {
        let engine = AlertEngine()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var fired: [AppAlert] = []
        // 12 minutes at 90 % sampled every 30 s.
        for step in 0..<(12 * 2) {
            fired += engine.evaluate(snapshot(at: start.addingTimeInterval(Double(step) * 30), appCPU: 90))
        }
        #expect(fired.filter { $0.kind == .cpu }.count == 1)
        #expect(fired.first?.title.contains("Busy") == true)
    }

    @Test func shortSpikeDoesNotFire() {
        let engine = AlertEngine()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var fired: [AppAlert] = []
        for step in 0..<24 {
            let cpu = step < 6 ? 300.0 : 5.0
            fired += engine.evaluate(snapshot(at: start.addingTimeInterval(Double(step) * 30), appCPU: cpu))
        }
        #expect(fired.isEmpty)
    }

    @Test func steadyMemoryGrowthFires() {
        var settings = AlertSettings()
        settings.memoryWindowMinutes = 10
        settings.memoryGrowthGB = 1
        let engine = AlertEngine(settings: settings)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var fired: [AppAlert] = []
        for minute in 0..<14 {
            let memory = UInt64(500_000_000 + minute * 150_000_000)
            fired += engine.evaluate(snapshot(at: start.addingTimeInterval(Double(minute) * 60), appMemory: memory))
        }
        #expect(fired.contains { $0.kind == .memoryGrowth })
    }

    @Test func ignoredAppsStayQuiet() {
        var settings = AlertSettings()
        settings.ignoredApps = ["/Applications/Busy.app"]
        let engine = AlertEngine(settings: settings)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var fired: [AppAlert] = []
        for step in 0..<30 { fired += engine.evaluate(snapshot(at: start.addingTimeInterval(Double(step) * 30), appCPU: 150)) }
        #expect(fired.isEmpty)
    }
}

@Suite("Diagnosis")
struct DiagnosisTests {
    @Test func healthyMac() {
        let input = DiagnosisInput(snapshot: snapshot(at: .now), recentCPU: [10, 12, 9], recentAppCPU: [:])
        let result = Diagnostician.diagnose(input)
        #expect(result.severity <= .info)
        #expect(result.headline == "Your Mac is running fine")
    }

    @Test func memoryShortageLeadsTheVerdict() {
        let s = snapshot(at: .now, appMemory: 9_000_000_000, pressure: .critical, swap: 8_000_000_000)
        let result = Diagnostician.diagnose(DiagnosisInput(snapshot: s, recentCPU: [20], recentAppCPU: [:]))
        #expect(result.severity == .critical)
        #expect(result.headline == "Not enough memory")
        #expect(result.findings.first?.action == .quitApp(id: "/Applications/Busy.app", name: "Busy"))
    }

    @Test func runawayAppIsNamed() {
        let s = snapshot(at: .now, appCPU: 190)
        let series = Array(repeating: 190.0, count: 20)
        let result = Diagnostician.diagnose(DiagnosisInput(snapshot: s, recentCPU: [30], recentAppCPU: ["/Applications/Busy.app": series]))
        #expect(result.findings.contains { $0.title == "Busy is running flat out" })
    }
}

@Suite("History")
struct HistoryTests {
    @Test func recordsAndReadsBack() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("activityplus-test-\(UUID()).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = HistoryStore(url: url)
        let start = Date().addingTimeInterval(-3600)
        for step in 0..<(8 * 30) {
            var s = snapshot(at: start.addingTimeInterval(Double(step) * 2), appCPU: 50)
            s.cpu.user = 30
            s.disk.writeRate = 1_000_000
            store.record(s)
        }
        store.flush()
        let points = store.systemSeries(.hours12)
        #expect(!points.isEmpty)
        #expect(abs((points.first?.cpu ?? 0) - 30) < 0.01)
        let apps = store.topApps(.hours12)
        #expect(apps.first?.name == "Busy")
        #expect(abs((apps.first?.averageCPU ?? 0) - 50) < 1)
        let totals = store.totals(since: start.addingTimeInterval(-60))
        // 8 minutes at 1 MB/s ≈ 480 MB written
        #expect(totals.diskWritten > 400_000_000 && totals.diskWritten < 560_000_000)
    }

    @Test func sessionRecordsSummaryAppsAndCSV() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("activityplus-session-\(UUID()).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = HistoryStore(url: url)
        let start = Date().addingTimeInterval(-120)
        let id = store.startSession(name: "Build", at: start)
        #expect(id > 0)
        // 30 samples of 2 s: the app works at 80 % for the first half, then idles at 0 %.
        for step in 0..<30 {
            var s = snapshot(at: start.addingTimeInterval(Double(step + 1) * 2), appCPU: step < 15 ? 80 : 0)
            s.cpu.user = 40
            store.recordSession(id, snapshot: s)
        }
        store.stopSession(id, at: start.addingTimeInterval(62))
        let session = try #require(store.sessions().first)
        #expect(session.name == "Build")
        #expect(session.samples == 30)
        #expect(abs(session.averageCPU - 40) < 0.01)
        #expect(abs(session.duration - 62) < 0.01)
        let app = try #require(store.sessionApps(id).first)
        #expect(app.name == "Busy")
        #expect(abs(app.averageCPU - 40) < 0.5)   // 80 % for half the session
        #expect(abs(app.peakCPU - 80) < 0.01)
        let samples = store.sessionSamples(id)
        let csv = SessionExport.csv(samples, started: session.started)
        let lines = csv.split(separator: "\n")
        #expect(lines.count == 31)
        #expect(lines[0].hasPrefix("time,elapsed_s,cpu_percent"))
        #expect(lines[1].contains(",2.000,40.00,"))
        store.deleteSession(id)
        #expect(store.sessions().isEmpty)
    }
}
