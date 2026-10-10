import Foundation
import Testing
@testable import ActivityCore

@Suite("Network quality")
struct NetworkQualityTests {
    /// Trimmed from a real `networkQuality -c -s` run (macOS 27).
    static let sample = """
    {
      "base_rtt" : 84.644615173339844,
      "dl_bytes_transferred" : 339224896,
      "dl_flows" : 9,
      "dl_responsiveness" : 258.472412109375,
      "dl_throughput" : 150006896,
      "end_date" : "2026-10-10 20:37:40.984",
      "interface_name" : "en0",
      "start_date" : "2026-10-10 20:36:55.512",
      "test_endpoint" : "defra1-edge-fx-010.aaplimg.com",
      "ul_bytes_transferred" : 90832894,
      "ul_flows" : 16,
      "ul_responsiveness" : 24.104991912841797,
      "ul_throughput" : 40517048
    }
    """

    static func json(_ overrides: [String: String]) -> Data {
        var fields: [String: String] = [
            "dl_throughput": "150006896", "ul_throughput": "40517048", "dl_responsiveness": "258.5",
            "ul_responsiveness": "24.1", "base_rtt": "84.6", "interface_name": "\"en0\"", "test_endpoint": "\"edge.example\"",
        ]
        fields.merge(overrides) { _, new in new }
        let body = fields.sorted { $0.key < $1.key }.map { "\"\($0.key)\" : \($0.value)" }.joined(separator: ",")
        return Data("{\(body)}".utf8)
    }

    @Test func parsesRealOutput() throws {
        let result = try #require(NetworkQuality.parse(Data(Self.sample.utf8), date: Date(timeIntervalSince1970: 0)))
        #expect(abs(result.downloadMbps - 150.006896) < 0.000001)
        #expect(abs(result.uploadMbps - 40.517048) < 0.000001)
        #expect(abs((result.downloadRPM ?? 0) - 258.472) < 0.001)
        #expect(abs((result.uploadRPM ?? 0) - 24.105) < 0.001)
        #expect(abs((result.idleLatencyMs ?? 0) - 84.645) < 0.001)
        #expect(result.interface == "en0")
        #expect(result.endpoint == "defra1-edge-fx-010.aaplimg.com")
        #expect(result.date == Date(timeIntervalSince1970: 0))
    }

    @Test func headlineRPMIsTheSlowerDirection() throws {
        let result = try #require(NetworkQuality.parse(Data(Self.sample.utf8)))
        #expect(abs((result.responsivenessRPM ?? 0) - 24.105) < 0.001)
        #expect(result.rating == .low)
    }

    @Test func ratingBands() {
        #expect(NetworkQuality.rating(forRPM: 0) == .low)
        #expect(NetworkQuality.rating(forRPM: 299.9) == .low)
        #expect(NetworkQuality.rating(forRPM: 300) == .medium)
        #expect(NetworkQuality.rating(forRPM: 1000) == .medium)
        #expect(NetworkQuality.rating(forRPM: 1000.1) == .high)
    }

    @Test func missingThroughputIsNotAResult() {
        #expect(NetworkQuality.parse(Data("{}".utf8)) == nil)
        #expect(NetworkQuality.parse(Data("not json".utf8)) == nil)
        #expect(NetworkQuality.parse(Self.json(["ul_throughput": "\"n/a\""])) == nil)
    }

    @Test func missingRPMStillParses() throws {
        let result = try #require(NetworkQuality.parse(Self.json(["ul_responsiveness": "null"])))
        #expect(result.uploadRPM == nil)
        #expect(result.responsivenessRPM == result.downloadRPM)
    }

    @Test func historyKeepsTenNewestFirst() throws {
        var history: [NetworkQualityResult] = []
        for index in 0..<12 {
            let result = try #require(NetworkQuality.parse(Self.json([:]), date: Date(timeIntervalSince1970: TimeInterval(index))))
            history = NetworkQuality.history(adding: result, to: history)
        }
        #expect(history.count == 10)
        #expect(history.first?.date == Date(timeIntervalSince1970: 11))
        #expect(history.last?.date == Date(timeIntervalSince1970: 2))
    }
}
