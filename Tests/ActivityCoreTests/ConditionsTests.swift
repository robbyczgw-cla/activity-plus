import Foundation
import Testing
@testable import ActivityCore

@Suite("History conditions")
struct ConditionsTests {
    /// The worst heat and memory pressure of a minute are kept, Wi-Fi signal and noise are averaged.
    @Test func worstHeatAndPressureAverageSignal() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("conditions-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = HistoryStore(url: url)
        var s = SystemSnapshot(); s.interval = 10
        s.thermal = .fair; s.memory.pressure = .normal
        s.wifi = WiFiInfo(ssid: "Home", rssi: -50, noise: -90, channel: 36, band: "5 GHz", transmitRateMbps: 600)
        store.record(s)
        s.thermal = .serious; s.memory.pressure = .warning
        s.wifi = WiFiInfo(ssid: "Home", rssi: -70, noise: -92, channel: 36, band: "5 GHz", transmitRateMbps: 300)
        store.record(s)
        s.thermal = .nominal; s.memory.pressure = .normal; s.wifi = nil
        store.record(s)
        store.flush()
        let point = try #require(store.systemSeries(.hours12, until: Date().addingTimeInterval(60)).last)
        #expect(point.thermal == 2)
        #expect(point.pressure == MemoryPressure.warning.rawValue)
        #expect(point.wifiRSSI == -60)
        #expect(point.wifiNoise == -91)
    }

    @Test func noWifiMeansNoSignal() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("conditions-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = HistoryStore(url: url)
        var s = SystemSnapshot(); s.interval = 10
        store.record(s); store.flush()
        let point = try #require(store.systemSeries(.hours12, until: Date().addingTimeInterval(60)).last)
        #expect(point.wifiRSSI == nil)
        #expect(point.thermal == 0)
    }
}
