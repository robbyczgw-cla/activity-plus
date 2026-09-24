import ActivityCore
import SwiftUI

enum SidebarItem: Hashable {
    case overview
    case metric(Metric)
    case battery
}

struct ContentView: View {
    @Environment(Monitor.self) private var monitor
    @SceneStorage("sidebarSelection") private var stored = "overview"
    @State private var selection: SidebarItem? = .overview

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Label("Overview", systemImage: "square.grid.2x2").tag(SidebarItem.overview)
                Section("Resources") {
                    ForEach([Metric.cpu, .memory, .gpu, .disk, .network, .energy]) { metric in
                        Label(metric.title, systemImage: metric.systemImage)
                            .badge(badge(for: metric))
                            .tag(SidebarItem.metric(metric))
                    }
                    if monitor.snapshot.battery != nil {
                        Label("Battery", systemImage: "battery.75percent").tag(SidebarItem.battery)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
        } detail: {
            switch selection ?? .overview {
            case .overview: OverviewView(selection: $selection).navigationTitle("Overview")
            case .metric(let metric): MetricDetailView(metric: metric).id(metric)
            case .battery: BatteryView()
            }
        }
        .toolbar {
            ToolbarItem(placement: .status) {
                Text("\(monitor.snapshot.processCount) processes · up \(Format.duration(monitor.snapshot.uptime))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 820, minHeight: 560)
        .onAppear { selection = Self.decode(stored) }
        .onChange(of: selection) { _, new in stored = Self.encode(new ?? .overview) }
    }

    private func badge(for metric: Metric) -> Text? {
        let s = monitor.snapshot
        switch metric {
        case .cpu: return Text(Format.percent(s.cpu.total))
        case .memory: return Text(Format.memory(s.memory.used))
        case .gpu: return s.gpu.map { Text(Format.percent($0.utilization)) }
        default: return nil
        }
    }

    static func encode(_ item: SidebarItem) -> String {
        switch item {
        case .overview: "overview"
        case .metric(let m): "metric:\(m.rawValue)"
        case .battery: "battery"
        }
    }

    static func decode(_ string: String) -> SidebarItem {
        if string.hasPrefix("metric:"), let m = Metric(rawValue: String(string.dropFirst(7))) { return .metric(m) }
        if string == "battery" { return .battery }
        return .overview
    }
}
