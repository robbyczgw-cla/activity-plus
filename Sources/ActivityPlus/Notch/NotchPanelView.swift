import ActivityCore
import SwiftUI

/// A short "live activity" shown in the notch for a few seconds.
struct NotchHint: Identifiable, Equatable {
    enum Kind: String, CaseIterable, Identifiable {
        case memory, hang, thermal, charger, recording, findCause
        var id: String { rawValue }
        var title: String {
            switch self {
            case .memory: String(localized: "Memory pressure")
            case .hang: String(localized: "App not responding")
            case .thermal: String(localized: "Mac running hot")
            case .charger: String(localized: "Charger connected")
            case .recording: String(localized: "Recording")
            case .findCause: String(localized: "Find the Cause")
            }
        }
    }

    let id = UUID()
    let kind: Kind
    /// Rate limit: the same key shows at most once every 10 minutes.
    let key: String
    let symbol: String
    let tint: Color
    let text: String
    /// A short value in the right ear (e.g. "96 W"), if any.
    var trailing: String?
    /// The main window page a click opens.
    var page: String

    static func == (a: NotchHint, b: NotchHint) -> Bool { a.id == b.id }
}

/// What the notch panel shows; the controller changes `mode` inside an animation.
@MainActor @Observable
final class NotchModel {
    enum Mode: Equatable {
        case idle, expanded, hint(NotchHint)
    }

    var mode: Mode = .idle
    /// The hardware notch in points.
    var notch = CGSize(width: 185, height: 32)

    init(notch: CGSize = CGSize(width: 185, height: 32), mode: Mode = .idle) {
        self.notch = notch
        self.mode = mode
    }

    /// Small outward curves where the shape meets the top edge (none while idle, so nothing spills
    /// past the hardware notch) and the radius of the bottom corners.
    func radii(_ mode: Mode) -> (top: CGFloat, bottom: CGFloat) {
        switch mode {
        case .idle: (0, 10)
        case .expanded: (8, 22)
        case .hint: (6, 16)
        }
    }

    /// The whole shape, flares included.
    func size(_ mode: Mode) -> CGSize {
        let flare = radii(mode).top * 2
        switch mode {
        case .idle: return CGSize(width: max(notch.width - 2, 10), height: notch.height)
        case .expanded: return CGSize(width: max(400, notch.width + 200) + flare, height: notch.height + 118)
        case .hint: return CGSize(width: max(300, notch.width + 124) + flare, height: notch.height + 30)
        }
    }

    /// Big enough for every mode; used for offscreen snapshots.
    var largest: CGSize {
        let a = size(.expanded), b = size(.hint(NotchHint(kind: .memory, key: "", symbol: "", tint: .white, text: "", page: "")))
        return CGSize(width: max(a.width, b.width), height: max(a.height, b.height))
    }
}

/// The notch outline: flat top, optional outward flares at the top corners, rounded bottom corners.
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set { topRadius = newValue.first; bottomRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let t = min(topRadius, rect.width / 4)
        let b = min(bottomRadius, (rect.width - 2 * t) / 2, rect.height - t)
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.minX + t, y: rect.minY + t), control: CGPoint(x: rect.minX + t, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + t, y: rect.maxY - b))
        p.addQuadCurve(to: CGPoint(x: rect.minX + t + b, y: rect.maxY), control: CGPoint(x: rect.minX + t, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - t - b, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - t, y: rect.maxY - b), control: CGPoint(x: rect.maxX - t, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - t, y: rect.minY + t))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: rect.maxX - t, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

/// Everything inside the notch panel window. While idle it is a plain black shape and reads no live
/// data, so samples cause no SwiftUI work until the panel opens.
struct NotchRootView: View {
    let model: NotchModel
    var open: (String) -> Void

    var body: some View {
        let mode = model.mode
        let size = model.size(mode)
        let radii = model.radii(mode)
        ZStack(alignment: .top) {
            Color.black
            switch mode {
            case .idle:
                EmptyView()
            case .expanded:
                NotchExpandedView(notch: model.notch, flare: model.radii(.expanded).top, open: open)
                    .frame(width: model.size(.expanded).width, height: model.size(.expanded).height)
                    .transition(.opacity.animation(.easeOut(duration: 0.18).delay(0.08)))
            case .hint(let hint):
                NotchHintView(hint: hint, notch: model.notch, flare: model.radii(mode).top, open: open)
                    .frame(width: size.width, height: size.height)
                    .transition(.opacity.animation(.easeOut(duration: 0.18).delay(0.06)))
            }
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .clipShape(NotchShape(topRadius: radii.top, bottomRadius: radii.bottom))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
    }
}

// MARK: - Hover: live values

private let dim = Color.white.opacity(0.55)

struct NotchExpandedView: View {
    let notch: CGSize
    let flare: CGFloat
    var open: (String) -> Void
    private let monitor = Monitor.shared

    var body: some View {
        let s = monitor.snapshot
        VStack(spacing: 0) {
            // The two "ears" beside the camera housing.
            HStack(spacing: 0) {
                Button { open("sensors") } label: { temperature(s) }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Color.clear.frame(width: notch.width + 8)
                Button { open("battery") } label: { battery(s) }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(.horizontal, flare + 16)
            .frame(height: notch.height)

            VStack(spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    metric("CPU", value: Format.percent(s.cpu.total), fraction: s.cpu.total / 100,
                           color: Self.loadColor(s.cpu.total), page: "metric:cpu")
                    metric("Memory", value: Format.memory(s.memory.used),
                           fraction: s.memory.total > 0 ? Double(s.memory.used) / Double(s.memory.total) : 0,
                           color: Self.pressureColor(s.memory.pressure), page: "metric:memory")
                    metric("GPU", value: s.gpu.map { Format.percent($0.utilization) } ?? "–",
                           fraction: (s.gpu?.utilization ?? 0) / 100, color: Self.loadColor(s.gpu?.utilization ?? 0), page: "metric:gpu")
                    network(s)
                }
                Rectangle().fill(Color.white.opacity(0.12)).frame(height: 1)
                topApp(s)
            }
            .padding(.horizontal, flare + 16)
            .padding(.top, 8)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .contentShape(Rectangle())
        .onTapGesture { open("overview") }
    }

    @ViewBuilder private func temperature(_ s: SystemSnapshot) -> some View {
        if let celsius = s.sensors.cpuTemperature {
            HStack(spacing: 4) {
                Image(systemName: "thermometer.medium").foregroundStyle(Self.heatColor(s.thermal))
                Text(Format.temperature(celsius))
            }
            .font(.system(size: 12, weight: .semibold).monospacedDigit())
        } else {
            Color.clear.frame(width: 1, height: 1)
        }
    }

    @ViewBuilder private func battery(_ s: SystemSnapshot) -> some View {
        if let b = s.battery {
            HStack(spacing: 4) {
                Text(Format.percent(b.percent))
                Image(systemName: Self.batterySymbol(b))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(b.isCharging || b.isPluggedIn ? .green : (b.percent <= 15 ? .red : .white), .white.opacity(0.5))
            }
            .font(.system(size: 12, weight: .semibold).monospacedDigit())
        } else {
            Color.clear.frame(width: 1, height: 1)
        }
    }

    private func metric(_ title: LocalizedStringKey, value: String, fraction: Double, color: Color, page: String) -> some View {
        Button { open(page) } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 10, weight: .medium)).foregroundStyle(dim)
                Text(value).font(.system(size: 15, weight: .semibold).monospacedDigit())
                    .lineLimit(1).minimumScaleFactor(0.7)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.14))
                        Capsule().fill(color).frame(width: max(4, geo.size.width * min(max(fraction, 0), 1)))
                    }
                }
                .frame(height: 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func network(_ s: SystemSnapshot) -> some View {
        Button { open("metric:network") } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text("Network").font(.system(size: 10, weight: .medium)).foregroundStyle(dim)
                HStack(spacing: 3) {
                    Image(systemName: "arrow.down").foregroundStyle(dim)
                    Text(Format.networkRate(s.network.inRate))
                }
                HStack(spacing: 3) {
                    Image(systemName: "arrow.up").foregroundStyle(dim)
                    Text(Format.networkRate(s.network.outRate))
                }
            }
            .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
            .lineLimit(1).minimumScaleFactor(0.7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private func topApp(_ s: SystemSnapshot) -> some View {
        // An app you can name beats the "macOS" group of daemons; that one only when nothing else runs.
        if let app = s.apps.filter({ $0.kind != .system }).max(by: { $0.cpuPercent < $1.cpuPercent })
            ?? s.apps.max(by: { $0.cpuPercent < $1.cpuPercent }) {
            Button { open("metric:cpu") } label: {
                HStack(spacing: 8) {
                    AppIconView(app: app, size: 20)
                    Text(app.name).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.tail)
                    Text("busiest now").font(.system(size: 10.5)).foregroundStyle(dim).lineLimit(1)
                    Spacer(minLength: 8)
                    Text("CPU \(Format.percent(app.cpuPercent))")
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            Text("Waiting for the first sample…").font(.system(size: 12)).foregroundStyle(dim)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    static func loadColor(_ percent: Double) -> Color {
        percent >= 95 ? .red : percent >= 80 ? .orange : Color.white.opacity(0.85)
    }

    static func pressureColor(_ pressure: MemoryPressure) -> Color {
        switch pressure {
        case .normal: .green
        case .warning: .orange
        case .critical: .red
        }
    }

    static func heatColor(_ thermal: ThermalLevel) -> Color {
        switch thermal {
        case .nominal: Color.white.opacity(0.7)
        case .fair: .yellow
        case .serious: .orange
        case .critical: .red
        }
    }

    static func batterySymbol(_ b: BatteryStats) -> String {
        if b.isCharging { return "battery.100percent.bolt" }
        switch b.percent {
        case 88...: return "battery.100percent"
        case 63..<88: return "battery.75percent"
        case 38..<63: return "battery.50percent"
        case 13..<38: return "battery.25percent"
        default: return "battery.0percent"
        }
    }
}

// MARK: - Hint

struct NotchHintView: View {
    let hint: NotchHint
    let notch: CGSize
    let flare: CGFloat
    var open: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Image(systemName: hint.symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(hint.tint)
                    .frame(maxWidth: .infinity)
                Color.clear.frame(width: notch.width)
                Text(hint.trailing ?? "")
                    .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(1).minimumScaleFactor(0.7)
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, flare)
            .frame(height: notch.height)
            Text(hint.text)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1).minimumScaleFactor(0.75)
                .padding(.horizontal, flare + 14)
                .frame(maxWidth: .infinity)
                .frame(height: 24)
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture { open(hint.page) }
    }
}
