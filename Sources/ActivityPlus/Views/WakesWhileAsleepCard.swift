import ActivityCore
import Charts
import SwiftUI

/// Who wakes the Mac while it sleeps: dark wakes per night, their reasons and the processes behind them.
struct WakesWhileAsleepCard: View {
    @Environment(\.density) private var density
    @Environment(AppServices.self) private var services
    @State private var nights: [SleepWakes.Night] = []
    @State private var busy: [(name: String, wakes: Int, averageCPU: Double)] = []
    @State private var loaded = false

    private var wakes: [SleepWakes.Wake] { nights.flatMap(\.wakes) }

    var body: some View {
        Card {
            CardHeader(title: "Wakes while asleep", systemImage: "moon.zzz", tint: .indigo,
                       trailing: loaded ? String(localized: "last 7 nights") : String(localized: "reading…"))
            Text("While it sleeps, the Mac wakes for a few seconds at a time without turning on the screen. A few dozen a night are normal; many more drain the battery.")
                .appFont(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if loaded && wakes.isEmpty {
                Label("No wakes while asleep in the last 7 nights.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            }
            if !wakes.isEmpty {
                summary
                Divider()
                reasons
                processes
            }
        }
        .task { await load() }
    }

    private var summary: some View {
        HStack(alignment: .center, spacing: 24) {
            if let last = nights.first {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.nightTitle(last.evening)).appFont(.caption).foregroundStyle(.secondary)
                    BigNumber(text: "\(last.wakes.count)", size: 28)
                    if last.asleep > 600 {
                        let perHour = Double(last.wakes.count) / (last.asleep / 3600)
                        Text("wakes in \(Format.duration(last.asleep)) asleep, \(String(format: "%.1f", perHour)) per hour")
                            .appFont(.caption).foregroundStyle(.secondary).monospacedDigit()
                    } else {
                        Text("wakes").appFont(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(minWidth: 170, alignment: .leading)
            }
            Chart(nights.prefix(7).reversed()) { night in
                BarMark(x: .value("Night", night.evening, unit: .day), y: .value("Wakes", night.wakes.count))
                    .foregroundStyle(.indigo.gradient)
                    .annotation(position: .top, overflowResolution: .init(x: .disabled, y: .disabled)) { Text("\(night.wakes.count)").appFont(.caption2).foregroundStyle(.secondary).fixedSize() }
            }
            .chartXAxis { AxisMarks(values: .stride(by: .day)) { _ in AxisValueLabel(format: .dateTime.weekday(.abbreviated)) } }
            .chartYAxis(.hidden)
            .frame(height: 90)
        }
    }

    @ViewBuilder private var reasons: some View {
        let causes = Dictionary(grouping: wakes, by: \.cause).map { ($0.key, $0.value.count) }.sorted { $0.1 > $1.1 }.prefix(5)
        Text("Why it woke").appFont(.caption, weight: .semibold).foregroundStyle(.secondary)
        ForEach(Array(causes), id: \.0) { cause, count in
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(cause.title).fontWeight(.medium)
                    Spacer()
                    Text("\(count)×").monospacedDigit().foregroundStyle(.secondary)
                }
                Text(cause.explanation).appFont(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let advice = cause.advice {
                    Label(advice, systemImage: "lightbulb").appFont(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .appFont(.callout)
            .padding(.vertical, 2)
        }
    }

    @ViewBuilder private var processes: some View {
        let active = SleepWakes.processes(in: wakes).prefix(6)
        if !active.isEmpty {
            Divider()
            Text("What ran during the wakes").appFont(.caption, weight: .semibold).foregroundStyle(.secondary)
            ForEach(Array(active), id: \.name) { item in
                HStack {
                    Text(item.name).lineLimit(1)
                    if let what = SleepWakes.describe(item.name) { Text(what).foregroundStyle(.secondary).lineLimit(1) }
                    Spacer()
                    Text("in \(item.wakes) of \(wakes.count) wakes").monospacedDigit().foregroundStyle(.secondary)
                }
                .appFont(.callout)
            }
        }
        if !busy.isEmpty {
            Divider()
            Text("Busy right after, from the history").appFont(.caption, weight: .semibold).foregroundStyle(.secondary)
            ForEach(busy.prefix(5), id: \.name) { app in
                HStack {
                    Text(app.name).lineLimit(1)
                    Spacer()
                    Text("after \(app.wakes) wakes, \(Format.percent(app.averageCPU)) CPU on average").monospacedDigit().foregroundStyle(.secondary)
                }
                .appFont(.callout)
            }
        }
    }

    static func nightTitle(_ evening: Date) -> String {
        let calendar = Calendar.current
        // Nights run noon to noon: before noon the current one is last night, after noon it is the one before.
        let now = Date()
        let current = calendar.startOfDay(for: now.addingTimeInterval(-12 * 3600))
        let afternoon = calendar.component(.hour, from: now) >= 12
        if evening == current { return afternoon ? String(localized: "Since noon today") : String(localized: "Last night") }
        if afternoon, let previous = calendar.date(byAdding: .day, value: -1, to: current), evening == previous {
            return String(localized: "Last night")
        }
        let next = calendar.date(byAdding: .day, value: 1, to: evening) ?? evening
        return String(localized: "Night to \(next.formatted(.dateTime.weekday(.wide).day().month(.abbreviated)))")
    }

    private func load() async {
        let store = services.history
        let result = await Task.detached(priority: .utility) { () -> ([SleepWakes.Night], [(name: String, wakes: Int, averageCPU: Double)]) in
            let since = Date().addingTimeInterval(-7 * 86_400)
            guard let lines = SleepWakes.readLog() else { return ([], []) }
            let parsed = SleepWakes.parse(lines: lines, since: since)
            let windows = store.appLoadWindows(from: since, to: Date())
            return (SleepWakes.nights(parsed.wakes, sleeps: parsed.sleeps).filter { !$0.wakes.isEmpty },
                    SleepWakes.busyAfter(parsed.wakes, windows: windows, ignoring: ["Activity+"]))
        }.value
        nights = result.0
        busy = result.1
        loaded = true
    }
}
