import ActivityCore
import CoreLocation
import SwiftUI

/// Owns the scan: asks for Location access only when the user clicks Scan (macOS hides other networks'
/// names from apps without it), then scans once. Nothing here runs in the background.
@MainActor
@Observable
final class WiFiScanController: NSObject, CLLocationManagerDelegate {
    /// Snapshot-only sample (`ACTIVITYPLUS_FAKE_WIFI_SCAN=1`); never a real scan.
    static let fakeRequested = ProcessInfo.processInfo.environment["ACTIVITYPLUS_FAKE_WIFI_SCAN"] == "1"

    var result: WiFiScanResult?
    var scanning = false
    var error: String?
    var status: CLAuthorizationStatus
    private(set) var isSample = false
    private var pendingScan = false
    private let manager = CLLocationManager()

    override init() {
        status = manager.authorizationStatus
        super.init()
        manager.delegate = self
        if Self.fakeRequested {
            result = Self.sample
            isSample = true
        }
    }

    var hasAccess: Bool { status == .authorizedAlways || status == .authorized }
    var denied: Bool { status == .denied || status == .restricted }

    func scanTapped() {
        guard !scanning, !isSample else { return }
        error = nil
        if status == .notDetermined {
            // The explanation is on screen next to the button; this is the only place the prompt is triggered.
            pendingScan = true
            scanning = true
            manager.requestWhenInUseAuthorization()
        } else {
            scan()
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.status = status
            if self.pendingScan, status != .notDetermined {
                self.pendingScan = false
                self.scanning = false
                self.scan()
            }
        }
    }

    private func scan() {
        scanning = true
        Task.detached(priority: .userInitiated) {
            let outcome = Result { try WiFiScanner.scan() }
            await MainActor.run {
                switch outcome {
                case .success(let result): self.result = result; self.error = nil
                case .failure(let failure): self.error = String(localized: "The scan did not work: \(failure.localizedDescription)")
                }
                self.scanning = false
            }
        }
    }

    /// A made-up neighbourhood for layout checks: a busy 2.4 GHz channel 6, a calmer 5 GHz band, one 6 GHz network.
    static var sample: WiFiScanResult {
        func net(_ band: WiFiBand, _ channel: Int, _ rssi: Int, _ width: Int = 20) -> ScannedNetwork {
            ScannedNetwork(band: band, channel: channel, widthMHz: width, rssi: rssi)
        }
        var networks = [net(.ghz24, 6, -48, 20)]
        for (channel, rssi) in [(6, -60), (6, -71), (6, -78), (7, -66), (7, -82), (8, -70), (9, -75), (10, -88), (11, -64), (1, -79), (1, -86), (3, -90)] {
            networks.append(net(.ghz24, channel, rssi))
        }
        for (channel, rssi, width) in [(36, -62, 80), (44, -74, 40), (52, -80, 20), (100, -68, 80), (149, -77, 80), (157, -85, 20)] {
            networks.append(net(.ghz5, channel, rssi, width))
        }
        networks.append(net(.ghz6, 37, -72, 80))
        return WiFiScanResult(networks: networks, own: OwnWiFi(band: .ghz24, channel: 6, widthMHz: 20, rssi: -48, noise: -92))
    }
}

/// "Wi-Fi around you": one button, a bar chart per band, and a calm hint when another channel is clearly better.
struct WiFiScanCard: View {
    @Environment(Monitor.self) private var monitor
    @Environment(\.density) private var density
    @State private var controller = WiFiScanController()

    var body: some View {
        Card {
            HStack {
                CardHeader(title: "Wi-Fi around you", systemImage: "dot.radiowaves.left.and.right", tint: .teal)
                Spacer()
                if controller.scanning { ProgressView().controlSize(.small) }
                if !controller.isSample {
                    Button(controller.result == nil ? "Scan" : "Scan again") { controller.scanTapped() }
                        .disabled(controller.scanning)
                        .help("Listens once for nearby Wi-Fi networks. Activity+ never does this on its own.")
                }
            }
            if controller.isSample {
                Label("Sample data for screenshots, not a real scan", systemImage: "exclamationmark.triangle")
                    .appFont(.caption).foregroundStyle(.orange)
            }
            if let error = controller.error { Text(error).appFont(.callout).foregroundStyle(.red) }
            if let result = controller.result {
                content(result)
            } else if !controller.scanning {
                intro
            }
            if controller.result != nil || controller.denied { accessNote }
        }
    }

    // MARK: Before the first scan

    @ViewBuilder private var intro: some View {
        Text("Shows how many networks use each channel, so you can see whether yours is crowded.")
            .appFont(.callout).foregroundStyle(.secondary)
        if controller.status == .notDetermined {
            // One plain sentence before macOS asks.
            Text("To show network names, macOS asks for Location access once when you click Scan; Activity+ does not read where you are and works without it.")
                .appFont(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var accessNote: some View {
        if controller.denied {
            HStack(spacing: 4) {
                Text("Location access is off, so network names stay hidden. Channels and signal strengths still show.")
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
                    Link("Open Settings", destination: url)
                }
            }
            .appFont(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Results

    @ViewBuilder private func content(_ result: WiFiScanResult) -> some View {
        let advice = WiFiChannelAnalysis.advice(for: result)
        let overlap = WiFiChannelAnalysis.overlapCount(result)
        if result.networks.isEmpty {
            Text("The scan found no networks. If you are on Wi-Fi, try again in a moment.")
                .appFont(.callout).foregroundStyle(.secondary)
        }
        HStack(alignment: .top, spacing: density.grid * 2) {
            ownDetails(result, overlap: overlap)
                .frame(width: 250)
            VStack(alignment: .leading, spacing: density.cardLines) {
                ForEach(WiFiBand.allCases, id: \.self) { band in
                    BandChart(band: band, networks: result.networks, own: result.own)
                }
            }
        }
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(advice.lines.enumerated()), id: \.offset) { _, line in
                Text(line).appFont(.callout)
            }
            Text("Activity+ never changes router or Wi-Fi settings; this is only a hint for you.")
                .appFont(.caption).foregroundStyle(.secondary)
        }
        .padding(.top, 2)
    }

    @ViewBuilder private func ownDetails(_ result: WiFiScanResult, overlap: Int?) -> some View {
        let live = monitor.snapshot.wifi
        VStack(alignment: .leading, spacing: 6) {
            if let own = result.own {
                StatLine(label: "Your channel", value: "\(own.channel)")
                StatLine(label: "Band", value: own.band.title)
                StatLine(label: "Width", value: String(localized: "\(own.widthMHz) MHz"))
                if let rssi = (controller.isSample ? own.rssi : live?.rssi ?? own.rssi) {
                    StatLine(label: "Signal", value: String(localized: "\(rssi) dBm"))
                }
                if let noise = (controller.isSample ? own.noise : live?.noise ?? own.noise), noise != 0 {
                    StatLine(label: "Noise", value: String(localized: "\(noise) dBm"))
                }
                if let overlap {
                    StatLine(label: "Overlapping networks", value: "\(overlap)")
                }
            } else {
                Text("This Mac is not connected to Wi-Fi.").appFont(.callout).foregroundStyle(.secondary)
            }
            StatLine(label: "Networks seen", value: "\(result.networks.count)")
            if result.namesHidden {
                Text("Names are hidden by macOS.").appFont(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// Bars for one band: networks per channel, with the strongest signal beneath each. Your own channel is highlighted.
private struct BandChart: View {
    let band: WiFiBand
    let networks: [ScannedNetwork]
    let own: OwnWiFi?

    private var loads: [ChannelLoad] { WiFiChannelAnalysis.channelLoads(networks, band: band) }
    private var ownChannel: Int? { own.flatMap { $0.band == band ? $0.channel : nil } }

    private var channels: [Int] {
        if band == .ghz24 { return Array(1...13) }
        return Set(loads.map(\.channel)).union(ownChannel.map { [$0] } ?? []).sorted()
    }

    var body: some View {
        let byChannel = Dictionary(uniqueKeysWithValues: loads.map { ($0.channel, $0) })
        let maxCount = max(loads.map(\.count).max() ?? 1, 1)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(band.title).appFont(.subheadline).fontWeight(.semibold)
                Text(summary).appFont(.caption).foregroundStyle(.secondary)
            }
            if loads.isEmpty && ownChannel == nil {
                Text("No networks on this band.").appFont(.caption).foregroundStyle(.tertiary)
            } else {
                HStack(alignment: .bottom, spacing: 3) {
                    ForEach(channels, id: \.self) { channel in
                        column(channel, byChannel[channel], maxCount: maxCount)
                    }
                }
                .frame(maxWidth: CGFloat(max(channels.count, 6)) * 40, alignment: .leading)
            }
        }
    }

    private var summary: String {
        let total = loads.reduce(0) { $0 + $1.count }
        return total == 1 ? String(localized: "1 network") : String(localized: "\(total) networks")
    }

    private func column(_ channel: Int, _ load: ChannelLoad?, maxCount: Int) -> some View {
        let isOwn = channel == ownChannel
        let tint: Color = isOwn ? .teal : .secondary
        return VStack(spacing: 2) {
            Text(load.map { "\($0.count)" } ?? " ").appFont(.caption).monospacedDigit().foregroundStyle(.secondary)
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 3).fill(.quaternary.opacity(0.35)).frame(height: 44)
                if let load {
                    RoundedRectangle(cornerRadius: 3).fill(tint.opacity(isOwn ? 0.95 : 0.55))
                        .frame(height: max(4, 44 * CGFloat(load.count) / CGFloat(maxCount)))
                }
            }
            Text("\(channel)").appFont(.caption).monospacedDigit().fontWeight(isOwn ? .bold : .regular)
                .foregroundStyle(isOwn ? Color.teal : Color.primary)
            Text(load.map { "\($0.strongest)" } ?? " ").appFont(.caption2).monospacedDigit().foregroundStyle(.tertiary)
        }
        .frame(maxWidth: 40)
        .help(load.map { String(localized: "Channel \(channel): \($0.count), strongest \($0.strongest) dBm") } ?? String(localized: "Channel \(channel): none"))
    }
}
