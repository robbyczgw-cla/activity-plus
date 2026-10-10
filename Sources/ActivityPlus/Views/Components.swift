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
                .appFont(size: size, weight: .semibold, design: .rounded)
                .monospacedDigit()
                .contentTransition(.numericText())
            if !parts.unit.isEmpty {
                Text(parts.unit)
                    .appFont(size: size * 0.5, weight: .medium, design: .rounded)
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
            // Labels are written as English literals and looked up in the string catalog at runtime.
            Text(LocalizedStringKey(label)).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit().fontWeight(.medium)
        }
        .appFont(.callout)
    }
}

struct Card<Content: View>: View {
    @Environment(\.density) private var density
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: density.cardLines) { content }
            .padding(density.card)
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
    /// Longer explanation behind an ⓘ; defaults to the entry for this title in `CardInfo`.
    var info: String?

    var body: some View {
        HStack(spacing: 6) {
            Label(LocalizedStringKey(title), systemImage: systemImage)
                .appFont(.headline)
                .foregroundStyle(tint)
            if let text = info ?? CardInfo.text(for: title) { InfoButton(text: text).appFont(.callout) }
            Spacer()
            if let trailing {
                Text(LocalizedStringKey(trailing)).appFont(.caption).foregroundStyle(.secondary)
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
    @Environment(\.uiScale) private var scale
    @AppStorage("chartMinutes") private var minutes = 10

    /// The chosen time range, averaged down to at most 300 points so an hour draws as fast as ten minutes.
    private var shown: (lines: [Line], interval: TimeInterval) {
        let wanted = max(2, Int(Double(minutes) * 60 / max(interval, 0.1)))
        let step = max(1, Int((Double(wanted) / 300).rounded(.up)))
        let trimmed = lines.map { line -> Line in
            let recent = Array(line.values.suffix(wanted))
            guard step > 1 else { return Line(name: line.name, values: recent, color: line.color) }
            let buckets = stride(from: 0, to: recent.count, by: step).map { start -> Double in
                let bucket = recent[start..<min(start + step, recent.count)]
                return bucket.reduce(0, +) / Double(bucket.count)
            }
            return Line(name: line.name, values: buckets, color: line.color)
        }
        return (trimmed, interval * Double(step))
    }

    var body: some View {
        let (lines, interval) = shown
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
                AxisValueLabel { if let v = value.as(Double.self) { axisText(Text(format(v))) } }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        axisText(Text(v == 0 ? "now" : (abs(v) < 120 ? "\(Int(-v))s" : "\(Int(-v / 60))m")))
                    }
                }
            }
        }
        .chartLegend(lines.count > 1 ? .visible : .hidden)
        .chartForegroundStyleScale(domain: lines.map(\.name), range: lines.map(\.color))
    }

    /// Axis labels keep the Charts default at Standard and follow the text size otherwise.
    private func axisText(_ text: Text) -> Text {
        scale == 1 ? text : text.font(.system(size: AppFont.pointSize(.caption2) * scale))
    }
}
