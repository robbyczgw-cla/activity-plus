import ActivityCore
import SwiftUI

/// What one module shows right now, independent of how it is drawn.
struct ModuleReading {
    var text: String = "–"
    /// 0…1 for rings, gauges, dots and colors; nil when a level makes no sense.
    var level: Double?
    var series: [Double] = []
    var seriesMax: Double?
    var up: String = ""
    var down: String = ""
    var cores: [Double] = []
    /// For "hide below": the value in percent of its scale.
    var percentOfScale: Double { (level ?? 1) * 100 }

    @MainActor
    static func read(_ config: MenuBarItemConfig, monitor: Monitor, services: AppServices, now: Date = Date()) -> ModuleReading {
        let s = monitor.snapshot
        let h = monitor.history
        var r = ModuleReading()
        let decimals = config.showDecimals ? 1 : 0
        switch config.module {
        case .status:
            r.text = ""
        case .cpu:
            r.text = Format.percent(s.cpu.total, decimals: decimals)
            r.level = s.cpu.total / 100
            r.series = h.cpu.values
            r.seriesMax = 100
            r.cores = s.cpu.perCore.map { $0 / 100 }
        case .memory:
            let fraction = Double(s.memory.used) / Double(max(1, s.memory.total))
            r.level = fraction
            r.series = h.memory.values
            r.seriesMax = Double(s.memory.total)
            switch config.memoryFigure {
            case .percent: r.text = Format.percent(fraction * 100, decimals: decimals)
            case .used: r.text = Format.memory(s.memory.used)
            case .free: r.text = Format.memory(s.memory.total > s.memory.used ? s.memory.total - s.memory.used : 0)
            case .pressure:
                r.text = s.memory.pressure.label
                r.level = s.memory.pressure == .normal ? 0.3 : (s.memory.pressure == .warning ? 0.7 : 1)
            }
        case .gpu:
            let value = s.gpu?.utilization ?? 0
            r.text = Format.percent(value, decimals: decimals)
            r.level = value / 100
            r.series = h.gpu.values
            r.seriesMax = 100
        case .disk:
            let used = 1 - Double(s.disk.free) / Double(max(1, s.disk.total))
            r.level = used
            r.series = zip(h.diskRead.values, h.diskWrite.values).map(+)
            switch config.diskFigure {
            case .free: r.text = Format.storage(s.disk.free)
            case .usedPercent: r.text = Format.percent(used * 100, decimals: decimals)
            case .activity: r.text = Format.rate(s.disk.readRate + s.disk.writeRate)
            }
            r.up = "W " + Format.rate(s.disk.writeRate)
            r.down = "R " + Format.rate(s.disk.readRate)
        case .network:
            let total = s.network.inRate + s.network.outRate
            r.text = Format.networkRate(s.network.inRate)
            r.up = "↑ " + Format.networkRate(s.network.outRate)
            r.down = "↓ " + Format.networkRate(s.network.inRate)
            r.series = zip(h.netIn.values, h.netOut.values).map(+)
            let peak = max(r.series.max() ?? 1, 1)
            r.level = min(1, total / peak)
        case .temperature:
            if let t = s.sensors.cpuTemperature {
                r.text = Format.temperature(t, decimals: decimals, unit: false)
                r.level = min(1, max(0, (t - 30) / 70))
            }
            r.series = h.cpuTemperature.values
            r.seriesMax = 110
        case .fans:
            if let fan = s.sensors.fans.max(by: { $0.rpm < $1.rpm }) {
                r.text = "\(Int(fan.rpm))"
                if let max = fan.maxRPM, max > 0 { r.level = fan.rpm / max }
            } else {
                r.text = "0"
                r.level = 0
            }
        case .battery:
            if let b = s.battery {
                r.text = Format.percent(b.percent)
                r.level = b.percent / 100
            } else if let device = services.accessories.first {
                r.text = "\(device.lowest)%"
                r.level = Double(device.lowest) / 100
            }
            r.series = h.battery.values
            r.seriesMax = 100
        case .power:
            let watts = s.battery?.systemPower ?? s.apps.reduce(0) { $0 + $1.powerWatts }
            r.text = Format.watts(watts)
            r.level = min(1, watts / 60)
            r.series = h.power.values
        case .clock:
            let zones = config.timeZones.compactMap(TimeZone.init(identifier:))
            let formatter = DateFormatter()
            formatter.dateFormat = config.clockShowsSeconds ? "HH:mm:ss" : "HH:mm"
            if zones.isEmpty {
                r.text = formatter.string(from: now)
            } else {
                r.text = zones.map { zone in
                    formatter.timeZone = zone
                    let city = zone.identifier.split(separator: "/").last.map { String($0).replacingOccurrences(of: "_", with: " ") } ?? zone.identifier
                    return "\(city.prefix(3).uppercased()) \(formatter.string(from: now))"
                }.joined(separator: "  ")
            }
        }
        return r
    }
}

/// Draws one menu bar item. Rendered to an image by `StatusItemsController`.
struct MenuBarWidget: View {
    let config: MenuBarItemConfig
    let reading: ModuleReading
    /// Menu bar text color when drawing in color (white on dark menu bars).
    let ink: Color
    var showWarning = false

    private var monochrome: Bool { config.colorMode == .monochrome }

    /// Level-based or fixed accent; batteries are inverted (low = red).
    private var accent: Color {
        switch config.colorMode {
        case .monochrome: return ink
        case .fixed: return Color(hex: config.fixedColor)
        case .byLevel:
            guard var level = reading.level else { return ink }
            if config.module == .battery { level = 1 - level }
            return level < 0.6 ? .green : (level < 0.85 ? .orange : .red)
        }
    }

    var body: some View {
        HStack(spacing: 3) {
            if showWarning {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 12)).foregroundStyle(monochrome ? ink : .orange)
            }
            if config.showLabel && config.style != .labeled && !config.label.isEmpty {
                Text(config.label).font(.system(size: 8, weight: .semibold)).foregroundStyle(ink.opacity(0.8))
            }
            content
        }
        .frame(height: 18)
        .fixedSize()
    }

    @ViewBuilder private var content: some View {
        switch config.style {
        case .icon:
            Image(systemName: showWarning ? "exclamationmark.triangle.fill" : config.module.systemImage)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(config.colorMode == .monochrome ? ink : accent)
        case .text:
            value(reading.text, size: 12)
        case .labeled:
            VStack(alignment: .leading, spacing: -2) {
                Text(config.label).font(.system(size: 7, weight: .semibold)).foregroundStyle(ink.opacity(0.75))
                value(reading.text, size: 10)
            }
        case .line:
            HStack(spacing: 3) {
                LineGlyph(values: Array(reading.series.suffix(30)), maxValue: reading.seriesMax, color: accent)
                    .frame(width: 34, height: 15)
                if config.showLabel { value(reading.text, size: 10) }
            }
        case .bars:
            HStack(spacing: 3) {
                BarsGlyph(values: Array(reading.series.suffix(16)), maxValue: reading.seriesMax, color: accent)
                    .frame(width: 30, height: 15)
                if config.showLabel { value(reading.text, size: 10) }
            }
        case .coreBars:
            CoreBarsGlyph(levels: reading.cores, color: accent).frame(height: 15)
        case .ring:
            HStack(spacing: 3) {
                ZStack {
                    Circle().stroke(ink.opacity(0.25), lineWidth: 2.5)
                    Circle().trim(from: 0, to: reading.level ?? 0)
                        .stroke(accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 13, height: 13)
                if config.showLabel { value(reading.text, size: 10) }
            }
        case .gauge:
            HStack(spacing: 3) {
                GaugeGlyph(level: reading.level ?? 0, color: accent, track: ink.opacity(0.25), needle: ink).frame(width: 22, height: 13)
                if config.showLabel { value(reading.text, size: 10) }
            }
        case .dot:
            HStack(spacing: 3) {
                Circle().fill(config.colorMode == .monochrome ? ink : accent).frame(width: 8, height: 8)
                if config.showLabel { value(reading.text, size: 10) }
            }
        case .speed:
            VStack(alignment: .trailing, spacing: -2) {
                Text(reading.up).font(.system(size: 8.5, weight: .medium)).monospacedDigit()
                Text(reading.down).font(.system(size: 8.5, weight: .medium)).monospacedDigit()
            }
            .foregroundStyle(ink)
        case .battery:
            HStack(spacing: 3) {
                BatteryGlyph(level: reading.level ?? 0, color: accent, ink: ink).frame(width: 22, height: 11)
                if config.showLabel { value(reading.text, size: 10) }
            }
        }
    }

    private func value(_ text: String, size: CGFloat) -> some View {
        Text(text)
            .font(.system(size: size, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(config.colorMode == .monochrome ? ink : accent)
    }
}

// MARK: - Glyphs (plain shapes; Swift Charts is too heavy to render every second per item)

private struct LineGlyph: View {
    let values: [Double]
    let maxValue: Double?
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            let top = max(maxValue ?? (values.max() ?? 1), 0.000_1)
            let step = proxy.size.width / CGFloat(max(values.count - 1, 1))
            let point = { (i: Int) in CGPoint(x: CGFloat(i) * step, y: proxy.size.height * (1 - CGFloat(min(values[i] / top, 1)))) }
            if values.count > 1 {
                Path { path in
                    path.move(to: CGPoint(x: 0, y: proxy.size.height))
                    for i in values.indices { path.addLine(to: point(i)) }
                    path.addLine(to: CGPoint(x: CGFloat(values.count - 1) * step, y: proxy.size.height))
                    path.closeSubpath()
                }
                .fill(color.opacity(0.25))
                Path { path in
                    path.move(to: point(0))
                    for i in values.indices.dropFirst() { path.addLine(to: point(i)) }
                }
                .stroke(color, lineWidth: 1.2)
            }
        }
    }
}

private struct BarsGlyph: View {
    let values: [Double]
    let maxValue: Double?
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            let top = max(maxValue ?? (values.max() ?? 1), 0.000_1)
            let width = proxy.size.width / CGFloat(max(values.count, 1))
            HStack(alignment: .bottom, spacing: 0) {
                ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                    Rectangle().fill(color)
                        .frame(width: max(1, width - 1), height: max(1, proxy.size.height * CGFloat(min(value / top, 1))))
                        .frame(width: width, alignment: .bottom)
                }
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
    }
}

private struct CoreBarsGlyph: View {
    let levels: [Double]
    let color: Color

    var body: some View {
        HStack(alignment: .bottom, spacing: 1) {
            ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                ZStack(alignment: .bottom) {
                    Rectangle().fill(color.opacity(0.2))
                    Rectangle().fill(color).frame(height: max(1, 15 * CGFloat(min(level, 1))))
                }
                .frame(width: 3, height: 15)
            }
        }
    }
}

private struct GaugeGlyph: View {
    let level: Double
    let color: Color
    let track: Color
    let needle: Color

    var body: some View {
        GeometryReader { proxy in
            let center = CGPoint(x: proxy.size.width / 2, y: proxy.size.height)
            let radius = min(proxy.size.width / 2, proxy.size.height) - 1.5
            ZStack {
                Path { $0.addArc(center: center, radius: radius, startAngle: .degrees(180), endAngle: .degrees(360), clockwise: false) }
                    .stroke(track, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                Path { $0.addArc(center: center, radius: radius, startAngle: .degrees(180), endAngle: .degrees(180 + 180 * min(max(level, 0), 1)), clockwise: false) }
                    .stroke(color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                Path { path in
                    let angle = Angle.degrees(180 + 180 * min(max(level, 0), 1)).radians
                    path.move(to: center)
                    path.addLine(to: CGPoint(x: center.x + cos(angle) * (radius - 3), y: center.y + sin(angle) * (radius - 3)))
                }
                .stroke(needle, style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
            }
        }
    }
}

private struct BatteryGlyph: View {
    let level: Double
    let color: Color
    let ink: Color

    var body: some View {
        HStack(spacing: 1) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2.5).stroke(ink.opacity(0.6), lineWidth: 1)
                RoundedRectangle(cornerRadius: 1.5).fill(color)
                    .frame(width: max(1, 17 * CGFloat(min(max(level, 0), 1))))
                    .padding(1.5)
            }
            .frame(width: 20, height: 11)
            RoundedRectangle(cornerRadius: 1).fill(ink.opacity(0.6)).frame(width: 1.5, height: 4)
        }
    }
}
