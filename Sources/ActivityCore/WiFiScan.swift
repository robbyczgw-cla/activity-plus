import CoreWLAN
import Foundation

/// A Wi-Fi band as the channel scan sees it.
public enum WiFiBand: String, Sendable, Hashable, CaseIterable {
    case ghz24, ghz5, ghz6

    public var title: String {
        switch self {
        case .ghz24: String(localized: "2.4 GHz")
        case .ghz5: String(localized: "5 GHz")
        case .ghz6: String(localized: "6 GHz")
        }
    }
}

/// One access point seen by a scan. `ssid`/`bssid` are nil when macOS withholds them (no Location access).
public struct ScannedNetwork: Sendable, Hashable {
    public let ssid: String?
    public let bssid: String?
    public let band: WiFiBand
    /// Primary 20 MHz channel number.
    public let channel: Int
    /// Channel width in MHz (20, 40, 80, 160); 20 when unknown.
    public let widthMHz: Int
    public let rssi: Int

    public init(ssid: String? = nil, bssid: String? = nil, band: WiFiBand, channel: Int, widthMHz: Int = 20, rssi: Int) {
        self.ssid = ssid; self.bssid = bssid; self.band = band; self.channel = channel
        self.widthMHz = widthMHz > 0 ? widthMHz : 20; self.rssi = rssi
    }
}

/// The Mac's own connection, as far as the scan needs it.
public struct OwnWiFi: Sendable, Hashable {
    public let band: WiFiBand
    public let channel: Int
    public let widthMHz: Int
    public let rssi: Int?
    public let noise: Int?
    public let ssid: String?
    public let bssid: String?

    public init(band: WiFiBand, channel: Int, widthMHz: Int = 20, rssi: Int? = nil, noise: Int? = nil, ssid: String? = nil, bssid: String? = nil) {
        self.band = band; self.channel = channel; self.widthMHz = widthMHz > 0 ? widthMHz : 20
        self.rssi = rssi; self.noise = noise; self.ssid = ssid; self.bssid = bssid
    }
}

/// What one scan returned, plus the interface's own channel at that moment.
public struct WiFiScanResult: Sendable {
    public let networks: [ScannedNetwork]
    public let own: OwnWiFi?
    /// True when no network came back with a name, which is what macOS does without Location access.
    public var namesHidden: Bool { !networks.isEmpty && networks.allSatisfy { $0.ssid == nil } }

    public init(networks: [ScannedNetwork], own: OwnWiFi?) {
        self.networks = networks; self.own = own
    }
}

/// How busy one channel is.
public struct ChannelLoad: Sendable, Hashable, Identifiable {
    public let channel: Int
    public let count: Int
    /// Strongest signal on this channel in dBm.
    public let strongest: Int
    public var id: Int { channel }
}

/// Calm advice built from a scan. `lines` are ready to show, in order.
public struct WiFiAdvice: Sendable, Equatable {
    public let lines: [String]
    /// A better channel in the same band, when one is clearly better.
    public let betterChannel: Int?
    /// True when the advice mentions moving from 2.4 GHz to 5 GHz.
    public let suggestsFiveGHz: Bool
}

public enum WiFiChannelAnalysis {
    // MARK: Channel geometry

    /// Lower and upper edge of the spectrum a network occupies, in MHz. For 5 and 6 GHz the block of the
    /// channel width that holds the primary channel (36-48 for 80 MHz at channel 36 and so on).
    static func span(band: WiFiBand, channel: Int, widthMHz: Int) -> ClosedRange<Double> {
        let width = Double(max(20, widthMHz))
        switch band {
        case .ghz24:
            let center = channel == 14 ? 2484.0 : 2407.0 + 5.0 * Double(channel)
            return (center - width / 2)...(center + width / 2)
        case .ghz5:
            let lowerEdge = 5000.0 + 5.0 * Double(channel) - 10
            let base: Double = channel >= 149 ? 5735 : channel >= 100 ? 5490 : 5170
            let start = base + max(0, ((lowerEdge - base) / width).rounded(.down)) * width
            return start...(start + width)
        case .ghz6:
            let lowerEdge = 5950.0 + 5.0 * Double(channel) - 10
            let start = 5945 + max(0, ((lowerEdge - 5945) / width).rounded(.down)) * width
            return start...(start + width)
        }
    }

    /// Whether two networks in the same band disturb each other. 2.4 GHz: channel numbers within four
    /// (the 20 MHz channels are only five MHz apart); 5 and 6 GHz: their channel blocks overlap.
    public static func overlaps(_ a: (channel: Int, widthMHz: Int), _ b: (channel: Int, widthMHz: Int), band: WiFiBand) -> Bool {
        switch band {
        case .ghz24:
            return abs(a.channel - b.channel) <= 4
        case .ghz5, .ghz6:
            let x = span(band: band, channel: a.channel, widthMHz: a.widthMHz)
            let y = span(band: band, channel: b.channel, widthMHz: b.widthMHz)
            return x.lowerBound < y.upperBound && y.lowerBound < x.upperBound
        }
    }

    // MARK: Counting

    /// Networks per channel for one band, sorted by channel.
    public static func channelLoads(_ networks: [ScannedNetwork], band: WiFiBand) -> [ChannelLoad] {
        let inBand = networks.filter { $0.band == band }
        return Dictionary(grouping: inBand, by: \.channel).map { channel, items in
            ChannelLoad(channel: channel, count: items.count, strongest: items.map(\.rssi).max() ?? -100)
        }.sorted { $0.channel < $1.channel }
    }

    /// Index of the scanned entry that is the Mac's own access point, if it can be told apart.
    /// By BSSID when both sides have one, then by name on the same channel, then (names hidden) the
    /// entry on the same channel whose signal is within 6 dB of the own one.
    static func ownIndex(in networks: [ScannedNetwork], own: OwnWiFi) -> Int? {
        let sameChannel = networks.indices.filter { networks[$0].band == own.band && networks[$0].channel == own.channel }
        if let bssid = own.bssid?.lowercased(), let hit = networks.indices.first(where: { networks[$0].bssid?.lowercased() == bssid }) { return hit }
        if let ssid = own.ssid, let hit = sameChannel.first(where: { networks[$0].ssid == ssid }) { return hit }
        guard let rssi = own.rssi else { return nil }
        let nearest = sameChannel
            .filter { networks[$0].ssid == nil }
            .min { abs(networks[$0].rssi - rssi) < abs(networks[$1].rssi - rssi) }
        guard let nearest, abs(networks[nearest].rssi - rssi) <= 6 else { return nil }
        return nearest
    }

    /// Other networks that overlap the given channel and width, the Mac's own access point left out.
    public static func overlapping(_ networks: [ScannedNetwork], band: WiFiBand, channel: Int, widthMHz: Int, excluding ownIndex: Int? = nil) -> [ScannedNetwork] {
        networks.enumerated().compactMap { index, network in
            guard index != ownIndex, network.band == band,
                  overlaps((channel, widthMHz), (network.channel, network.widthMHz), band: band) else { return nil }
            return network
        }
    }

    /// How many other networks overlap the Mac's own channel; nil when it is not on Wi-Fi.
    public static func overlapCount(_ result: WiFiScanResult) -> Int? {
        guard let own = result.own else { return nil }
        return overlapping(result.networks, band: own.band, channel: own.channel, widthMHz: own.widthMHz,
                           excluding: ownIndex(in: result.networks, own: own)).count
    }

    /// Congestion of a channel: every overlapping network counts, strong ones more (1.0 at -50 dBm and
    /// above, down to 0.1 at -86 dBm and below).
    public static func congestion(of networks: [ScannedNetwork]) -> Double {
        networks.reduce(0) { $0 + min(1, max(0.1, Double($1.rssi + 90) / 40)) }
    }

    // MARK: Advice

    /// Channels worth suggesting: the usual non-overlapping ones on 2.4 GHz, and on 5/6 GHz those that
    /// need no radar check (so the router will not have to leave them).
    static func candidates(band: WiFiBand, widthMHz: Int) -> [Int] {
        switch band {
        case .ghz24: return [1, 6, 11]
        case .ghz5:
            return widthMHz >= 160 ? [36] : widthMHz >= 80 ? [36, 149] : widthMHz >= 40 ? [36, 44, 149, 157] : [36, 40, 44, 48, 149, 153, 157, 161, 165]
        case .ghz6:
            return Array(stride(from: 1, through: 93, by: max(4, widthMHz / 5)))
        }
    }

    /// The quietest candidate in a band for a given width, with the networks that would share it.
    static func quietest(_ networks: [ScannedNetwork], band: WiFiBand, widthMHz: Int, excluding ownIndex: Int?, not channel: Int? = nil) -> (channel: Int, shared: [ScannedNetwork])? {
        candidates(band: band, widthMHz: widthMHz)
            .filter { $0 != channel }
            .map { ($0, overlapping(networks, band: band, channel: $0, widthMHz: widthMHz, excluding: ownIndex)) }
            .min { congestion(of: $0.1) < congestion(of: $1.1) }
            .map { (channel: $0.0, shared: $0.1) }
    }

    /// Advice only when the change is clearly better: the own channel is shared with at least three
    /// networks, and the alternative has at most a third of them and half the congestion.
    public static func advice(for result: WiFiScanResult) -> WiFiAdvice {
        guard let own = result.own else {
            return WiFiAdvice(lines: [String(localized: "This Mac is not connected to Wi-Fi, so there is no channel to compare.")], betterChannel: nil, suggestsFiveGHz: false)
        }
        let index = ownIndex(in: result.networks, own: own)
        let shared = overlapping(result.networks, band: own.band, channel: own.channel, widthMHz: own.widthMHz, excluding: index)
        let count = shared.count
        let ownScore = congestion(of: shared)
        var lines: [String] = []
        var better: Int?
        var five = false

        func clearlyBetter(_ other: [ScannedNetwork]) -> Bool {
            other.count * 3 <= count && congestion(of: other) <= ownScore * 0.5
        }

        let mine = String(localized: "Your router uses \(own.band.title) channel \(own.channel)")
        lines.append(count == 0 ? String(localized: "\(mine) and shares it with no other network.")
                     : count == 1 ? String(localized: "\(mine), shared with 1 other network.")
                     : String(localized: "\(mine), shared with \(count) networks."))

        if count >= 3 {
            if let best = quietest(result.networks, band: own.band, widthMHz: own.widthMHz, excluding: index, not: own.channel),
               clearlyBetter(best.shared) {
                better = best.channel
                let n = best.shared.count
                lines.append(n == 0 ? String(localized: "Channel \(best.channel) has none.")
                             : n == 1 ? String(localized: "Channel \(best.channel) has 1.")
                             : String(localized: "Channel \(best.channel) has \(n)."))
            }
            // The simplest improvement on 2.4 GHz is another band altogether.
            if own.band == .ghz24,
               let fiveGHz = quietest(result.networks, band: .ghz5, widthMHz: 20, excluding: nil),
               clearlyBetter(fiveGHz.shared) {
                five = true
                lines.append(String(localized: "If your router can, prefer 5 GHz."))
            }
        }

        if let rssi = own.rssi, let noise = own.noise, noise != 0, rssi - noise < 15 {
            lines.append(String(localized: "The signal is only \(rssi - noise) dB above the noise. A channel change will not fix that; moving closer to the router will."))
        }
        if lines.count == 1 {
            lines.append(String(localized: "Nothing to change."))
        }
        return WiFiAdvice(lines: lines, betterChannel: better, suggestsFiveGHz: five)
    }
}

/// The real scan. Blocks for a few seconds; never call it from the main actor.
public enum WiFiScanner {
    public static func scan() throws -> WiFiScanResult {
        guard let interface = CWWiFiClient.shared().interface() else {
            return WiFiScanResult(networks: [], own: nil)
        }
        let found = try interface.scanForNetworks(withSSID: nil)
        let networks: [ScannedNetwork] = found.compactMap { network in
            guard let channel = network.wlanChannel, let band = band(channel.channelBand) else { return nil }
            return ScannedNetwork(ssid: network.ssid, bssid: network.bssid, band: band, channel: channel.channelNumber,
                                  widthMHz: width(channel.channelWidth), rssi: network.rssiValue)
        }
        var own: OwnWiFi?
        if let channel = interface.wlanChannel(), let band = band(channel.channelBand) {
            let noise = interface.noiseMeasurement()
            own = OwnWiFi(band: band, channel: channel.channelNumber, widthMHz: width(channel.channelWidth),
                          rssi: interface.rssiValue(), noise: noise == 0 ? nil : noise, ssid: interface.ssid(), bssid: interface.bssid())
        }
        return WiFiScanResult(networks: networks, own: own)
    }

    static func band(_ band: CWChannelBand) -> WiFiBand? {
        switch band {
        case .band2GHz: .ghz24
        case .band5GHz: .ghz5
        case .band6GHz: .ghz6
        case .bandUnknown: nil
        @unknown default: nil
        }
    }

    static func width(_ width: CWChannelWidth) -> Int {
        switch width {
        case .width20MHz: 20
        case .width40MHz: 40
        case .width80MHz: 80
        case .width160MHz: 160
        case .widthUnknown: 20
        @unknown default: 20
        }
    }
}
