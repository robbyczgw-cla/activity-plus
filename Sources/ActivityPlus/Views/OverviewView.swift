import ActivityCore
import SwiftUI

/// The cards on the Overview page; order and visibility are chosen in Settings → Window.
enum OverviewCard: String, CaseIterable, Identifiable {
    case cpu, memory, gpu, disk, network, battery, temperature, insights, busiest
    var id: String { rawValue }
    var title: String {
        switch self {
        case .cpu: "CPU"
        case .memory: "Memory"
        case .gpu: "GPU"
        case .disk: "Disk"
        case .network: "Network"
        case .battery: "Battery"
        case .temperature: "Temperatures"
        case .insights: "Unusual activity"
        case .busiest: "Busiest right now"
        }
    }

    static let defaultOrder = allCases.map(\.rawValue).joined(separator: ",")

    /// The stored order, with cards added in newer versions appended at the end.
    static func ordered(_ stored: String) -> [OverviewCard] {
        var cards = stored.split(separator: ",").compactMap { OverviewCard(rawValue: String($0)) }
        for card in allCases where !cards.contains(card) { cards.append(card) }
        return cards
    }
}

struct OverviewView: View {
    @Environment(Monitor.self) private var monitor
    @Environment(AppServices.self) private var services
    @Binding var selection: SidebarItem?
    @AppStorage("overviewCards") private var cardOrder = OverviewCard.defaultOrder
    @AppStorage("hiddenOverviewCards") private var hiddenCards = ""

    private let columns = [GridItem(.adaptive(minimum: 250, maximum: 420), spacing: 14)]

    private var visible: [OverviewCard] {
        let hidden = Set(hiddenCards.split(separator: ",").map(String.init))
        return OverviewCard.ordered(cardOrder).filter { !hidden.contains($0.rawValue) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(visible.filter { $0 != .busiest && $0 != .insights }) { card in tile(card) }
                }
                if visible.contains(.insights), !services.anomalies.isEmpty {
                    InsightsCard(anomalies: services.anomalies)
                }
                if visible.contains(.busiest) {
                    Card {
                        CardHeader(title: "Busiest right now", systemImage: "flame", tint: .orange,
                                   trailing: "\(monitor.snapshot.processCount) processes in \(monitor.snapshot.apps.count) apps")
                        AppListView(metric: .cpu, limit: 8)
                    }
                }
            }
            .padding(20)
        }
    }

    @ViewBuilder private func tile(_ card: OverviewCard) -> some View {
        let s = monitor.snapshot
        let h = monitor.history
        switch card {
        case .cpu:
            button(.metric(.cpu)) {
                CardHeader(title: "CPU", systemImage: "cpu", tint: Metric.cpu.tint, trailing: "Now")
                BigNumber(text: Format.percent(s.cpu.total))
                Sparkline(values: h.cpu.values, tint: Metric.cpu.tint, maxValue: 100).frame(height: 38)
                StatLine(label: "User", value: Format.percent(s.cpu.user))
                StatLine(label: "System", value: Format.percent(s.cpu.system))
                StatLine(label: "Average (10 min)", value: Format.percent(h.cpu.average))
            }
        case .memory:
            button(.metric(.memory)) {
                CardHeader(title: "Memory", systemImage: "memorychip", tint: Metric.memory.tint,
                           trailing: "In use of \(Format.memory(s.memory.total))")
                HStack(alignment: .firstTextBaseline) {
                    BigNumber(text: Format.memory(s.memory.used))
                    Spacer()
                    PressureBadge(pressure: s.memory.pressure)
                }
                Sparkline(values: h.memory.values, tint: Metric.memory.tint, maxValue: Double(s.memory.total)).frame(height: 38)
                StatLine(label: "App", value: Format.memory(s.memory.app))
                StatLine(label: "Wired", value: Format.memory(s.memory.wired))
                StatLine(label: "Compressed", value: Format.memory(s.memory.compressed))
            }
        case .gpu:
            if let gpu = s.gpu {
                button(.metric(.gpu)) {
                    CardHeader(title: "GPU", systemImage: "square.stack.3d.up", tint: Metric.gpu.tint, trailing: gpu.name)
                    BigNumber(text: Format.percent(gpu.utilization))
                    Sparkline(values: h.gpu.values, tint: Metric.gpu.tint, maxValue: 100).frame(height: 38)
                    StatLine(label: "Memory", value: Format.memory(gpu.memoryInUse))
                    StatLine(label: "Average", value: Format.percent(h.gpu.average))
                    StatLine(label: "Peak", value: Format.percent(h.gpu.peak))
                }
            }
        case .disk:
            button(.metric(.disk)) {
                CardHeader(title: "Disk", systemImage: "internaldrive", tint: Metric.disk.tint,
                           trailing: "Free of \(Format.storage(s.disk.total))")
                BigNumber(text: Format.storage(s.disk.free))
                Sparkline(values: zip(h.diskRead.values, h.diskWrite.values).map(+), tint: Metric.disk.tint).frame(height: 38)
                StatLine(label: "Reading", value: Format.rate(s.disk.readRate))
                StatLine(label: "Writing", value: Format.rate(s.disk.writeRate))
                StatLine(label: "Written today", value: Format.storage(UInt64(max(services.today.diskWritten, Double(s.disk.writtenSinceLaunch)))))
            }
        case .network:
            button(.metric(.network)) {
                CardHeader(title: "Network", systemImage: "network", tint: Metric.network.tint, trailing: "Downloading")
                BigNumber(text: Format.networkRate(s.network.inRate))
                Sparkline(values: h.netIn.values, tint: Metric.network.tint).frame(height: 38)
                StatLine(label: "Uploading", value: Format.networkRate(s.network.outRate))
                StatLine(label: "Today", value: Format.storage(UInt64(max(services.today.received + services.today.sent,
                                                                           Double(s.network.receivedSinceLaunch + s.network.sentSinceLaunch)))))
                StatLine(label: "Last 7 days", value: Format.storage(UInt64(max(services.week.received + services.week.sent,
                                                                                 Double(s.network.receivedSinceLaunch + s.network.sentSinceLaunch)))))
            }
        case .battery:
            if let battery = s.battery {
                button(.battery) {
                    CardHeader(title: "Battery", systemImage: BatteryView.symbol(for: battery), tint: .green,
                               trailing: BatteryView.stateText(battery))
                    BigNumber(text: Format.percent(battery.percent))
                    Sparkline(values: h.battery.values, tint: .green, maxValue: 100).frame(height: 38)
                    StatLine(label: "Remaining", value: battery.timeRemaining.map(Format.duration) ?? "–")
                    StatLine(label: "Power draw", value: battery.systemPower.map(Format.watts) ?? "–")
                    StatLine(label: "Health", value: battery.health.map { Format.percent($0) } ?? "–")
                }
            }
        case .temperature:
            if let temperature = s.sensors.cpuTemperature {
                button(.sensors) {
                    CardHeader(title: "Temperatures", systemImage: "thermometer.medium", tint: SensorsView.color(for: temperature),
                               trailing: s.thermal.rawValue)
                    BigNumber(text: Format.temperature(temperature))
                    Sparkline(values: h.cpuTemperature.values, tint: .red).frame(height: 38)
                    if let gpu = s.sensors.gpuTemperature { StatLine(label: "GPU", value: Format.temperature(gpu)) }
                    ForEach(s.sensors.fans.prefix(2), id: \.name) { fan in
                        StatLine(label: fan.name, value: "\(Int(fan.rpm)) rpm")
                    }
                }
            }
        case .insights, .busiest:
            EmptyView()
        }
    }

    private func button<Content: View>(_ target: SidebarItem, @ViewBuilder content: () -> Content) -> some View {
        Button { selection = target } label: { Card { content() } }
            .buttonStyle(.plain)
    }
}

/// Apps doing something unusual compared with their own history.
struct InsightsCard: View {
    let anomalies: [Anomaly]

    var body: some View {
        Card {
            CardHeader(title: "Unusual activity", systemImage: "sparkle.magnifyingglass", tint: .purple, trailing: "compared with the last 7 days")
            ForEach(anomalies) { anomaly in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: anomaly.kind == .leak ? "drop.triangle" : (anomaly.kind == .cpu ? "cpu" : "memorychip"))
                        .foregroundStyle(.purple).frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(anomaly.title).fontWeight(.medium)
                        Text(anomaly.detail).font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

struct PressureBadge: View {
    let pressure: MemoryPressure

    var body: some View {
        Text(pressure.label)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    private var color: Color {
        switch pressure {
        case .normal: .green
        case .warning: .orange
        case .critical: .red
        }
    }
}
