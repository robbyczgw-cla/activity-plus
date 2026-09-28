import Foundation
import SQLite3
import Testing
@testable import ActivityCore

@Suite("Battery details")
struct BatteryTests {
    private var fixture: [String: Any] {
        ["IsCharging": true, "ExternalConnected": true, "CurrentCapacity": 83, "MaxCapacity": 100,
         "CycleCount": 244, "DesignCycleCount9C": 1000, "Voltage": 12333, "Amperage": 1626, "AvgTimeToFull": 103,
         "ChargerData": ["NotChargingReason": 0, "SlowChargingReason": 0, "TimeChargingThermallyLimited": 0],
         "AdapterDetails": ["Watts": 65, "AdapterVoltage": 20000, "Current": 3240, "Description": "pd charger",
                            "IsWireless": false, "UsbHvcMenu": [
                                ["MaxVoltage": 20000, "MaxCurrent": 3240], ["MaxVoltage": 5000, "MaxCurrent": 2960],
                                ["MaxVoltage": 9000, "MaxCurrent": 2980], ["MaxVoltage": 12000, "MaxCurrent": 2980],
                                ["MaxVoltage": 15000, "MaxCurrent": 2990]]],
         "PowerTelemetryData": ["SystemPowerIn": 63304, "SystemLoad": 46661, "BatteryPower": 16643, "AdapterEfficiencyLoss": 1856],
         "BatteryData": ["DesignCapacity": 6075, "FullChargeCapacity": 5258, "NominalChargeCapacity": 5408, "RemainingCapacity": 4168],
         "FedDetails": [["FedExternalConnected": 1], ["FedExternalConnected": 0], ["FedExternalConnected": 0]]]
    }

    @Test func chargingDetails() throws {
        let b = try #require(BatterySampler.parse(fixture, adapter: nil))
        #expect(b.percent == 83 && b.cycleCount == 244 && b.designCycleCount == 1000)
        #expect(abs(b.batteryPower - 20.053458) < 0.000001)
        #expect(b.systemPower == 46.661 && b.adapterInputPower == 63.304 && b.adapterLoss == 1.856)
        #expect(b.amperage == 1626 && b.voltage == 12.333 && b.adapterCurrent == 3.24)
        #expect(b.adapterVoltage == 20 && b.adapterWatts == 65 && b.adapterName == "pd charger")
        #expect(b.adapterProfiles.map(\.volts) == [5, 9, 12, 15, 20])
        #expect(b.adapterPort == 1 && !b.adapterIsWireless && b.timeToFull == 6180)
        #expect(b.designCapacity == 6075 && b.fullChargeCapacity == 5258 && b.remainingCapacity == 4168)
        #expect(abs(try #require(b.chargeRate) - 30.9243) < 0.001)
        #expect(b.hold == nil && b.slowCharging == nil && b.thermallyLimitedSeconds == 0)
    }

    @Test func dischargeAndHoldRules() throws {
        var d = fixture
        d["IsCharging"] = false
        d["ExternalConnected"] = false
        d["Amperage"] = 65536 - 1626
        d["PowerTelemetryData"] = nil
        var b = try #require(BatterySampler.parse(d, adapter: nil))
        #expect(b.amperage == -1626 && b.batteryPower < -20 && b.systemPower == -b.batteryPower)
        #expect(b.timeToFull == nil && b.adapterInputPower == nil && b.adapterPort == nil)
        d["ExternalConnected"] = true
        b = try #require(BatterySampler.parse(d, adapter: nil))
        #expect(b.hold == .adapterTooWeak)
        d["FullyCharged"] = true
        #expect(BatterySampler.parse(d, adapter: nil)?.hold == .full)
        d["FullyCharged"] = false
        d["Amperage"] = 0
        // 0x4000 has no documented meaning: reported as-is, never guessed.
        d["ChargerData"] = ["NotChargingReason": 0x4000, "SlowChargingReason": 43, "TimeChargingThermallyLimited": 12]
        b = try #require(BatterySampler.parse(d, adapter: nil))
        #expect(b.hold == .other(code: 0x4000) && b.slowCharging == .other(code: 43))
        #expect(b.thermallyLimitedSeconds == 12)
    }

    @Test func fallbacksAndMissingKeys() throws {
        let basic = try #require(BatterySampler.parse(["CurrentCapacity": 2500, "MaxCapacity": 5000], adapter: nil))
        #expect(basic.percent == 50 && basic.fullChargeCapacity == nil && basic.chargeRate == nil)
        #expect(basic.adapterProfiles.isEmpty && basic.timeToFull == nil && basic.hold == nil)
        #expect(BatterySampler.parse(["BatteryInstalled": false], adapter: nil) == nil)
        var d = fixture
        d["AppleRawMaxCapacity"] = 5500
        d["AppleRawCurrentCapacity"] = 4200
        d["DesignCapacity"] = 9999
        d["AvgTimeToFull"] = 65535
        d["FedDetails"] = [["FedExternalConnected": 1], ["FedExternalConnected": 1]]
        d["AdapterDetails"] = ["Watts": 65]
        d["PowerDistribution"] = ["IPDInputCurrent": 2000]
        let b = try #require(BatterySampler.parse(d, adapter: ["AdapterVoltage": 15000]))
        #expect(b.fullChargeCapacity == 5500 && b.remainingCapacity == 4200 && b.designCapacity == 6075)
        #expect(b.timeToFull == nil && b.adapterPort == nil && b.adapterCurrent == 2 && b.adapterVoltage == 15)
        d["BatteryData"] = nil
        d["AppleRawMaxCapacity"] = nil
        d["NominalChargeCapacity"] = 5000
        #expect(BatterySampler.parse(d, adapter: nil)?.fullChargeCapacity == 5000)
        d["Amperage"] = -1000
        d["ExternalConnected"] = false
        d["TimeRemainingEstimate"] = 7200
        #expect(BatterySampler.parse(d, adapter: nil)?.timeRemaining == 7200)
        d["ExternalConnected"] = true
        #expect(BatterySampler.parse(d, adapter: nil)?.timeRemaining == nil)
        d["Amperage"] = NSNumber(value: UInt64.max - 1625)
        #expect(BatterySampler.parse(d, adapter: nil)?.amperage == -1626)
    }

    @Test func sessionsIntegrateAndEnd() throws {
        let tracker = ChargeSessionTracker()
        let start = Date(timeIntervalSince1970: 1000)
        var b = BatteryStats()
        #expect(tracker.update(b, at: start) == nil)
        b.isPluggedIn = true; b.batteryPower = 10; b.percent = 40
        #expect(tracker.update(b, at: start)?.startPercent == 40)
        b.batteryPower = 20; b.percent = 41
        let session = try #require(tracker.update(b, at: start.addingTimeInterval(120)))
        #expect(session.energyWh == 0.5 && session.averageWatts == 15 && session.peakWatts == 20)
        #expect(session.gainedPercent == 1)
        b.isPluggedIn = false
        #expect(tracker.update(b, at: start.addingTimeInterval(130)) == nil)
        #expect(tracker.lastSession == session)
        b.isPluggedIn = true
        #expect(tracker.update(b, at: start.addingTimeInterval(140))?.energyWh == 0)
        #expect(tracker.lastSession == session)
    }

    @Test func sleepMissingSamplesAndPointRetention() throws {
        let tracker = ChargeSessionTracker()
        var b = BatteryStats(); b.isPluggedIn = true; b.batteryPower = 12
        let start = Date(timeIntervalSince1970: 1000)
        _ = tracker.update(b, at: start)
        #expect(tracker.update(b, at: start.addingTimeInterval(10))?.points.count == 1)
        #expect(tracker.update(b, at: start.addingTimeInterval(30))?.points.count == 2)
        let before = try #require(tracker.update(b, at: start.addingTimeInterval(30)))
        #expect(tracker.update(b, at: start.addingTimeInterval(331))?.energyWh == before.energyWh)
        _ = tracker.update(nil, at: start.addingTimeInterval(340))
        #expect(tracker.update(b, at: start.addingTimeInterval(350))?.energyWh == before.energyWh)
        for second in stride(from: 360, through: 90000, by: 10) {
            _ = tracker.update(b, at: start.addingTimeInterval(Double(second)))
        }
        let last = try #require(tracker.update(b, at: start.addingTimeInterval(90010)))
        #expect(last.points.count <= 2881)
        #expect(last.points.allSatisfy { $0.date >= start.addingTimeInterval(90010 - 86400) })
        #expect(zip(last.points, last.points.dropFirst()).allSatisfy { $1.date.timeIntervalSince($0.date) >= 30 })
    }

    @Test func idleTimeExcludedFromAverage() throws {
        let tracker = ChargeSessionTracker()
        var b = BatteryStats(); b.isPluggedIn = true
        let start = Date(timeIntervalSince1970: 1000)
        _ = tracker.update(b, at: start)
        _ = tracker.update(b, at: start.addingTimeInterval(60))
        b.batteryPower = 10
        let result = try #require(tracker.update(b, at: start.addingTimeInterval(120)))
        #expect(abs(result.energyWh - 1.0 / 12) < 0.000001)
        #expect(abs(result.averageWatts - 300.0 / 57) < 0.000001)
    }

    @Test func oldHistoryMigrationAndWeightedReadings() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("battery-test-\(UUID()).sqlite")
        defer {
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
        }
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        let oldSQL = """
            CREATE TABLE system (ts INTEGER NOT NULL, secs REAL NOT NULL, cpu REAL, mem REAL, gpu REAL,
                disk_r REAL, disk_w REAL, net_in REAL, net_out REAL, battery REAL, power REAL, on_battery INTEGER DEFAULT 0);
            INSERT INTO system VALUES (1000,60,10,20,30,40,50,60,70,83,46.661,0);
            PRAGMA user_version = 2;
            """
        #expect(sqlite3_exec(db, oldSQL, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)
        do {
            let store = HistoryStore(url: url)
            let old = try #require(store.batterySeries(from: Date(timeIntervalSince1970: 0), to: Date()).first)
            #expect(old.percent == 83 && old.batteryWatts == nil && old.adapterWatts == nil)
            let power = store.query("SELECT power FROM system WHERE ts = 1000") { sqlite3_column_double($0, 0) }
            #expect(power == [46.661])
            #expect(store.query("PRAGMA user_version") { sqlite3_column_int($0, 0) } == [3])
            var s = SystemSnapshot(); s.interval = 10
            var b = BatteryStats(); b.percent = 50; b.batteryPower = -10; b.adapterInputPower = 60
            s.battery = b; store.record(s)
            s.interval = 30; b.batteryPower = 30; b.adapterInputPower = 80; s.battery = b; store.record(s)
            s.interval = 20; s.battery = nil; store.record(s)
            store.flush()
            let row = try #require(store.batterySeries(from: Date().addingTimeInterval(-60), to: Date().addingTimeInterval(60)).last)
            #expect(row.batteryWatts == 20 && row.adapterWatts == 75 && row.percent == 50)
            s.battery = nil; store.record(s); store.flush()
            let missing = try #require(store.batterySeries(from: Date().addingTimeInterval(-60), to: Date().addingTimeInterval(60)).last)
            #expect(missing.percent == nil && missing.batteryWatts == nil && missing.adapterWatts == nil)
            #expect(store.batterySeries(from: Date(timeIntervalSince1970: 1001), to: Date(timeIntervalSince1970: 1002)).isEmpty)
        }
        let reopened = HistoryStore(url: url)
        #expect(reopened.batterySeries(from: Date(timeIntervalSince1970: 0), to: Date().addingTimeInterval(60)).count == 3)
    }

    @Test func holdBitsFromTheSMCMask() {
        func hold(_ code: Int, percent: Double = 80, charging: Bool = false, optimized: Bool = false, limit: Int? = nil) -> ChargeHold? {
            BatterySampler.hold(notChargingReason: code, percent: percent, isPluggedIn: true, isCharging: charging,
                                fullyCharged: false, batteryPower: 0, optimizedEngaged: optimized, chargeLimit: limit)
        }
        #expect(hold(0x1) == .full)
        #expect(hold(0x4) == .temperature)          // too hot, stop
        #expect(hold(0x10) == .temperature)         // too hot to start
        #expect(hold(1 << 24, limit: 80) == .chargeLimit(80))
        #expect(hold(0, percent: 80, limit: 80) == .chargeLimit(80))
        #expect(hold(0x8000, optimized: true) == .optimized)
        #expect(hold(1 << 23, charging: true) == nil) // BMS busy: charging continues
        #expect(hold(1 << 7) == nil)                  // no charger input for a moment
        #expect(hold((1 << 7) | 0x8000) == .other(code: 0x8000))
        #expect(BatterySampler.hold(notChargingReason: 0x1, percent: 100, isPluggedIn: false, isCharging: false,
                                    fullyCharged: true, batteryPower: -5) == nil)
    }

    @Test func chargeLimitFromPmset() {
        #expect(BatterySampler.parseChargeLimit("No battery level limits set") == nil)
        #expect(BatterySampler.parseChargeLimit("Battery level limits:\n chargeSocLimitSoc = 80\n") == 80)
        #expect(BatterySampler.parseChargeLimit("chargeSocLimitSoc: 100") == nil) // 100 = no limit
        #expect(BatterySampler.parseChargeLimit(nil) == nil)
    }
}
