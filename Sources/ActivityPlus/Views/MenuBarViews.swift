import ActivityCore
import Charts
import SwiftUI

enum MenuBarStyle: String, CaseIterable, Identifiable {
    case icon, figure, graph, stacked
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

/// What the menu bar item can show as its figure or graph.
enum MenuBarFigure: String, CaseIterable, Identifiable {
    case cpu, memory, gpu, network, temperature, battery
    var id: String { rawValue }
    var title: String {
        switch self {
        case .cpu: "CPU"
        case .memory: "Memory"
        case .gpu: "GPU"
        case .network: "Network"
        case .temperature: "Temperature"
        case .battery: "Battery"
        }
    }

    @MainActor func text(_ monitor: Monitor) -> String {
        let s = monitor.snapshot
        switch self {
        case .cpu: return Format.percent(s.cpu.total)
        case .memory: return Format.percent(Double(s.memory.used) / Double(max(1, s.memory.total)) * 100)
        case .gpu: return Format.percent(s.gpu?.utilization ?? 0)
        case .network: return Format.rate(s.network.inRate + s.network.outRate)
        case .temperature: return s.sensors.cpuTemperature.map { String(format: "%.0f°", $0) } ?? "–"
        case .battery: return s.battery.map { Format.percent($0.percent) } ?? "–"
        }
    }

    @MainActor func series(_ monitor: Monitor) -> (values: [Double], max: Double?) {
        let h = monitor.history
        switch self {
        case .cpu: return (h.cpu.values, 100)
        case .memory: return (h.memory.values, Double(monitor.snapshot.memory.total))
        case .gpu: return (h.gpu.values, 100)
        case .network: return (zip(h.netIn.values, h.netOut.values).map(+), nil)
        case .temperature: return (h.cpuTemperature.values, 110)
        case .battery: return (h.battery.values, 100)
        }
    }
}

struct MenuBarLabel: View {
    @Environment(Monitor.self) private var monitor
    @AppStorage("menuBarStyle") private var style = MenuBarStyle.figure.rawValue
    @AppStorage("menuBarFigure") private var figure = MenuBarFigure.cpu.rawValue
    @AppStorage("menuBarStacked") private var stackedRaw = "cpu,memory"

    var body: some View {
        let figure = MenuBarFigure(rawValue: figure) ?? .cpu
        if monitor.isUnderStrain {
            Image(systemName: "exclamationmark.triangle.fill")
        } else {
            switch MenuBarStyle(rawValue: style) ?? .figure {
            case .icon:
                Image(systemName: "waveform.path.ecg")
            case .figure:
                Text(figure.text(monitor)).monospacedDigit()
            case .graph:
                Image(nsImage: Self.render(GraphGlyph(series: figure.series(monitor))))
            case .stacked:
                let figures = stackedRaw.split(separator: ",").compactMap { MenuBarFigure(rawValue: String($0)) }
                Image(nsImage: Self.render(StackedGlyph(lines: figures.prefix(2).map { ($0.title, $0.text(monitor)) })))
            }
        }
    }

    /// MenuBarExtra labels only reliably render Text and Image, so richer glyphs are drawn to a template image.
    @MainActor static func render<V: View>(_ view: V) -> NSImage {
        let renderer = ImageRenderer(content: view.foregroundStyle(.black))
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        let image = renderer.nsImage ?? NSImage()
        image.isTemplate = true
        return image
    }
}

private struct GraphGlyph: View {
    let series: (values: [Double], max: Double?)
    var body: some View {
        let values = Array(series.values.suffix(24))
        Chart(Array(values.enumerated()), id: \.offset) { p in
            BarMark(x: .value("t", p.offset), y: .value("v", p.element), width: 1.5)
        }
        .chartXAxis(.hidden).chartYAxis(.hidden)
        .chartYScale(domain: 0...max(series.max ?? (values.max() ?? 1), 0.000_1))
        .chartXScale(domain: -0.5...23.5)
        .frame(width: 38, height: 16)
    }
}

private struct StackedGlyph: View {
    let lines: [(String, String)]
    var body: some View {
        VStack(alignment: .trailing, spacing: -1) {
            ForEach(lines, id: \.0) { line in
                HStack(spacing: 3) {
                    Text(line.0).font(.system(size: 7, weight: .medium))
                    Text(line.1).font(.system(size: 9, weight: .semibold)).monospacedDigit()
                }
            }
        }
        .frame(height: 20)
    }
}

/// The compact view shown when clicking the menu bar item.
struct MenuBarPanel: View {
    @Environment(Monitor.self) private var monitor
    @Environment(AppServices.self) private var services
    @Environment(\.openWindow) private var openWindow
    @AppStorage("menuBarPanelTab") private var tab: Tab = .overview

    enum Tab: String, CaseIterable, Identifiable {
        case overview, cpu, memory, gpu, disk, network, battery, projects
        var id: String { rawValue }
        var metric: Metric? {
            switch self {
            case .cpu: .cpu
            case .memory: .memory
            case .gpu: .gpu
            case .disk: .disk
            case .network: .network
            case .battery: .energy
            case .overview, .projects: nil
            }
        }
        var title: String {
            switch self {
            case .overview: "Overview"
            case .battery: "Battery"
            case .projects: "Projects"
            default: metric?.title ?? ""
            }
        }
        var systemImage: String {
            switch self {
            case .overview: "square.grid.2x2"
            case .battery: "battery.75percent"
            case .projects: "hammer"
            default: metric?.systemImage ?? "circle"
            }
        }
        /// The main window page with the same content.
        var page: String {
            switch self {
            case .overview: "overview"
            case .battery: "battery"
            case .projects: "projects"
            default: "metric:\(metric!.rawValue)"
            }
        }
    }

    var body: some View {
        let s = monitor.snapshot
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(tab.title).font(.headline)
                Spacer()
                Text("Up \(Format.duration(s.uptime))").font(.caption).foregroundStyle(.secondary)
            }
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Image(systemName: $0.systemImage).tag($0).help($0.title) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch tab {
            case .overview: overview
            case .battery: battery
            case .projects: projects
            default: if let metric = tab.metric { detail(for: metric) }
            }

            if tab != .projects {
                Divider()
                Text(tab == .battery ? "Using the most energy" : "Busiest right now")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                let metric = tab.metric ?? .cpu
                ForEach(s.apps.sorted { metric.value($0) > metric.value($1) }.prefix(5)) { app in
                    BusyRow(app: app, metric: metric)
                }
            }

            Divider()
            HStack {
                Button("Open Activity+") {
                    // Opens on the tab you were looking at here.
                    services.requestedPage = tab.page
                    openWindow(id: "main")
                    NSApp.activate()
                }
                .keyboardShortcut("o")
                Spacer()
                SettingsLink { Image(systemName: "gearshape") }.buttonStyle(.borderless)
                Button("Quit") { NSApp.terminate(nil) }.keyboardShortcut("q")
            }
        }
        .padding(14)
        .frame(width: 360)
        .onAppear { monitor.panelVisible = true }
        .onDisappear { monitor.panelVisible = false }
    }

    // MARK: Tabs

    private var overview: some View {
        let s = monitor.snapshot
        return Grid(horizontalSpacing: 10, verticalSpacing: 10) {
            GridRow {
                mini("CPU", Format.percent(s.cpu.total), .cpu)
                mini("Memory", Format.memory(s.memory.used), .memory)
                mini("Network", Format.rate(s.network.inRate), .network)
            }
            GridRow {
                mini("Disk free", Format.storage(s.disk.free), .disk)
                mini("GPU", Format.percent(s.gpu?.utilization ?? 0), .gpu)
                if let b = s.battery {
                    mini("Battery", Format.percent(b.percent), .battery, tint: .green)
                } else if let t = s.sensors.cpuTemperature {
                    mini("CPU temp", String(format: "%.0f °C", t), nil, tint: .red)
                } else {
                    mini("Power", Format.watts(s.apps.reduce(0) { $0 + $1.powerWatts }), .battery, tint: .green)
                }
            }
        }
    }

    @ViewBuilder private var battery: some View {
        let s = monitor.snapshot
        VStack(alignment: .leading, spacing: 6) {
            if let b = s.battery {
                HStack(alignment: .firstTextBaseline) {
                    BigNumber(text: Format.percent(b.percent), size: 26)
                    Spacer()
                    Text(BatteryView.stateText(b)).font(.caption).foregroundStyle(.secondary)
                }
                UsageBar(fraction: b.percent / 100, tint: b.percent < 20 ? .red : .green)
                StatLine(label: "Remaining", value: b.timeRemaining.map(Format.duration) ?? (b.isPluggedIn ? "Plugged in" : "Calculating…"))
                StatLine(label: "Mac power draw", value: b.systemPower.map(Format.watts) ?? "–")
                StatLine(label: "Health", value: b.health.map { Format.percent($0) } ?? "–")
            } else {
                StatLine(label: "Apps power", value: Format.watts(s.apps.reduce(0) { $0 + $1.powerWatts }))
            }
            ForEach(services.accessories) { device in
                StatLine(label: device.name, value: device.levels.map { ($0.label.map { $0 + " " } ?? "") + "\($0.percent) %" }.joined(separator: " · "))
            }
        }
    }

    @ViewBuilder private var projects: some View {
        let servers = services.projects.projects.flatMap { project in project.servers.map { (project.name, $0) } }
        VStack(alignment: .leading, spacing: 8) {
            if servers.isEmpty {
                Text("No dev servers running.").foregroundStyle(.secondary).font(.callout)
            }
            ForEach(servers.prefix(8), id: \.1.id) { project, server in
                HStack(spacing: 8) {
                    Text(server.ports.first.map(String.init) ?? "–")
                        .font(.system(.caption, design: .monospaced).weight(.semibold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                        .frame(width: 54, alignment: .leading)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(project).font(.callout).lineLimit(1)
                        Text(server.isIdle() ? "idle · \(Format.memory(server.memory))" : "working · \(Format.memory(server.memory))")
                            .font(.caption2).foregroundStyle(server.isIdle() ? .orange : .secondary)
                    }
                    Spacer()
                    Button("Stop…") { stop(server, project: project) }.controlSize(.small)
                }
            }
        }
    }

    // MARK: Pieces

    private func mini(_ title: String, _ value: String, _ target: Tab?, tint: Color? = nil) -> some View {
        Button {
            if let target { tab = target }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption).foregroundStyle(tint ?? target?.metric?.tint ?? .secondary)
                BigNumber(text: value, size: 17)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private func mini(_ title: String, _ value: String, _ metric: Metric, tint: Color? = nil) -> some View {
        mini(title, value, Tab.allCases.first { $0.metric == metric }, tint: tint)
    }

    private func stop(_ server: DevServer, project: String) {
        let ports = server.ports.map(String.init).joined(separator: ", ")
        guard Confirm.ask("Stop \(project) on port \(ports)?",
                          "\(server.command) will be asked to stop. \(Format.memory(server.memory)) and the port will be freed.",
                          button: "Stop") else { return }
        ProjectScanner.stop(server)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { services.scanProjects() }
    }

    @ViewBuilder private func detail(for metric: Metric) -> some View {
        let s = monitor.snapshot
        let h = monitor.history
        VStack(alignment: .leading, spacing: 6) {
            switch metric {
            case .cpu:
                BigNumber(text: Format.percent(s.cpu.total), size: 26)
                Sparkline(values: h.cpu.values, tint: metric.tint, maxValue: 100).frame(height: 44)
                StatLine(label: "User", value: Format.percent(s.cpu.user))
                StatLine(label: "System", value: Format.percent(s.cpu.system))
                if let t = s.sensors.cpuTemperature { StatLine(label: "Temperature", value: String(format: "%.0f °C", t)) }
            case .memory:
                HStack { BigNumber(text: Format.memory(s.memory.used), size: 26); Spacer(); PressureBadge(pressure: s.memory.pressure) }
                MemoryBar(stats: s.memory)
                StatLine(label: "Compressed", value: Format.memory(s.memory.compressed))
                StatLine(label: "Swap", value: Format.memory(s.memory.swapUsed))
            case .gpu:
                BigNumber(text: Format.percent(s.gpu?.utilization ?? 0), size: 26)
                Sparkline(values: h.gpu.values, tint: metric.tint, maxValue: 100).frame(height: 44)
                if let t = s.sensors.gpuTemperature { StatLine(label: "Temperature", value: String(format: "%.0f °C", t)) }
            case .disk:
                BigNumber(text: Format.storage(s.disk.free) + " free", size: 22)
                StatLine(label: "Reading", value: Format.rate(s.disk.readRate))
                StatLine(label: "Writing", value: Format.rate(s.disk.writeRate))
                StatLine(label: "Written today", value: Format.storage(UInt64(services.today.diskWritten)))
            case .network:
                BigNumber(text: Format.rate(s.network.inRate), size: 26)
                Sparkline(values: h.netIn.values, tint: metric.tint).frame(height: 44)
                StatLine(label: "Uploading", value: Format.rate(s.network.outRate))
                StatLine(label: "Today", value: Format.storage(UInt64(services.today.received + services.today.sent)))
            case .energy:
                EmptyView()
            }
        }
    }
}

/// One of the busiest apps, with a quit button on hover. Quitting always asks first.
private struct BusyRow: View {
    let app: AppGroup
    let metric: Metric
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            AppIconView(app: app, size: 18)
            Text(app.name).lineLimit(1)
            Spacer()
            if hovering && app.kind != .system {
                Button { quit() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Quit \(app.name)…")
            }
            Text(metric.format(metric.value(app))).monospacedDigit().foregroundStyle(.secondary)
        }
        .font(.callout)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Quit \(app.name)…") { quit() }.disabled(app.kind == .system)
            Button("Force Quit \(app.name)…") { quit(force: true) }.disabled(app.kind == .system)
        }
    }

    private func quit(force: Bool = false) {
        let count = app.processes.count
        guard Confirm.ask("\(force ? "Force quit" : "Quit") \(app.name)?",
                          (count == 1 ? "1 process will close." : "\(count) processes will close.")
                            + (force ? " Unsaved changes will be lost." : ""),
                          button: force ? "Force Quit" : "Quit") else { return }
        if case .denied(let message) = ProcessActions.quit(app, force: force) {
            _ = Confirm.ask("Could not quit", message, button: "OK", cancel: false)
        }
    }
}

/// A modal confirmation that works from the menu bar panel (SwiftUI dialogs there can close the panel first).
@MainActor
enum Confirm {
    static func ask(_ title: String, _ message: String, button: String, cancel: Bool = true) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = cancel ? .warning : .informational
        alert.addButton(withTitle: button)
        if cancel { alert.addButton(withTitle: "Cancel") }
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn
    }
}
