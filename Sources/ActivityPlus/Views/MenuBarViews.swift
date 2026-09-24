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
    case cpu, memory, gpu, network, battery
    var id: String { rawValue }
    var title: String {
        switch self {
        case .cpu: "CPU"
        case .memory: "Memory"
        case .gpu: "GPU"
        case .network: "Network"
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
    @Environment(\.openWindow) private var openWindow
    @State private var tab: Tab = .overview

    enum Tab: String, CaseIterable, Identifiable {
        case overview, cpu, memory, gpu, disk, network
        var id: String { rawValue }
        var metric: Metric? {
            switch self {
            case .overview: nil
            case .cpu: .cpu
            case .memory: .memory
            case .gpu: .gpu
            case .disk: .disk
            case .network: .network
            }
        }
        var systemImage: String { metric?.systemImage ?? "square.grid.2x2" }
    }

    var body: some View {
        let s = monitor.snapshot
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(tab == .overview ? "Overview" : tab.metric!.title).font(.headline)
                Spacer()
                Text("Up \(Format.duration(s.uptime))").font(.caption).foregroundStyle(.secondary)
            }
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Image(systemName: $0.systemImage).tag($0).help($0.metric?.title ?? "Overview") }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if let metric = tab.metric {
                detail(for: metric)
            } else {
                Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                    GridRow {
                        mini("CPU", Format.percent(s.cpu.total), .cpu)
                        mini("Memory", Format.memory(s.memory.used), .memory)
                        mini("Network", Format.rate(s.network.inRate), .network)
                    }
                    GridRow {
                        mini("Disk free", Format.storage(s.disk.free), .disk)
                        mini("GPU", Format.percent(s.gpu?.utilization ?? 0), .gpu)
                        if let b = s.battery {
                            mini("Battery", Format.percent(b.percent), nil, tint: .green)
                        } else {
                            mini("Power", Format.watts(s.apps.reduce(0) { $0 + $1.powerWatts }), .energy)
                        }
                    }
                }
            }

            Divider()
            Text("Busiest right now").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            let metric = tab.metric ?? .cpu
            ForEach(s.apps.sorted { metric.value($0) > metric.value($1) }.prefix(5)) { app in
                HStack(spacing: 8) {
                    AppIconView(app: app, size: 18)
                    Text(app.name).lineLimit(1)
                    Spacer()
                    Text(metric.format(metric.value(app))).monospacedDigit().foregroundStyle(.secondary)
                }
                .font(.callout)
            }

            Divider()
            HStack {
                Button("Open Activity+") {
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
        .frame(width: 340)
    }

    private func mini(_ title: String, _ value: String, _ metric: Metric?, tint: Color? = nil) -> some View {
        Button {
            if let metric, let t = Tab.allCases.first(where: { $0.metric == metric }) { tab = t }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption).foregroundStyle(tint ?? metric?.tint ?? .secondary)
                BigNumber(text: value, size: 17)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
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
            case .memory:
                HStack { BigNumber(text: Format.memory(s.memory.used), size: 26); Spacer(); PressureBadge(pressure: s.memory.pressure) }
                MemoryBar(stats: s.memory)
                StatLine(label: "Compressed", value: Format.memory(s.memory.compressed))
                StatLine(label: "Swap", value: Format.memory(s.memory.swapUsed))
            case .gpu:
                BigNumber(text: Format.percent(s.gpu?.utilization ?? 0), size: 26)
                Sparkline(values: h.gpu.values, tint: metric.tint, maxValue: 100).frame(height: 44)
            case .disk:
                BigNumber(text: Format.storage(s.disk.free) + " free", size: 22)
                StatLine(label: "Reading", value: Format.rate(s.disk.readRate))
                StatLine(label: "Writing", value: Format.rate(s.disk.writeRate))
            case .network:
                BigNumber(text: Format.rate(s.network.inRate), size: 26)
                Sparkline(values: h.netIn.values, tint: metric.tint).frame(height: 44)
                StatLine(label: "Uploading", value: Format.rate(s.network.outRate))
            case .energy:
                EmptyView()
            }
        }
    }
}
