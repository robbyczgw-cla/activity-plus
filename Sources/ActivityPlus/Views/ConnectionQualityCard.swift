import ActivityCore
import Charts
import SwiftUI

/// Latency, jitter and loss over time: tells a slow connection from a flaky one.
struct ConnectionQualityCard: View {
    @Environment(AppServices.self) private var services
    @AppStorage("perf.connectionQuality") private var enabled = false
    @AppStorage("pingTarget") private var target = ""
    @State private var draft = ""
    @State private var series: [PingResult] = []
    @State private var hours = 6.0

    private var gateway: String? { NetworkInfo.primaryGateway() }

    var body: some View {
        Card {
            HStack {
                CardHeader(title: "Connection quality", systemImage: "waveform.badge.magnifyingglass", tint: .teal)
                Spacer()
                Toggle("Measure", isOn: $enabled).toggleStyle(.switch).controlSize(.small)
            }
            if !enabled {
                Text("Pings your router every 30 seconds and keeps latency, jitter and packet loss in the history, so you can tell a slow connection from a dropping one. Nothing leaves your network unless you add a host below.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 24) {
                    ForEach(services.pings, id: \.target) { ping in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(ping.target == gateway ? "Router (\(ping.target))" : ping.target).font(.caption).foregroundStyle(.secondary)
                            if ping.isOutage {
                                Text("No answer").font(.title3.weight(.semibold)).foregroundStyle(.red)
                            } else {
                                Text(ping.averageMs.map { String(format: "%.0f ms", $0) } ?? "–").font(.title3.weight(.semibold)).monospacedDigit()
                            }
                            Text("jitter \(ping.jitterMs.map { String(format: "%.0f ms", $0) } ?? "–") · loss \(Int(ping.lossPercent.rounded())) %")
                                .font(.caption).foregroundStyle(ping.lossPercent > 0 ? .orange : .secondary).monospacedDigit()
                        }
                    }
                    if services.pings.isEmpty { Text("First measurement in a moment…").foregroundStyle(.secondary) }
                    Spacer()
                    Picker("", selection: $hours) {
                        Text("1 h").tag(1.0); Text("6 h").tag(6.0); Text("24 h").tag(24.0); Text("7 d").tag(168.0)
                    }
                    .pickerStyle(.segmented).frame(width: 190).labelsHidden()
                }
                if series.count > 1 {
                    Chart {
                        ForEach(Array(series.enumerated()), id: \.offset) { _, p in
                            if let ms = p.averageMs {
                                LineMark(x: .value("Time", p.date), y: .value("ms", ms), series: .value("Target", p.target))
                                    .foregroundStyle(by: .value("Target", p.target == gateway ? "Router" : p.target))
                            }
                            if p.lossPercent > 0 {
                                PointMark(x: .value("Time", p.date), y: .value("ms", p.averageMs ?? 0))
                                    .foregroundStyle(p.isOutage ? .red : .orange).symbolSize(p.isOutage ? 60 : 30)
                            }
                        }
                    }
                    .chartYAxisLabel("ms")
                    .frame(height: 130)
                    let outages = series.filter(\.isOutage).count
                    let lossy = series.filter { $0.lossPercent > 0 && !$0.isOutage }.count
                    Text(outages == 0 && lossy == 0 ? "No lost packets in this period." : "\(outages) outage(s) and \(lossy) round(s) with packet loss in this period (red and orange points).")
                        .font(.caption).foregroundStyle(outages > 0 ? .red : .secondary)
                }
                HStack {
                    TextField("Also ping a host (optional, e.g. 1.1.1.1)", text: $draft)
                        .textFieldStyle(.roundedBorder).frame(maxWidth: 320)
                        .onSubmit(saveTarget)
                    Button("Save", action: saveTarget).disabled(draft == target)
                    if !target.isEmpty { Button("Remove") { draft = ""; saveTarget() } }
                }
                Text(target.isEmpty ? "Only your router is pinged." : "\(target) is pinged every 30 seconds and sees your IP address.")
                    .font(.caption).foregroundStyle(.secondary)
                if !draft.isEmpty && !ConnectionProbe.isValidTarget(draft) {
                    Text("Enter a host name or an IP address.").font(.caption).foregroundStyle(.red)
                }
            }
        }
        .onAppear { draft = target }
        .onChange(of: enabled) { _, on in if on { services.probeConnection() } }
        .task(id: "\(hours)-\(services.pings.first?.date.timeIntervalSince1970 ?? 0)-\(enabled)") {
            series = enabled ? services.history.pings(since: Date().addingTimeInterval(-hours * 3600)) : []
        }
    }

    private func saveTarget() {
        let value = draft.trimmingCharacters(in: .whitespaces)
        guard value.isEmpty || ConnectionProbe.isValidTarget(value) else { return }
        target = value
        services.probeConnection()
    }
}
