import ActivityCore
import Charts
import SwiftUI

/// "54.76 GB" with the number large and the unit small, like the rest of macOS dashboards.
struct BigNumber: View {
    let text: String
    var size: CGFloat = 28

    var body: some View {
        let parts = Format.split(text)
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(parts.value)
                .font(.system(size: size, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
            if !parts.unit.isEmpty {
                Text(parts.unit)
                    .font(.system(size: size * 0.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.6)
    }
}

struct Sparkline: View {
    let values: [Double]
    var tint: Color = .accentColor
    var maxValue: Double?

    var body: some View {
        let floor = domain.lowerBound
        Chart(Array(values.enumerated()), id: \.offset) { point in
            // Fill down to the bottom of the visible scale, not to zero, so zoomed-in series keep their shape.
            AreaMark(x: .value("t", point.offset), yStart: .value("floor", floor), yEnd: .value("v", point.element))
                .foregroundStyle(tint.opacity(0.18).gradient)
                .interpolationMethod(.monotone)
            LineMark(x: .value("t", point.offset), y: .value("v", point.element))
                .foregroundStyle(tint)
                .lineStyle(StrokeStyle(lineWidth: 1.5))
                .interpolationMethod(.monotone)
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: domain)
        .chartXScale(domain: 0...max(values.count - 1, 1))
    }

    /// Fixed scales (percentages) start at 0; free scales hug the data so flat series stay readable.
    private var domain: ClosedRange<Double> {
        if let maxValue { return 0...max(maxValue, 0.000_1) }
        let high = values.max() ?? 1
        let low = values.min() ?? 0
        let pad = max((high - low) * 0.2, high * 0.05, 0.000_1)
        return max(0, low - pad)...(high + pad)
    }
}

struct UsageBar: View {
    let fraction: Double
    var tint: Color = .accentColor

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(tint.gradient)
                    .frame(width: max(2, proxy.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: 5)
        .animation(.smooth, value: fraction)
    }
}

/// A labelled figure in a card: "Reading 22 kB/s".
struct StatLine: View {
    let label: String
    let value: String
    var tint: Color?

    var body: some View {
        HStack {
            if let tint { Circle().fill(tint).frame(width: 7, height: 7) }
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit().fontWeight(.medium)
        }
        .font(.callout)
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.separator.opacity(0.5)))
    }
}

struct CardHeader: View {
    let title: String
    let systemImage: String
    var tint: Color = .secondary
    var trailing: String?

    var body: some View {
        HStack {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .foregroundStyle(tint)
            Spacer()
            if let trailing {
                Text(trailing).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct AppIconView: View {
    let app: AppGroup
    var size: CGFloat = 22

    var body: some View {
        Image(nsImage: IconCache.icon(for: app))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
    }
}

/// A multi-series live chart used on every metric page.
struct LiveChart: View {
    struct Line: Identifiable {
        let name: String
        let values: [Double]
        let color: Color
        var id: String { name }
    }

    let lines: [Line]
    var format: (Double) -> String
    var maxValue: Double?
    var interval: TimeInterval

    var body: some View {
        Chart {
            ForEach(lines) { line in
                ForEach(Array(line.values.enumerated()), id: \.offset) { point in
                    LineMark(
                        x: .value("Seconds ago", -Double(line.values.count - 1 - point.offset) * interval),
                        y: .value(line.name, point.element),
                        series: .value("Series", line.name)
                    )
                    .foregroundStyle(line.color)
                    .interpolationMethod(.monotone)
                    if lines.count == 1 {
                        AreaMark(
                            x: .value("Seconds ago", -Double(line.values.count - 1 - point.offset) * interval),
                            y: .value(line.name, point.element)
                        )
                        .foregroundStyle(line.color.opacity(0.15).gradient)
                        .interpolationMethod(.monotone)
                    }
                }
            }
        }
        .chartYScale(domain: 0...max(maxValue ?? (lines.flatMap(\.values).max() ?? 1) * 1.1, 0.000_1))
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine()
                AxisValueLabel { if let v = value.as(Double.self) { Text(format(v)) } }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(v == 0 ? "now" : (abs(v) < 120 ? "\(Int(-v))s" : "\(Int(-v / 60))m"))
                    }
                }
            }
        }
        .chartLegend(lines.count > 1 ? .visible : .hidden)
        .chartForegroundStyleScale(domain: lines.map(\.name), range: lines.map(\.color))
    }
}
