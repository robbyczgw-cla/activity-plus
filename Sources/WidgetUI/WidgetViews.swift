import SwiftUI
import WidgetData
import WidgetKit

// The desktop and Notification Center widgets. Shared by the widget extension and the app (whose
// SnapshotRunner renders them to PNG), so they only use extension-safe APIs.

extension WidgetMetric {
    public var title: LocalizedStringKey {
        switch self {
        case .cpu: "CPU"
        case .memory: "Memory"
        case .gpu: "GPU"
        case .disk: "Disk"
        case .network: "Network"
        case .temperature: "Temperature"
        case .battery: "Battery"
        }
    }

    public var systemImage: String {
        switch self {
        case .cpu: "cpu"
        case .memory: "memorychip"
        case .gpu: "square.stack.3d.up"
        case .disk: "internaldrive"
        case .network: "network"
        case .temperature: "thermometer.medium"
        case .battery: "battery.100percent"
        }
    }

    /// The same tints the app uses for these metrics.
    public var tint: Color {
        switch self {
        case .cpu: .blue
        case .memory: .purple
        case .gpu: .pink
        case .disk: .orange
        case .network: .teal
        case .temperature: .orange
        case .battery: .green
        }
    }

    func reading(in s: WidgetSnapshot) -> WidgetSnapshot.Reading? {
        switch self {
        case .cpu: s.cpu
        case .memory: s.memory
        case .gpu: s.gpu
        case .disk: s.disk
        case .network: s.networkIn
        case .temperature: s.temperature
        case .battery: s.battery
        }
    }
}

/// Lets SnapshotRunner preview the desktop look (vibrant), which outside a widget host cannot be set.
public struct WidgetVibrantPreviewKey: EnvironmentKey {
    public static let defaultValue = false
}

extension EnvironmentValues {
    public var widgetVibrantPreview: Bool {
        get { self[WidgetVibrantPreviewKey.self] }
        set { self[WidgetVibrantPreviewKey.self] = newValue }
    }
}

/// True on the desktop while another app is in front (and in tinted modes): colors are flattened to
/// one hue there, so shapes and weights have to carry the meaning instead.
private struct Monochrome: ViewModifier {
    @Environment(\.widgetRenderingMode) private var mode
    @Environment(\.widgetVibrantPreview) private var preview
    func body(content: Content) -> some View {
        content.environment(\.widgetIsMonochrome, preview || mode != .fullColor)
    }
}

private struct WidgetIsMonochromeKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var widgetIsMonochrome: Bool {
        get { self[WidgetIsMonochromeKey.self] }
        set { self[WidgetIsMonochromeKey.self] = newValue }
    }
}

// MARK: - Building blocks

struct Ring<Center: View>: View {
    var fraction: Double?
    var tint: Color
    var lineWidth: CGFloat
    @ViewBuilder var center: Center
    @Environment(\.widgetIsMonochrome) private var monochrome

    var body: some View {
        ZStack {
            Circle().stroke(monochrome ? Color.primary.opacity(0.18) : tint.opacity(0.2), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, fraction ?? 0))
                .stroke(monochrome ? Color.primary : tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .widgetAccentable()
            center
        }
        .padding(lineWidth / 2)
    }
}

struct MetricHeader: View {
    var metric: WidgetMetric
    @Environment(\.widgetIsMonochrome) private var monochrome
    var body: some View {
        Label {
            Text(metric.title).lineLimit(1)
        } icon: {
            Image(systemName: metric.systemImage).foregroundStyle(monochrome ? Color.primary : metric.tint).widgetAccentable()
        }
        .font(.system(size: 13, weight: .semibold))
    }
}

struct PressureDot: View {
    var pressure: WidgetSnapshot.Pressure
    @Environment(\.widgetIsMonochrome) private var monochrome
    var body: some View {
        Circle()
            .fill(monochrome ? Color.primary : color)
            .frame(width: 6, height: 6)
            .opacity(monochrome && pressure == .normal ? 0.4 : 1)
    }
    var color: Color {
        switch pressure {
        case .normal: .green
        case .warning: .yellow
        case .critical: .red
        }
    }
}

struct AppIcon: View {
    var app: WidgetSnapshot.App
    var size: CGFloat
    var body: some View {
        if let data = app.icon, let image = NSImage(data: data) {
            Image(nsImage: image).resizable().interpolation(.high).frame(width: size, height: size)
        } else {
            Image(systemName: app.symbol ?? "app.dashed").resizable().scaledToFit().foregroundStyle(.secondary)
                .padding(size * 0.12).frame(width: size, height: size)
        }
    }
}

/// "14:32", or a warning that the numbers are old because Activity+ is not running.
struct UpdatedLine: View {
    var snapshot: WidgetSnapshot
    var now: Date
    var compact = false
    var body: some View {
        if snapshot.isStale(at: now) {
            Label {
                Text(compact ? "Not running" : "Activity+ isn't running · \(snapshot.date, style: .time)")
            } icon: {
                Image(systemName: "pause.circle")
            }
            .labelStyle(.titleAndIcon)
            .foregroundStyle(.orange)
        } else {
            Text(snapshot.date, style: .time).foregroundStyle(.secondary)
        }
    }
}

struct EmptyWidget: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "gauge.with.dots.needle.33percent").font(.system(size: 26)).foregroundStyle(.secondary)
            Text("Open Activity+ to fill this widget.")
                .font(.system(size: 12))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Small: one metric

public struct MetricWidgetView: View {
    var snapshot: WidgetSnapshot?
    var metric: WidgetMetric
    var now: Date

    public init(snapshot: WidgetSnapshot?, metric: WidgetMetric, now: Date = Date()) {
        self.snapshot = snapshot
        self.metric = metric
        self.now = now
    }

    public var body: some View {
        Group {
            if let snapshot { content(snapshot) } else { EmptyWidget() }
        }
        .modifier(Monochrome())
    }

    @ViewBuilder private func content(_ s: WidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                MetricHeader(metric: metric)
                Spacer(minLength: 4)
                UpdatedLine(snapshot: s, now: now, compact: true).font(.system(size: 10)).lineLimit(1)
            }
            Spacer(minLength: 6)
            if metric == .network {
                network(s)
            } else if let reading = metric.reading(in: s) {
                HStack {
                    Spacer(minLength: 0)
                    Ring(fraction: reading.fraction, tint: metric.tint, lineWidth: 9) {
                        Text(ringText(reading))
                            .font(.system(size: 19, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .minimumScaleFactor(0.6)
                            .lineLimit(1)
                            .padding(.horizontal, 10)
                    }
                    .frame(width: 86, height: 86)
                    Spacer(minLength: 0)
                }
                .opacity(s.isStale(at: now) ? 0.45 : 1)
                Spacer(minLength: 6)
                detail(s, reading)
            } else {
                Text("Not available on this Mac")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// Disk and memory rings show the used share; their absolute figures go into the line below.
    private func ringText(_ r: WidgetSnapshot.Reading) -> String {
        switch metric {
        case .disk, .memory: r.fraction.map { "\(Int(($0 * 100).rounded()))%" } ?? r.text
        default: r.text
        }
    }

    @ViewBuilder private func detail(_ s: WidgetSnapshot, _ r: WidgetSnapshot.Reading) -> some View {
        Group {
            switch metric {
            case .memory:
                HStack(spacing: 5) {
                    PressureDot(pressure: s.memoryPressure)
                    Text(r.text).monospacedDigit()
                    Text(r.detail ?? "").foregroundStyle(.secondary)
                }
            case .disk:
                Text(r.text).monospacedDigit()
            default:
                Text(r.detail ?? " ").foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 11))
        .lineLimit(1)
        .minimumScaleFactor(0.75)
        .frame(maxWidth: .infinity)
    }

    private func network(_ s: WidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            rateRow("arrow.down.circle.fill", s.networkIn.text, label: "Download")
            rateRow("arrow.up.circle.fill", s.networkOut.text, label: "Upload")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func rateRow(_ symbol: String, _ value: String, label: LocalizedStringKey) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 22)).foregroundStyle(metric.tint).widgetAccentable()
            VStack(alignment: .leading, spacing: 0) {
                Text(value).font(.system(size: 17, weight: .semibold, design: .rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
                Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Medium and large: everything at a glance

public struct OverviewWidgetView: View {
    var snapshot: WidgetSnapshot?
    var large: Bool
    var now: Date

    public init(snapshot: WidgetSnapshot?, large: Bool, now: Date = Date()) {
        self.snapshot = snapshot
        self.large = large
        self.now = now
    }

    public var body: some View {
        Group {
            if let snapshot { content(snapshot) } else { EmptyWidget() }
        }
        .modifier(Monochrome())
    }

    private func content(_ s: WidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: large ? 12 : 8) {
            if large {
                HStack(alignment: .firstTextBaseline) {
                    Text("Activity+").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    UpdatedLine(snapshot: s, now: now).font(.system(size: 11)).lineLimit(1)
                }
            }
            HStack(alignment: .top, spacing: 0) {
                ForEach([WidgetMetric.cpu, .memory, .gpu, .disk], id: \.self) { metric in
                    ringColumn(metric, s)
                    if metric != .disk { Spacer(minLength: 4) }
                }
            }
            .opacity(s.isStale(at: now) ? 0.45 : 1)
            if large {
                stats(s)
                Divider().opacity(0.5)
                topApps(s)
                Spacer(minLength: 0)
            } else {
                Spacer(minLength: 0)
                mediumFooter(s)
            }
        }
    }

    private func ringColumn(_ metric: WidgetMetric, _ s: WidgetSnapshot) -> some View {
        let reading = metric.reading(in: s)
        let size: CGFloat = large ? 70 : 68
        return VStack(spacing: 5) {
            Ring(fraction: reading?.fraction, tint: metric.tint, lineWidth: 7) {
                Text(reading?.fraction.map { "\(Int(($0 * 100).rounded()))%" } ?? "–")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
            }
            .frame(width: size, height: size)
            Text(metric.title)
                .font(.system(size: 11, weight: .medium))
            .lineLimit(1)
        }
        .frame(width: 76)
    }

    private func mediumFooter(_ s: WidgetSnapshot) -> some View {
        HStack(spacing: 6) {
            if let app = s.topApps.first {
                AppIcon(app: app, size: 16)
                Text(app.name).lineLimit(1)
                Text(app.cpuText).monospacedDigit().foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            Image(systemName: "arrow.down").foregroundStyle(.secondary)
            Text(s.networkIn.text).monospacedDigit().lineLimit(1)
            Image(systemName: "arrow.up").foregroundStyle(.secondary)
            Text(s.networkOut.text).monospacedDigit().lineLimit(1)
        }
        .font(.system(size: 11))
        .minimumScaleFactor(0.8)
        .overlay(alignment: .topTrailing) {
            if s.isStale(at: now) {
                UpdatedLine(snapshot: s, now: now, compact: true).font(.system(size: 10)).offset(y: -18)
            }
        }
    }

    private func stats(_ s: WidgetSnapshot) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
            GridRow {
                statLabel(.memory)
                HStack(spacing: 5) {
                    PressureDot(pressure: s.memoryPressure)
                    Text(s.memory.text).monospacedDigit()
                    Text(s.memory.detail ?? "").foregroundStyle(.secondary).lineLimit(1)
                }
            }
            GridRow {
                statLabel(.disk)
                Text("\(s.disk.text) \(Text(s.disk.detail ?? "").foregroundStyle(.secondary))").monospacedDigit()
            }
            GridRow {
                statLabel(.network)
                HStack(spacing: 4) {
                    Image(systemName: "arrow.down").foregroundStyle(.secondary)
                    Text(s.networkIn.text).monospacedDigit()
                    Image(systemName: "arrow.up").foregroundStyle(.secondary).padding(.leading, 6)
                    Text(s.networkOut.text).monospacedDigit()
                }
            }
            if let t = s.temperature {
                GridRow {
                    statLabel(.temperature)
                    Text("\(t.text) \(Text(t.detail ?? "").foregroundStyle(.secondary))").monospacedDigit()
                }
            }
            if let b = s.battery {
                GridRow {
                    statLabel(.battery)
                    Text("\(b.text) \(Text(b.detail ?? "").foregroundStyle(.secondary))").monospacedDigit()
                }
            }
        }
        .font(.system(size: 11))
        .lineLimit(1)
    }

    private func statLabel(_ metric: WidgetMetric) -> some View {
        StatLabel(metric: metric)
    }

    private func topApps(_ s: WidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Top apps").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            ForEach(s.topApps) { app in
                HStack(spacing: 8) {
                    AppIcon(app: app, size: 20)
                    Text(app.name).lineLimit(1)
                    Spacer(minLength: 6)
                    Text(app.cpuText).monospacedDigit().frame(minWidth: 44, alignment: .trailing)
                    Text(app.memoryText).monospacedDigit().foregroundStyle(.secondary).frame(minWidth: 64, alignment: .trailing)
                }
                .font(.system(size: 12))
            }
        }
    }
}

private struct StatLabel: View {
    var metric: WidgetMetric
    @Environment(\.widgetIsMonochrome) private var monochrome
    var body: some View {
        Label {
            Text(metric.title).foregroundStyle(.secondary)
        } icon: {
            Image(systemName: metric.systemImage).foregroundStyle(monochrome ? Color.primary : metric.tint).widgetAccentable()
        }
        .labelStyle(.titleAndIcon)
        .gridColumnAlignment(.leading)
    }
}

// MARK: - Gallery placeholder

extension WidgetSnapshot {
    /// Made-up numbers for the widget gallery and the loading placeholder.
    public static var sample: WidgetSnapshot {
        WidgetSnapshot(
            date: Date(),
            cpu: Reading(text: "18%", fraction: 0.18, detail: "User 12% · System 6%"),
            memory: Reading(text: "11.4 GB", fraction: 0.62, detail: "Pressure: Normal"),
            memoryPressure: .normal,
            gpu: Reading(text: "7%", fraction: 0.07),
            disk: Reading(text: "214 GB free", fraction: 0.58, detail: "of 494 GB"),
            networkIn: Reading(text: "1.2 MB/s"),
            networkOut: Reading(text: "84 kB/s"),
            temperature: Reading(text: "48 °C", fraction: 0.48),
            temperatureCelsius: 48,
            battery: Reading(text: "86%", fraction: 0.86, detail: "Charging"),
            batteryCharging: true,
            topApps: [
                App(id: "a", name: "Safari", cpuText: "9.4%", memoryText: "1.8 GB", cpuPercent: 9.4),
                App(id: "b", name: "Mail", cpuText: "2.1%", memoryText: "420 MB", cpuPercent: 2.1),
                App(id: "c", name: "Music", cpuText: "1.3%", memoryText: "310 MB", cpuPercent: 1.3),
            ])
    }
}
