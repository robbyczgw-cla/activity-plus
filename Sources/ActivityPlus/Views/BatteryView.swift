import ActivityCore
import SwiftUI

struct BatteryView: View {
    @Environment(\.density) private var density
    @Environment(Monitor.self) private var monitor
    @Environment(AppServices.self) private var services

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: density.stack) {
                if let b = monitor.snapshot.battery {
                    BatteryHeroCard(battery: b)
                    HStack(alignment: .top, spacing: density.grid) {
                        PowerFlowCard(battery: b)
                        if b.isPluggedIn, b.adapterWatts != nil { ChargerCard(battery: b) }
                    }
                    if let session = monitor.chargeSession ?? monitor.lastChargeSession {
                        // A session that began when Activity+ launched started earlier in reality.
                        ChargeSessionCard(session: session, live: monitor.chargeSession != nil,
                                          sinceLaunch: session.start.timeIntervalSince(monitor.launchDate) < 10)
                    }
                    BatteryHealthCard(battery: b)
                    Card {
                        LiveChart(lines: [.init(name: "Power", values: monitor.history.power.values, color: .green)],
                                  format: Format.watts, interval: monitor.interval)
                            .frame(height: 160)
                    }
                    Card {
                        Text("Apps using the most energy").appFont(.headline)
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
            .padding(density.page)
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
        if b.isCharging { return String(localized: "Charging") }
        if b.isPluggedIn { return b.isFullyCharged ? "Charged" : String(localized: "Plugged in") }
        return String(localized: "On battery")
    }
}
