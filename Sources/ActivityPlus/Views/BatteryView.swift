import ActivityCore
import SwiftUI

struct BatteryView: View {
    @Environment(Monitor.self) private var monitor
    @Environment(AppServices.self) private var services

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
                            if b.isCharging {
                                StatLine(label: "Charging at", value: Format.watts(abs(b.batteryPower)))
                            } else if b.isPluggedIn {
                                StatLine(label: "Battery", value: "Resting, the adapter powers the Mac")
                            } else {
                                StatLine(label: "Battery output", value: Format.watts(abs(b.batteryPower)))
                            }
                        }
                        Card {
                            CardHeader(title: "Health", systemImage: "heart", tint: .pink)
                            BigNumber(text: b.health.map { Format.percent($0) } ?? "–", size: 36)
                            StatLine(label: "Charge cycles", value: "\(b.cycleCount)")
                            if let t = b.temperature { StatLine(label: "Temperature", value: Format.temperature(t, decimals: 1)) }
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
                }
                if !services.accessories.isEmpty {
                    Card {
                        CardHeader(title: "Accessories", systemImage: "airpods", tint: .blue)
                        ForEach(services.accessories) { device in
                            HStack {
                                Image(systemName: Self.accessorySymbol(device.kind)).frame(width: 22)
                                Text(device.name)
                                Spacer()
                                ForEach(device.levels, id: \.self) { level in
                                    Text((level.label.map { $0 + " " } ?? "") + "\(level.percent) %")
                                        .monospacedDigit()
                                        .foregroundStyle(level.percent <= 15 ? .red : .primary)
                                        .padding(.leading, 10)
                                }
                            }
                        }
                    }
                }
                if monitor.snapshot.battery == nil && services.accessories.isEmpty {
                    ContentUnavailableView("No battery", systemImage: "powerplug", description: Text("This Mac runs on mains power."))
                }
            }
            .padding(20)
        }
        .navigationTitle("Battery")
    }

    static func accessorySymbol(_ kind: String) -> String {
        switch kind.lowercased() {
        case let k where k.contains("head"): "airpods"
        case let k where k.contains("keyboard"): "keyboard"
        case let k where k.contains("trackpad"): "rectangle.and.hand.point.up.left"
        case let k where k.contains("mouse"): "computermouse"
        case let k where k.contains("game"): "gamecontroller"
        default: "dot.radiowaves.left.and.right"
        }
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
