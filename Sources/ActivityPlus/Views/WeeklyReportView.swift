import ActivityCore
import SwiftUI

struct WeeklyReportView: View {
    @Environment(AppServices.self) private var services
    @State private var report: WeeklyReport?
    @State private var current = false
    @AppStorage("weeklyReportEnabled") private var notify = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Picker("", selection: $current) {
                        Text("Last week").tag(false)
                        Text("This week so far").tag(true)
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 260)
                    Spacer()
                    Toggle("Monday notification", isOn: $notify).toggleStyle(.switch).controlSize(.small)
                }
                if let report {
                    Text("\(report.start.formatted(date: .abbreviated, time: .omitted)) – \(report.end.addingTimeInterval(-1).formatted(date: .abbreviated, time: .omitted))")
                        .font(.title2.weight(.semibold))
                    if report.topEnergy.isEmpty {
                        ContentUnavailableView("Not enough history yet", systemImage: "calendar",
                                               description: Text("The report fills up while Activity+ runs. Check back after a few days."))
                    } else {
                        totals(report)
                        if !report.biggestIncreases.isEmpty { increases(report) }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 14)], spacing: 14) {
                            ranking("Most energy", "bolt", .green, report.topEnergy) { String(format: "%.1f Wh", $0.energyWh) }
                            ranking("Most memory (average)", "memorychip", .purple, report.topMemory) { Format.memory(UInt64($0.averageMemory)) }
                            ranking("Most CPU (average)", "cpu", .blue, report.topCPU) { Format.percent($0.averageCPU, decimals: 1) }
                            ranking("Most network", "network", .teal, report.topNetwork) { Format.storage(UInt64($0.networkBytes)) }
                        }
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 200)
                }
            }
            .padding(20)
        }
        .navigationTitle("Weekly Report")
        .task(id: current) { report = await services.weeklyReport(current: current) }
    }

    private func totals(_ r: WeeklyReport) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
            comparison("Energy", String(format: "%.0f Wh", r.totals.energyWh), r.totals.energyWh, r.previousTotals.energyWh, r.hasPreviousWeek)
            comparison("Written to disk", Format.storage(UInt64(r.totals.diskWritten)), r.totals.diskWritten, r.previousTotals.diskWritten, r.hasPreviousWeek)
            comparison("Downloaded", Format.storage(UInt64(r.totals.received)), r.totals.received, r.previousTotals.received, r.hasPreviousWeek)
            comparison("Average CPU", Format.percent(r.totals.averageCPU), r.totals.averageCPU, r.previousTotals.averageCPU, r.hasPreviousWeek)
        }
    }

    private func comparison(_ title: String, _ value: String, _ now: Double, _ before: Double, _ hasBefore: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            BigNumber(text: value, size: 22)
            if hasBefore, before > 0 {
                let change = (now - before) / before * 100
                Text((change >= 0 ? "▲ " : "▼ ") + Format.percent(abs(change)) + " vs. week before")
                    .font(.caption).foregroundStyle(change > 10 ? .orange : .secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }

    private func increases(_ r: WeeklyReport) -> some View {
        Card {
            CardHeader(title: "Needed a lot more energy than the week before", systemImage: "arrow.up.right", tint: .orange)
            ForEach(r.biggestIncreases) { change in
                HStack {
                    icon(change.bundlePath)
                    Text(change.name)
                    Spacer()
                    Text(String(format: "%.1f → %.1f Wh (%.1f×)", change.before, change.now, change.factor)).monospacedDigit().foregroundStyle(.secondary)
                }
            }
        }
    }

    private func ranking(_ title: String, _ symbol: String, _ tint: Color, _ apps: [HistoryStore.AppTotal], value: @escaping (HistoryStore.AppTotal) -> String) -> some View {
        Card {
            CardHeader(title: title, systemImage: symbol, tint: tint)
            ForEach(Array(apps.enumerated()), id: \.element.id) { index, app in
                HStack(spacing: 8) {
                    Text("\(index + 1)").font(.caption.monospacedDigit()).foregroundStyle(.tertiary).frame(width: 14)
                    icon(app.bundlePath)
                    Text(app.name).lineLimit(1)
                    Spacer()
                    Text(value(app)).monospacedDigit().foregroundStyle(.secondary)
                }
                .font(.callout)
            }
        }
    }

    @ViewBuilder private func icon(_ bundlePath: String?) -> some View {
        if let bundlePath {
            Image(nsImage: NSWorkspace.shared.icon(forFile: bundlePath)).resizable().frame(width: 18, height: 18)
        } else {
            Image(systemName: "terminal").frame(width: 18, height: 18)
        }
    }
}
