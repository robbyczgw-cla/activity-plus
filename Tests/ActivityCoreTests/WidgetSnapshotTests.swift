import Foundation
import Testing
@testable import ActivityCore
import WidgetData

@Suite("Widget snapshot")
struct WidgetSnapshotTests {
    static func app(_ name: String, cpu: Double, memory: UInt64, bundle: Bool = true) -> AppGroup {
        var app = AppGroup(id: "com.example.\(name)", name: name, kind: bundle ? .app : .tool,
                           bundlePath: bundle ? "/Applications/\(name).app" : nil, bundleID: nil, mainPID: nil, processes: [])
        app.cpuPercent = cpu
        app.memory = memory
        return app
    }

    static var sample: SystemSnapshot {
        var s = SystemSnapshot()
        s.date = Date(timeIntervalSince1970: 1_800_000_000)
        s.interval = 2
        s.cpu.user = 20
        s.cpu.system = 5
        s.memory.total = 16 << 30
        s.memory.app = 6 << 30
        s.memory.wired = 2 << 30
        s.memory.pressure = .warning
        s.disk.total = 500_000_000_000
        s.disk.free = 125_000_000_000
        s.network.inRate = 1_500_000
        var gpu = GPUStats()
        gpu.utilization = 40
        s.gpu = gpu
        s.sensors.cpuTemperature = 55
        s.apps = [app("Idle", cpu: 0, memory: 900), app("Editor", cpu: 12, memory: 100), app("Browser", cpu: 30, memory: 50),
                  app("Tool", cpu: 0, memory: 5_000, bundle: false), app("Player", cpu: 3, memory: 10)]
        return s
    }

    @Test func mapsReadings() {
        let w = WidgetSnapshot(Self.sample)
        #expect(w.date == Self.sample.date)
        #expect(w.cpu.fraction == 0.25)
        #expect(w.memory.fraction == 0.5)
        #expect(w.memoryPressure == .warning)
        #expect(w.gpu?.fraction == 0.4)
        #expect(w.disk.fraction == 0.75)
        #expect(w.temperature?.fraction == 0.55)
        #expect(w.temperatureCelsius == 55)
        #expect(w.battery == nil)
        #expect(w.networkIn.text == Format.networkRate(1_500_000))
    }

    @Test func topThreeByCPUThenMemory() {
        let w = WidgetSnapshot(Self.sample)
        #expect(w.topApps.map(\.name) == ["Browser", "Editor", "Player"])
        var idle = Self.sample
        idle.apps = idle.apps.map { var a = $0; a.cpuPercent = 0; return a }
        #expect(WidgetSnapshot.topApps(idle.apps).map(\.name) == ["Tool", "Idle", "Editor"])
        // Groups without a bundle get a symbol instead of an icon.
        #expect(WidgetSnapshot(idle).topApps.first?.symbol == "terminal.fill")
    }

    @Test func fractionsStayInRange() {
        var s = Self.sample
        s.cpu.user = 90
        s.cpu.system = 30   // rounding across cores can overshoot 100
        s.disk.total = 0
        let w = WidgetSnapshot(s)
        #expect(w.cpu.fraction == 1)
        #expect((0...1).contains(w.disk.fraction ?? -1))
    }

    @Test func roundTripsThroughJSON() throws {
        let w = WidgetSnapshot(Self.sample, icon: { _ in Data([1, 2, 3]) })
        let decoded = try WidgetSnapshot.decode(try w.encoded())
        #expect(decoded == w)
        #expect(decoded.topApps.first?.icon == Data([1, 2, 3]))
    }

    @Test func writesAtomicallyAndReadsBack() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = dir.appendingPathComponent(WidgetStore.fileName)
        let w = WidgetSnapshot(Self.sample)
        try WidgetStore.write(w, to: url)
        #expect(WidgetStore.read(from: url) == w)
        #expect(WidgetStore.read(from: dir.appendingPathComponent("missing.json")) == nil)
    }

    @Test func staleAfterFifteenMinutes() {
        let w = WidgetSnapshot(Self.sample)
        #expect(!w.isStale(at: w.date.addingTimeInterval(14 * 60)))
        #expect(w.isStale(at: w.date.addingTimeInterval(16 * 60)))
    }
}

@Suite("Widget publish schedule")
struct WidgetPublishScheduleTests {
    @Test func writesOnceUntilWidgetsAreKnown() {
        var schedule = WidgetPublishSchedule()
        let t0 = Date()
        let first = schedule.decide(at: t0)
        #expect(first.checkWidgets && first.write && !first.reload)
        // No answer yet: nothing more is written.
        #expect(!schedule.decide(at: t0.addingTimeInterval(120)).write)
    }

    @Test func noWidgetsMeansNoWrites() {
        var schedule = WidgetPublishSchedule()
        let t0 = Date()
        _ = schedule.decide(at: t0)
        schedule.widgetsFound(false)
        for minute in 1...10 {
            #expect(!schedule.decide(at: t0.addingTimeInterval(Double(minute) * 60)).write)
        }
        // But WidgetKit is asked again every three minutes.
        var probe = WidgetPublishSchedule()
        _ = probe.decide(at: t0)
        probe.widgetsFound(false)
        #expect(!probe.decide(at: t0.addingTimeInterval(170)).checkWidgets)
        #expect(probe.decide(at: t0.addingTimeInterval(181)).checkWidgets)
    }

    @Test func writesEveryMinuteAndReloadsEveryFive() {
        var schedule = WidgetPublishSchedule()
        let t0 = Date()
        _ = schedule.decide(at: t0)
        schedule.widgetsFound(true)
        // A widget that just appeared gets numbers and a reload with the next sample.
        let next = schedule.decide(at: t0.addingTimeInterval(2))
        #expect(next.write && next.reload)
        var writes = 0, reloads = 0
        var t = t0.addingTimeInterval(2)
        while t < t0.addingTimeInterval(2 + 10 * 60) {
            t += 2
            let d = schedule.decide(at: t)
            if d.write { writes += 1 }
            if d.reload { reloads += 1 }
            if d.checkWidgets { schedule.widgetsFound(true) }
        }
        #expect(writes == 10)
        #expect(reloads == 2)
    }
}
