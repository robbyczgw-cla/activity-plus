import ActivityCore
import SwiftUI

enum SidebarItem: Hashable {
    case overview
    case metric(Metric)
    case battery, sensors
    case projects, history, alerts, sound, weekly, automations, sleep, connections
    case diagnosis, startup, storage

    struct Page {
        let item: SidebarItem
        let key: String
        let title: String
        let icon: String
        let section: String
    }

    /// Every page in sidebar order. The sidebar, Settings → Window and saved selections all come from this list.
    static let pages: [Page] = [
        Page(item: .overview, key: "overview", title: "Overview", icon: "square.grid.2x2", section: ""),
    ] + [Metric.cpu, .memory, .gpu, .disk, .network, .energy].map {
        Page(item: .metric($0), key: "metric:\($0.rawValue)", title: $0.title, icon: $0.systemImage, section: "Resources")
    } + [
        Page(item: .battery, key: "battery", title: "Battery", icon: "battery.75percent", section: "Resources"),
        Page(item: .sensors, key: "sensors", title: "Temperatures", icon: "thermometer.medium", section: "Resources"),
        Page(item: .projects, key: "projects", title: "Projects", icon: "hammer", section: "Tools"),
        Page(item: .connections, key: "connections", title: "Connections", icon: "point.3.connected.trianglepath.dotted", section: "Tools"),
        Page(item: .history, key: "history", title: "History", icon: "clock.arrow.circlepath", section: "Tools"),
        Page(item: .weekly, key: "weekly", title: "Weekly Report", icon: "calendar", section: "Tools"),
        Page(item: .alerts, key: "alerts", title: "Alerts", icon: "bell", section: "Tools"),
        Page(item: .automations, key: "automations", title: "Automations", icon: "wand.and.stars", section: "Tools"),
        Page(item: .sound, key: "sound", title: "Sound", icon: "speaker.wave.2", section: "Tools"),
        Page(item: .diagnosis, key: "diagnosis", title: "Why Is It Slow?", icon: "stethoscope", section: "Maintenance"),
        Page(item: .sleep, key: "sleep", title: "Sleep & Battery Drain", icon: "moon.zzz", section: "Maintenance"),
        Page(item: .startup, key: "startup", title: "Startup Items", icon: "power", section: "Maintenance"),
        Page(item: .storage, key: "storage", title: "Storage", icon: "externaldrive", section: "Maintenance"),
    ]

    /// Pages that can be hidden (Overview always stays).
    static var customizable: [(key: String, title: String)] {
        pages.dropFirst().map { ($0.key, $0.title) }
    }

    var key: String { Self.pages.first { $0.item == self }?.key ?? "overview" }
    static func from(_ key: String) -> SidebarItem { pages.first { $0.key == key }?.item ?? .overview }
}

struct ContentView: View {
    @Environment(Monitor.self) private var monitor
    @Environment(AppServices.self) private var services
    @SceneStorage("sidebarSelection") private var stored = "overview"
    @AppStorage("hiddenPages") private var hiddenPages = ""
    @AppStorage("accentColor") private var accent = "system"

    private let sections = ["", "Resources", "Tools", "Maintenance"]

    private func visiblePages(in section: String) -> [SidebarItem.Page] {
        let hidden = Set(hiddenPages.split(separator: ",").map(String.init))
        return SidebarItem.pages.filter { page in
            guard page.section == section, !hidden.contains(page.key) else { return false }
            // Battery only on Macs (or with accessories) that have one.
            if page.item == .battery { return monitor.snapshot.battery != nil || !services.accessories.isEmpty }
            return true
        }
    }

    @ViewBuilder private func row(_ page: SidebarItem.Page) -> some View {
        Label(page.title, systemImage: page.icon)
            .badge(badge(for: page.item))
            .tag(page.item)
    }
    @State private var selection: SidebarItem? = .overview

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(sections, id: \.self) { section in
                    if section.isEmpty {
                        ForEach(visiblePages(in: section), id: \.key) { row($0) }
                    } else {
                        Section(section) {
                            ForEach(visiblePages(in: section), id: \.key) { row($0) }
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
        } detail: {
            // A hidden or fully covered window renders nothing: charts would otherwise redraw every sample.
            if monitor.windowVisible { detail } else { Color.clear }
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
        .background(WindowActionsCapture())
        .tint(AccentChoice.color(accent))
        .background(WindowVisibilityTracker { visible in monitor.windowVisible = visible })
        .onAppear { selection = Self.decode(stored) }
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

    @ViewBuilder private var detail: some View {
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
        case .weekly: WeeklyReportView()
        case .automations: AutomationsView()
        case .sleep: SleepView()
        case .connections: ConnectionsView()
        }
    }

    private func exportCard(dark: Bool) {
        if let url = ShareCard.export(monitor.snapshot, dark: dark) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    private func badge(for item: SidebarItem) -> Text? {
        let s = monitor.snapshot
        switch item {
        case .metric(.cpu): return Text(Format.percent(s.cpu.total))
        case .metric(.memory): return Text(Format.memory(s.memory.used))
        case .metric(.gpu): return s.gpu.map { Text(Format.percent($0.utilization)) }
        case .sensors: return s.sensors.cpuTemperature.map { Text(Format.temperature($0, unit: false)) }
        case .projects:
            let count = services.projects.projects.flatMap(\.servers).count
            return count > 0 ? Text("\(count)") : nil
        case .alerts:
            let count = services.alerts.filter { $0.date > Date().addingTimeInterval(-86_400) }.count
            return count > 0 ? Text("\(count)") : nil
        case .automations:
            return services.pendingAutomations.isEmpty ? nil : Text("\(services.pendingAutomations.count)")
        default: return nil
        }
    }

    static func encode(_ item: SidebarItem) -> String { item.key }
    static func decode(_ string: String) -> SidebarItem { SidebarItem.from(string) }
}

/// Reports whether the window is actually on screen (not ordered out, minimized or fully covered).
struct WindowVisibilityTracker: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: TrackingView, context: Context) { view.onChange = onChange }

    final class TrackingView: NSView {
        var onChange: ((Bool) -> Void)?
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { onChange?(false); return }
            let names: [Notification.Name] = [NSWindow.didChangeOcclusionStateNotification, NSWindow.willCloseNotification,
                                              NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification]
            for name in names {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] note in
                    self?.report(closing: note.name == NSWindow.willCloseNotification)
                })
            }
            report(closing: false)
        }

        private func report(closing: Bool) {
            guard let window else { return }
            let visible = !closing && window.isVisible && window.occlusionState.contains(.visible) && !window.isMiniaturized
            DispatchQueue.main.async { self.onChange?(visible) }
        }

        deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    }
}
