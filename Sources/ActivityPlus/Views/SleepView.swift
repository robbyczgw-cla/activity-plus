import ActivityCore
import SwiftUI

/// What keeps the Mac awake, what woke it up, and which apps drained the battery while unplugged.
struct SleepView: View {
    @Environment(AppServices.self) private var services
    @State private var blockers: [SleepBlocker] = []
    @State private var events: [PowerEvent] = []
    @State private var drain = HistoryStore.BatteryDrain()
    @State private var drainApps: [HistoryStore.AppTotal] = []
    @State private var range: Double = 86_400
    @State private var loading = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Card {
                    CardHeader(title: "Keeping your Mac awake right now", systemImage: "cup.and.saucer", tint: .orange)
                    if blockers.isEmpty && !loading {
                        Text("Nothing. Your Mac can sleep when idle.").foregroundStyle(.secondary)
                    }
                    ForEach(blockers) { blocker in
                        HStack {
                            Image(systemName: blocker.preventsDisplaySleep ? "display" : "moon.zzz").frame(width: 20).foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(blocker.processName).fontWeight(.medium)
                                Text(blocker.reason).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Text(blocker.preventsDisplaySleep ? "Keeps the display on" : "Prevents sleep")
                                .font(.caption).foregroundStyle(.secondary)
                            if let since = blocker.since {
                                Text("since \(since.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(.tertiary)
                            }
                        }
                    }
                }

                HStack {
                    Picker("", selection: $range) {
                        Text("Last 24 hours").tag(86_400.0)
                        Text("Last 3 days").tag(3 * 86_400.0)
                        Text("Last 7 days").tag(7 * 86_400.0)
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 360)
                    Spacer()
                    if loading { ProgressView().controlSize(.small) }
                }

                Card {
                    CardHeader(title: "Battery use while unplugged", systemImage: "battery.50percent", tint: .green)
                    if loading {
                        Text("Reading the power log…").foregroundStyle(.secondary)
                    } else if drain.hoursOnBattery < 0.05 {
                        Text("The Mac was plugged in the whole time.").foregroundStyle(.secondary)
                    } else {
                        HStack(spacing: 30) {
                            figure("On battery", Format.duration(drain.hoursOnBattery * 3600))
                            figure("Battery used", Format.percent(drain.percentUsed))
                            figure("Per hour", Format.percent(drain.percentUsed / max(drain.hoursOnBattery, 0.1), decimals: 1))
                            if drain.energyWh > 0 { figure("Energy", String(format: "%.0f Wh", drain.energyWh)) }
                        }
                        Text("Apps that used the most energy on battery").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 6)
                        let total = max(drainApps.reduce(0) { $0 + $1.energyWh }, 0.001)
                        ForEach(drainApps.prefix(8)) { app in
                            HStack {
                                Text(app.name).lineLimit(1)
                                Spacer()
                                UsageBar(fraction: app.energyWh / total, tint: .green).frame(width: 120)
                                Text(String(format: "%.1f Wh", app.energyWh)).monospacedDigit().frame(width: 70, alignment: .trailing)
                            }
                            .font(.callout)
                        }
                    }
                }

                Card {
                    CardHeader(title: "Sleep and wake", systemImage: "moon.stars", tint: .indigo, trailing: loading ? "reading…" : "\(events.count) events")
                    if !loading && events.isEmpty { Text("No sleep or wake in this period.").foregroundStyle(.secondary) }
                    let wakes = events.filter { $0.kind != .sleep }
                    if !wakes.isEmpty {
                        let reasons = Dictionary(grouping: wakes) { SleepAnalyzer.explain($0.reason) }
                            .map { ($0.key, $0.value.count) }.sorted { $0.1 > $1.1 }.prefix(5)
                        Text("Most common reasons it woke up").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(Array(reasons), id: \.0) { reason, count in
                            HStack { Text(reason).lineLimit(1); Spacer(); Text("\(count)×").monospacedDigit().foregroundStyle(.secondary) }
                                .font(.callout)
                        }
                        Divider()
                    }
                    ForEach(events.prefix(40)) { event in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: event.kind == .sleep ? "moon.fill" : (event.kind == .darkWake ? "moon.haze" : "sun.max.fill"))
                                .foregroundStyle(event.kind == .sleep ? .indigo : .orange).frame(width: 18)
                            Text(event.date.formatted(date: .abbreviated, time: .shortened)).monospacedDigit().frame(width: 150, alignment: .leading)
                            Text(event.kind == .sleep ? "Sleep" : (event.kind == .darkWake ? "Woke briefly (screen off)" : "Woke up")).frame(width: 170, alignment: .leading)
                            Text(SleepAnalyzer.explain(event.reason)).foregroundStyle(.secondary).lineLimit(2)
                            Spacer()
                            if let battery = event.batteryPercent { Text("\(battery) %").monospacedDigit().foregroundStyle(.tertiary) }
                        }
                        .font(.callout)
                    }
                }
            }
            .padding(20)
        }
        .navigationTitle("Sleep & Battery Drain")
        .task(id: range) { await load() }
    }

    private func figure(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            BigNumber(text: value, size: 22)
        }
    }

    private func load() async {
        loading = true
        let store = services.history
        let since = Date().addingTimeInterval(-range)
        // pmset's log is large (several seconds to read), so everything runs off the main thread.
        let result = await Task.detached(priority: .userInitiated) {
            (SleepAnalyzer.blockers(), SleepAnalyzer.events(since: since).sorted { $0.date > $1.date },
             store.batteryDrain(since: since), store.topApps(from: since, to: Date(), onBatteryOnly: true).sorted { $0.energyWh > $1.energyWh })
        }.value
        blockers = result.0
        events = result.1
        drain = result.2
        drainApps = result.3
        loading = false
    }
}
