import ActivityCore
import SwiftUI

/// When the fans sped up today and which apps were busiest in the minutes before.
struct FanSpinUpsCard: View {
    @Environment(Monitor.self) private var monitor
    @Environment(AppServices.self) private var services
    @State private var spinUps: [FanSpinUps.SpinUp] = []
    @State private var hasData = false
    @State private var loaded = false

    var body: some View {
        if monitor.snapshot.sensors.fans.isEmpty {
            EmptyView()
        } else {
            Card {
                CardHeader(title: "Fan spin-ups today", systemImage: "fan.badge.automatic", tint: .blue, trailing: loaded ? nil : "reading…")
                Text("When the fans sped up, and which apps were busiest in the ten minutes before. Heavy apps usually make a Mac warm; the fans follow a little later.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if loaded && spinUps.isEmpty {
                    if hasData {
                        Label("The fans stayed quiet today.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Text("Not enough data yet. Activity+ notes the fan speed once a minute while it runs.").foregroundStyle(.secondary)
                    }
                }
                ForEach(spinUps.reversed()) { spinUp in
                    Divider()
                    row(spinUp)
                }
            }
            .task {
                while !Task.isCancelled {
                    await load()
                    try? await Task.sleep(for: .seconds(60))
                }
            }
        }
    }

    private func row(_ spinUp: FanSpinUps.SpinUp) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(spinUp.start.formatted(date: .omitted, time: .shortened)).monospacedDigit().fontWeight(.semibold).frame(width: 56, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text("Up to \(Int(spinUp.peakRPM)) rpm for \(Format.duration(spinUp.end.timeIntervalSince(spinUp.start) + 60))").monospacedDigit()
                if spinUp.topApps.isEmpty {
                    Text("No single app stood out.").font(.callout).foregroundStyle(.secondary)
                } else {
                    Text("Busiest before: " + spinUp.topApps.map(describe).joined(separator: ", "))
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
        }
    }

    private func describe(_ app: FanSpinUps.Culprit) -> String {
        var text = "\(app.name) (\(Format.percent(app.cpu)) CPU"
        if app.gpu >= 5 { text += ", \(Format.percent(app.gpu)) GPU" }
        return text + ")"
    }

    private func load() async {
        let history = services.history
        let startOfDay = Calendar.current.startOfDay(for: Date())
        let result = await Task.detached(priority: .utility) {
            (history.fanSpinUps(since: startOfDay), !history.fanSeries(from: startOfDay, to: Date()).isEmpty)
        }.value
        spinUps = result.0
        hasData = result.1
        loaded = true
    }
}
