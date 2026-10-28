import Foundation
import Testing
@testable import ActivityCore

@Suite("Wi-Fi channel scan")
struct WiFiScanTests {
    static func net(_ band: WiFiBand, _ channel: Int, _ rssi: Int = -70, width: Int = 20, ssid: String? = nil, bssid: String? = nil) -> ScannedNetwork {
        ScannedNetwork(ssid: ssid, bssid: bssid, band: band, channel: channel, widthMHz: width, rssi: rssi)
    }

    /// A crowded 2.4 GHz channel 6: the own access point plus nine neighbours on 6 to 10, two on channel 1.
    static var crowded24: WiFiScanResult {
        var networks = [net(.ghz24, 6, -45, ssid: "Home", bssid: "aa:aa:aa:aa:aa:01")]
        for channel in [6, 6, 6, 7, 7, 8, 8, 9, 10] { networks.append(net(.ghz24, channel, -62)) }
        networks += [net(.ghz24, 1, -80), net(.ghz24, 1, -85)]
        networks += [net(.ghz5, 36, -75), net(.ghz5, 44, -80)]
        return WiFiScanResult(networks: networks, own: OwnWiFi(band: .ghz24, channel: 6, widthMHz: 20, rssi: -45, noise: -92, ssid: "Home", bssid: "aa:aa:aa:aa:aa:01"))
    }

    @Test func overlapOn24GHzIsWithinFourChannels() {
        #expect(WiFiChannelAnalysis.overlaps((6, 20), (10, 20), band: .ghz24))
        #expect(!WiFiChannelAnalysis.overlaps((6, 20), (11, 20), band: .ghz24))
        #expect(WiFiChannelAnalysis.overlaps((1, 20), (5, 20), band: .ghz24))
        #expect(!WiFiChannelAnalysis.overlaps((1, 20), (6, 20), band: .ghz24))
    }

    @Test func overlapOn5GHzFollowsTheChannelBlock() {
        // 80 MHz at 36 covers 36-48.
        #expect(WiFiChannelAnalysis.overlaps((36, 80), (48, 20), band: .ghz5))
        #expect(!WiFiChannelAnalysis.overlaps((36, 80), (52, 20), band: .ghz5))
        // 20 MHz channels next to each other do not overlap.
        #expect(!WiFiChannelAnalysis.overlaps((36, 20), (40, 20), band: .ghz5))
        // 40 MHz at 40 is the block 36-40.
        #expect(WiFiChannelAnalysis.overlaps((40, 40), (36, 20), band: .ghz5))
        // The upper block starts at 149; 160 MHz at 100 spans 100-128.
        #expect(WiFiChannelAnalysis.overlaps((149, 80), (161, 20), band: .ghz5))
        #expect(!WiFiChannelAnalysis.overlaps((149, 80), (144, 20), band: .ghz5))
        #expect(WiFiChannelAnalysis.overlaps((100, 160), (128, 20), band: .ghz5))
        #expect(!WiFiChannelAnalysis.overlaps((100, 160), (132, 20), band: .ghz5))
    }

    @Test func overlapOn6GHzFollowsTheChannelBlock() {
        #expect(WiFiChannelAnalysis.overlaps((1, 80), (13, 20), band: .ghz6))
        #expect(!WiFiChannelAnalysis.overlaps((1, 80), (17, 20), band: .ghz6))
    }

    @Test func channelLoadsCountAndStrongest() {
        let loads = WiFiChannelAnalysis.channelLoads(Self.crowded24.networks, band: .ghz24)
        #expect(loads.map(\.channel) == [1, 6, 7, 8, 9, 10])
        let six = loads.first { $0.channel == 6 }
        #expect(six?.count == 4)
        #expect(six?.strongest == -45)
        #expect(WiFiChannelAnalysis.channelLoads(Self.crowded24.networks, band: .ghz6).isEmpty)
    }

    @Test func ownAccessPointIsNotCountedAsNeighbour() {
        #expect(WiFiChannelAnalysis.overlapCount(Self.crowded24) == 9)
    }

    @Test func ownAccessPointIsFoundWithoutNamesBySignal() {
        // Names hidden: the entry on the own channel with a similar signal is the own router.
        let hidden = WiFiScanResult(
            networks: [Self.net(.ghz24, 6, -47), Self.net(.ghz24, 6, -80), Self.net(.ghz24, 7, -70)],
            own: OwnWiFi(band: .ghz24, channel: 6, rssi: -45))
        #expect(hidden.namesHidden)
        #expect(WiFiChannelAnalysis.overlapCount(hidden) == 2)
    }

    @Test func congestionWeighsStrongNeighboursMore() {
        let strong = WiFiChannelAnalysis.congestion(of: [Self.net(.ghz24, 6, -45)])
        let weak = WiFiChannelAnalysis.congestion(of: [Self.net(.ghz24, 6, -85)])
        #expect(strong == 1)
        #expect(weak < 0.2)
        #expect(WiFiChannelAnalysis.congestion(of: []) == 0)
    }

    @Test func adviceOnCrowded24GHzNamesChannelAndFiveGHz() {
        let advice = WiFiChannelAnalysis.advice(for: Self.crowded24)
        #expect(advice.betterChannel == 1)
        #expect(advice.suggestsFiveGHz)
        #expect(advice.lines.first?.contains("channel 6") == true)
        #expect(advice.lines.first?.contains("9 networks") == true)
        #expect(advice.lines.contains { $0.contains("Channel 1 is quieter: only 2 networks use it.") })
        #expect(advice.lines.contains { $0.contains("prefer 5 GHz") })
    }

    @Test func quietChannelGetsNoAdvice() {
        let result = WiFiScanResult(
            networks: [Self.net(.ghz5, 36, -50, ssid: "Home"), Self.net(.ghz5, 100, -70), Self.net(.ghz24, 1, -80)],
            own: OwnWiFi(band: .ghz5, channel: 36, widthMHz: 80, rssi: -50, noise: -92, ssid: "Home"))
        let advice = WiFiChannelAnalysis.advice(for: result)
        #expect(advice.betterChannel == nil)
        #expect(!advice.suggestsFiveGHz)
        #expect(advice.lines.contains { $0.contains("Nothing to change") })
    }

    @Test func noAdviceWhenTheAlternativeIsNotClearlyBetter() {
        // Every 2.4 GHz channel is busy: 4 neighbours on 6, others on 1 and 11 just as many.
        var networks = [Self.net(.ghz24, 6, -50, ssid: "Home")]
        for channel in [6, 6, 7, 5] { networks.append(Self.net(.ghz24, channel, -60)) }
        for channel in [1, 1, 2, 3] { networks.append(Self.net(.ghz24, channel, -60)) }
        for channel in [11, 11, 10, 12] { networks.append(Self.net(.ghz24, channel, -60)) }
        for channel in [36, 40, 44, 48, 149, 153, 157, 161, 165] { for _ in 0..<3 { networks.append(Self.net(.ghz5, channel, -50)) } }
        let result = WiFiScanResult(networks: networks, own: OwnWiFi(band: .ghz24, channel: 6, rssi: -50, ssid: "Home"))
        let advice = WiFiChannelAnalysis.advice(for: result)
        #expect(advice.betterChannel == nil)
        #expect(!advice.suggestsFiveGHz)
    }

    @Test func adviceWithoutWiFiExplainsWhy() {
        let advice = WiFiChannelAnalysis.advice(for: WiFiScanResult(networks: [], own: nil))
        #expect(advice.betterChannel == nil)
        #expect(advice.lines.count == 1)
        #expect(WiFiChannelAnalysis.overlapCount(WiFiScanResult(networks: [], own: nil)) == nil)
    }

    @Test func lowSignalToNoiseGetsAGentleNote() {
        let result = WiFiScanResult(networks: [], own: OwnWiFi(band: .ghz5, channel: 36, widthMHz: 80, rssi: -85, noise: -90))
        #expect(WiFiChannelAnalysis.advice(for: result).lines.contains { $0.contains("5 dB above the noise") })
    }
}
