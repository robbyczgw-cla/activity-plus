import ActivityCore
import SwiftUI

struct OverviewView: View {
    @Environment(Monitor.self) private var monitor
    @Binding var selection: SidebarItem?

    private let columns = [GridItem(.adaptive(minimum: 250, maximum: 420), spacing: 14)]

    var body: some View {
        let s = monitor.snapshot
        let h = monitor.history
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                LazyVGrid(columns: columns, spacing: 14) {
                    tile(.metric(.cpu)) {
                        CardHeader(title: "CPU", systemImage: "cpu", tint: Metric.cpu.tint, trailing: "Now")
                        BigNumber(text: Format.percent(s.cpu.total))
                        Sparkline(values: h.cpu.values, tint: Metric.cpu.tint, maxValue: 100).frame(height: 38)
                        StatLine(label: "User", value: Format.percent(s.cpu.user))
                        StatLine(label: "System", value: Format.percent(s.cpu.system))
                        StatLine(label: "Average (10 min)", value: Format.percent(h.cpu.average))
                    }
                    tile(.metric(.memory)) {
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
                    if let gpu = s.gpu {
                        tile(.metric(.gpu)) {
                            CardHeader(title: "GPU", systemImage: "square.stack.3d.up", tint: Metric.gpu.tint, trailing: gpu.name)
                            BigNumber(text: Format.percent(gpu.utilization))
                            Sparkline(values: h.gpu.values, tint: Metric.gpu.tint, maxValue: 100).frame(height: 38)
                            StatLine(label: "Memory", value: Format.memory(gpu.memoryInUse))
                            StatLine(label: "Average", value: Format.percent(h.gpu.average))
                            StatLine(label: "Peak", value: Format.percent(h.gpu.peak))
                        }
                    }
                    tile(.metric(.disk)) {
                        CardHeader(title: "Disk", systemImage: "internaldrive", tint: Metric.disk.tint,
                                   trailing: "Free of \(Format.storage(s.disk.total))")
                        BigNumber(text: Format.storage(s.disk.free))
                        Sparkline(values: zip(h.diskRead.values, h.diskWrite.values).map(+), tint: Metric.disk.tint).frame(height: 38)
                        StatLine(label: "Reading", value: Format.rate(s.disk.readRate))
                        StatLine(label: "Writing", value: Format.rate(s.disk.writeRate))
                        StatLine(label: "Written since launch", value: Format.storage(s.disk.writtenSinceLaunch))
                    }
                    tile(.metric(.network)) {
                        CardHeader(title: "Network", systemImage: "network", tint: Metric.network.tint, trailing: "Downloading")
                        BigNumber(text: Format.rate(s.network.inRate))
                        Sparkline(values: h.netIn.values, tint: Metric.network.tint).frame(height: 38)
                        StatLine(label: "Uploading", value: Format.rate(s.network.outRate))
                        StatLine(label: "Received since launch", value: Format.storage(s.network.receivedSinceLaunch))
                        StatLine(label: "Sent since launch", value: Format.storage(s.network.sentSinceLaunch))
                    }
                    if let battery = s.battery {
                        tile(.battery) {
                            CardHeader(title: "Battery", systemImage: BatteryView.symbol(for: battery), tint: .green,
                                       trailing: BatteryView.stateText(battery))
                            BigNumber(text: Format.percent(battery.percent))
                            Sparkline(values: h.battery.values, tint: .green, maxValue: 100).frame(height: 38)
                            StatLine(label: "Remaining", value: battery.timeRemaining.map(Format.duration) ?? "–")
                            StatLine(label: "Power draw", value: battery.systemPower.map(Format.watts) ?? "–")
                            StatLine(label: "Health", value: battery.health.map { Format.percent($0) } ?? "–")
                        }
                    }
                }

                Card {
                    CardHeader(title: "Busiest right now", systemImage: "flame", tint: .orange,
                               trailing: "\(s.processCount) processes in \(s.apps.count) apps")
                    AppListView(metric: .cpu, limit: 8)
                }
            }
            .padding(20)
        }
    }

    private func tile<Content: View>(_ target: SidebarItem, @ViewBuilder content: () -> Content) -> some View {
        Button { selection = target } label: {
            Card { content() }
        }
        .buttonStyle(.plain)
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
