import ActivityCore
import Charts
import SwiftUI

struct HistoryView: View {
    @Environment(AppServices.self) private var services
    @State private var range: HistoryStore.Range = .hours24
    @State private var metric: Metric = .cpu
    @State private var points: [HistoryStore.SystemPoint] = []
    @State private var apps: [HistoryStore.AppTotal] = []
    @State private var today = HistoryStore.Totals()
    @State private var week = HistoryStore.Totals()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Picker("Range", selection: $range) {
                        ForEach(HistoryStore.Range.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 260)
                    Spacer()
                    Picker("Metric", selection: $metric) {
                        ForEach(Metric.allCases) { Label($0.title, systemImage: $0.systemImage).tag($0) }
                    }
                    .frame(width: 180)
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
                    total("Written today", Format.storage(UInt64(today.diskWritten)), .orange)
                    total("Downloaded today", Format.storage(UInt64(today.received)), .teal)
                    total("Downloaded, 7 days", Format.storage(UInt64(week.received)), .teal)
                    total("Uploaded, 7 days", Format.storage(UInt64(week.sent)), .indigo)
                    if today.energyWh > 0 { total("Energy today", String(format: "%.0f Wh", today.energyWh), .green) }
                }

                Card {
                    CardHeader(title: metric.title, systemImage: metric.systemImage, tint: metric.tint, trailing: "last \(range.rawValue)")
                    if points.count < 2 {
                        Text("History fills up while Activity+ runs. Come back in a few minutes.")
                            .foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 180)
                    } else {
                        chart.frame(height: 220)
                    }
                }

                Card {
                    CardHeader(title: "Apps that used the most", systemImage: "list.number", tint: metric.tint, trailing: "last \(range.rawValue)")
                    let sorted = apps.sorted { value($0) > value($1) }.prefix(15)
                    let top = sorted.first.map(value) ?? 1
                    if sorted.isEmpty {
                        Text("No app data yet for this period.").foregroundStyle(.secondary)
                    }
                    ForEach(Array(sorted)) { app in
                        HStack(spacing: 10) {
                            if let path = app.bundlePath {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().frame(width: 20, height: 20)
                            } else {
                                Image(systemName: "terminal").frame(width: 20, height: 20)
                            }
                            Text(app.name).lineLimit(1)
                            Spacer()
                            UsageBar(fraction: value(app) / max(top, 0.000_1), tint: metric.tint).frame(width: 120)
                            Text(format(app)).monospacedDigit().frame(width: 90, alignment: .trailing)
                        }
                        .font(.callout)
                    }
                }
                Text("Stored on this Mac in \(services.history.url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")) (\(Format.storage(services.history.fileSize))).")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            .padding(20)
        }
        .navigationTitle("History")
        .task(id: "\(range.rawValue)") { await load() }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                await load()
            }
        }
    }

    @ChartContentBuilder private func marks(_ p: HistoryStore.SystemPoint) -> some ChartContent {
        switch metric {
        case .cpu: LineMark(x: .value("Time", p.date), y: .value("CPU", p.cpu)).foregroundStyle(metric.tint)
        case .memory: LineMark(x: .value("Time", p.date), y: .value("Memory", p.memory)).foregroundStyle(metric.tint)
        case .gpu: LineMark(x: .value("Time", p.date), y: .value("GPU", p.gpu)).foregroundStyle(metric.tint)
        case .disk: LineMark(x: .value("Time", p.date), y: .value("Disk", p.diskRead + p.diskWrite)).foregroundStyle(metric.tint)
        case .network: LineMark(x: .value("Time", p.date), y: .value("Network", p.netIn + p.netOut)).foregroundStyle(metric.tint)
        case .energy: LineMark(x: .value("Time", p.date), y: .value("Power", p.power ?? 0)).foregroundStyle(metric.tint)
        }
    }

    private var chart: some View {
        Chart(points) { point in marks(point) }
            .chartYAxis {
                AxisMarks(position: .trailing) { value in
                    AxisGridLine()
                    AxisValueLabel { if let v = value.as(Double.self) { Text(metric.format(v)) } }
                }
            }
    }

    private func total(_ title: String, _ value: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(tint)
            BigNumber(text: value, size: 22)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }

    private func value(_ app: HistoryStore.AppTotal) -> Double {
        switch metric {
        case .cpu: app.averageCPU
        case .memory: app.averageMemory
        case .gpu: app.gpuAverage
        case .disk: app.diskBytes
        case .network: app.networkBytes
        case .energy: app.energyWh
        }
    }

    private func format(_ app: HistoryStore.AppTotal) -> String {
        switch metric {
        case .cpu, .gpu: Format.percent(value(app), decimals: 1) + " avg"
        case .memory: Format.memory(UInt64(app.averageMemory)) + " avg"
        case .disk, .network: Format.storage(UInt64(value(app)))
        case .energy: String(format: "%.1f Wh", app.energyWh)
        }
    }

    private func load() async {
        let store = services.history
        let range = range
        let startOfDay = Calendar.current.startOfDay(for: Date())
        let result = await Task.detached(priority: .utility) {
            (store.systemSeries(range), store.topApps(range), store.totals(since: startOfDay),
             store.totals(since: Date().addingTimeInterval(-7 * 86_400)))
        }.value
        points = result.0
        apps = result.1
        today = result.2
        week = result.3
    }
}
