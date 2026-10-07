import ActivityCore
import Charts
import SwiftUI

/// Heat, memory pressure and Wi-Fi over the same period as the history chart: the conditions that
/// explain a slow afternoon even when no single app stands out.
struct ConditionsCard: View {
    let points: [HistoryStore.SystemPoint]
    let range: HistoryStore.Range
    var selectedDate: Date?

    private var recorded: [HistoryStore.SystemPoint] { points.filter { $0.thermal != nil } }
    private var wifi: [HistoryStore.SystemPoint] { points.filter { $0.wifiRSSI != nil } }

    var body: some View {
        Card {
            CardHeader(title: "Conditions", systemImage: "thermometer.medium", tint: .orange, trailing: "last \(range.rawValue)")
            if recorded.count < 2 {
                Text("Heat, memory pressure and Wi-Fi signal are kept from version 0.3 on. Come back in a few minutes.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                band(title: "Heat", summary: heatSummary) { p in
                    switch p.thermal ?? 0 {
                    case 0: .green.opacity(0.35)
                    case 1: .yellow
                    case 2: .orange
                    default: .red
                    }
                }
                band(title: "Memory pressure", summary: pressureSummary) { p in
                    switch p.pressure ?? 1 {
                    case ..<2: .green.opacity(0.35)
                    case 2..<4: .yellow
                    default: .red
                    }
                }
                if wifi.count >= 2 { wifiChart }
            }
        }
    }

    /// One colored strip per time bucket, so a hot or tight stretch lines up with the chart above.
    private func band(title: String, summary: String, color: @escaping (HistoryStore.SystemPoint) -> Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.callout.weight(.medium))
                Spacer()
                Text(summary).font(.caption).foregroundStyle(.secondary)
            }
            Chart {
                ForEach(recorded) { p in
                    RectangleMark(xStart: .value("From", p.date), xEnd: .value("To", p.date.addingTimeInterval(bucket)),
                                  yStart: .value("Low", 0), yEnd: .value("High", 1))
                        .foregroundStyle(color(p))
                }
                if let selectedDate { RuleMark(x: .value("Selected", selectedDate)).foregroundStyle(.secondary) }
            }
            .chartXScale(domain: domain)
            .chartYAxis {
                // An empty label as wide as the history chart's, so both plots span the same time.
                AxisMarks(position: .trailing, values: [0.5]) { _ in AxisValueLabel { Color.clear.frame(width: Self.axisWidth, height: 1) } }
            }
            .chartXAxis(.hidden)
            .frame(height: 14)
        }
    }

    private var wifiChart: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Wi-Fi signal").font(.callout.weight(.medium))
                Spacer()
                Text(wifiSummary).font(.caption).foregroundStyle(.secondary)
            }
            Chart {
                ForEach(wifi) { p in
                    LineMark(x: .value("Time", p.date), y: .value("dBm", p.wifiRSSI ?? 0), series: .value("Line", "Signal"))
                        .foregroundStyle(.teal)
                    if let noise = p.wifiNoise {
                        LineMark(x: .value("Time", p.date), y: .value("dBm", noise), series: .value("Line", "Noise"))
                            .foregroundStyle(.gray.opacity(0.6))
                    }
                }
                if let selectedDate { RuleMark(x: .value("Selected", selectedDate)).foregroundStyle(.secondary) }
            }
            .chartXScale(domain: domain)
            .chartYScale(domain: -100 ... -20)
            .chartYAxis {
                AxisMarks(position: .trailing, values: [-90, -70, -50, -30]) { value in
                    AxisGridLine()
                    AxisValueLabel { if let v = value.as(Int.self) { Text("\(v) dBm").frame(width: Self.axisWidth, alignment: .leading) } }
                }
            }
            .frame(height: 90)
            Text("Teal is the signal, gray the noise. The gap between them matters more than the signal alone: under 25 dB Wi-Fi slows down, under 15 dB it drops out.")
                .font(.caption).foregroundStyle(.tertiary)
        }
    }

    /// Width of the trailing axis labels, shared with the history chart so the time axes line up.
    static let axisWidth: CGFloat = 62

    static func domain(_ range: HistoryStore.Range) -> ClosedRange<Date> {
        let end = Date()
        return end.addingTimeInterval(-range.seconds) ... end
    }

    private var bucket: TimeInterval {
        guard recorded.count > 1 else { return 60 }
        return recorded[1].date.timeIntervalSince(recorded[0].date)
    }

    private var domain: ClosedRange<Date> { Self.domain(range) }

    private func duration(_ count: Int) -> String {
        Format.duration(Double(count) * bucket)
    }

    private var heatSummary: String {
        let hot = recorded.filter { ($0.thermal ?? 0) >= 2 }.count
        let warm = recorded.filter { ($0.thermal ?? 0) == 1 }.count
        if hot > 0 { return "hot for about \(duration(hot))" }
        if warm > 0 { return "warm for about \(duration(warm)), never hot" }
        return "normal the whole time"
    }

    private var pressureSummary: String {
        let critical = recorded.filter { ($0.pressure ?? 1) >= 4 }.count
        let elevated = recorded.filter { ($0.pressure ?? 1) == 2 }.count
        if critical > 0 { return "critical for about \(duration(critical))" }
        if elevated > 0 { return "elevated for about \(duration(elevated))" }
        return "normal the whole time"
    }

    private var wifiSummary: String {
        let values = wifi.compactMap(\.wifiRSSI)
        guard let worst = values.min() else { return "" }
        let average = values.reduce(0, +) / Double(values.count)
        return String(format: "average %.0f dBm, weakest %.0f dBm", average, worst)
    }
}
