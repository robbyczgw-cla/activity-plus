import ActivityCore
import SwiftUI

struct BatteryView: View {
    @Environment(Monitor.self) private var monitor

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let b = monitor.snapshot.battery {
                    HStack(alignment: .top, spacing: 14) {
                        Card {
                            CardHeader(title: "Battery", systemImage: Self.symbol(for: b), tint: .green, trailing: Self.stateText(b))
                            BigNumber(text: Format.percent(b.percent), size: 36)
                            UsageBar(fraction: b.percent / 100, tint: b.percent < 20 ? .red : .green)
                            StatLine(label: "Time remaining", value: b.timeRemaining.map(Format.duration) ?? (b.isPluggedIn ? "Plugged in" : "Calculating…"))
                            StatLine(label: "Mac power draw", value: b.systemPower.map(Format.watts) ?? "–")
                            StatLine(label: b.batteryPower >= 0 ? "Charging at" : "Battery output", value: Format.watts(abs(b.batteryPower)))
                        }
                        Card {
                            CardHeader(title: "Health", systemImage: "heart", tint: .pink)
                            BigNumber(text: b.health.map { Format.percent($0) } ?? "–", size: 36)
                            StatLine(label: "Charge cycles", value: "\(b.cycleCount)")
                            if let t = b.temperature { StatLine(label: "Temperature", value: String(format: "%.1f °C", t)) }
                            Text("Health is the current full-charge capacity compared with the battery's design capacity.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Card {
                        LiveChart(lines: [.init(name: "Power", values: monitor.history.power.values, color: .green)],
                                  format: Format.watts, interval: monitor.interval)
                            .frame(height: 160)
                    }
                    Card {
                        Text("Apps using the most energy").font(.headline)
                        AppListView(metric: .energy, limit: 15)
                    }
                } else {
                    ContentUnavailableView("No battery", systemImage: "powerplug", description: Text("This Mac runs on mains power."))
                }
            }
            .padding(20)
        }
        .navigationTitle("Battery")
    }

    static func symbol(for b: BatteryStats) -> String {
        if b.isCharging { return "battery.100percent.bolt" }
        switch b.percent {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    static func stateText(_ b: BatteryStats) -> String {
        if b.isCharging { return "Charging" }
        if b.isPluggedIn { return b.isFullyCharged ? "Charged" : "Plugged in" }
        return "On battery"
    }
}
