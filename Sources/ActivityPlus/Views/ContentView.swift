import ActivityCore
import SwiftUI

enum SidebarItem: Hashable {
    case overview
    case metric(Metric)
    case battery
    case sensors
    case projects
    case history
    case alerts
    case sound
    case diagnosis
    case startup
    case storage
}

struct ContentView: View {
    @Environment(Monitor.self) private var monitor
    @Environment(AppServices.self) private var services
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
                    if monitor.snapshot.battery != nil || !services.accessories.isEmpty {
                        Label("Battery", systemImage: "battery.75percent").tag(SidebarItem.battery)
                    }
                    Label("Temperatures", systemImage: "thermometer.medium")
                        .badge(monitor.snapshot.sensors.cpuTemperature.map { Text(String(format: "%.0f°", $0)) })
                        .tag(SidebarItem.sensors)
                }
                Section("Tools") {
                    Label("Projects", systemImage: "hammer")
                        .badge(services.projects.projects.flatMap(\.servers).count)
                        .tag(SidebarItem.projects)
                    Label("History", systemImage: "clock.arrow.circlepath").tag(SidebarItem.history)
                    Label("Alerts", systemImage: "bell")
                        .badge(services.alerts.filter { $0.date > Date().addingTimeInterval(-86_400) }.count)
                        .tag(SidebarItem.alerts)
                    Label("Sound", systemImage: "speaker.wave.2").tag(SidebarItem.sound)
                }
                Section("Maintenance") {
                    Label("Why Is It Slow?", systemImage: "stethoscope").tag(SidebarItem.diagnosis)
                    Label("Startup Items", systemImage: "power").tag(SidebarItem.startup)
                    Label("Storage", systemImage: "externaldrive").tag(SidebarItem.storage)
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
        } detail: {
            switch selection ?? .overview {
            case .overview: OverviewView(selection: $selection).navigationTitle("Overview")
            case .metric(let metric): MetricDetailView(metric: metric).id(metric)
            case .battery: BatteryView()
            case .sensors: SensorsView()
            case .projects: ProjectsView()
            case .history: HistoryView()
            case .alerts: AlertsView()
            case .sound: SoundView()
            case .diagnosis: DiagnosisView(selection: $selection)
            case .startup: StartupItemsView()
            case .storage: StorageView()
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Save Share Card (Light)") { exportCard(dark: false) }
                    Button("Save Share Card (Dark)") { exportCard(dark: true) }
                    Divider()
                    Button("Copy Dashboard") { ShareCard.copyDashboard() }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .help("Save a 1200 × 630 image of your Mac's state")
            }
            ToolbarItem(placement: .status) {
                Text("\(monitor.snapshot.processCount) processes · up \(Format.duration(monitor.snapshot.uptime))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 820, minHeight: 560)
        .onAppear {
            selection = Self.decode(stored)
            monitor.windowVisible = true
        }
        .onDisappear { monitor.windowVisible = false }
        .onChange(of: selection) { _, new in stored = Self.encode(new ?? .overview) }
        .onChange(of: services.requestedPage, initial: true) { _, page in
            guard let page else { return }
            selection = Self.decode(page)
            services.requestedPage = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: SnapshotRunner.selectNotification)) { note in
            if let page = note.object as? String { selection = Self.decode(page) }
        }
    }

    private func exportCard(dark: Bool) {
        if let url = ShareCard.export(monitor.snapshot, dark: dark) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
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
        case .sensors: "sensors"
        case .projects: "projects"
        case .history: "history"
        case .alerts: "alerts"
        case .sound: "sound"
        case .diagnosis: "diagnosis"
        case .startup: "startup"
        case .storage: "storage"
        }
    }

    static func decode(_ string: String) -> SidebarItem {
        if string.hasPrefix("metric:"), let m = Metric(rawValue: String(string.dropFirst(7))) { return .metric(m) }
        let simple: [String: SidebarItem] = ["battery": .battery, "sensors": .sensors, "projects": .projects,
                                             "history": .history, "alerts": .alerts, "sound": .sound,
                                             "diagnosis": .diagnosis, "startup": .startup, "storage": .storage]
        if let item = simple[string] { return item }
        return .overview
    }
}
