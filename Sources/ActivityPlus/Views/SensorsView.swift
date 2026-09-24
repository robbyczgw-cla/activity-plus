import ActivityCore
import SwiftUI

struct SensorsView: View {
    @Environment(Monitor.self) private var monitor

    var body: some View {
        let sensors = monitor.snapshot.sensors
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 14)], spacing: 14) {
                    if let t = sensors.cpuTemperature { temperatureCard("CPU", t, "cpu") }
                    if let t = sensors.gpuTemperature { temperatureCard("GPU", t, "square.stack.3d.up") }
                    if let t = sensors.batteryTemperature { temperatureCard("Battery", t, "battery.75percent") }
                    Card {
                        CardHeader(title: "Thermal state", systemImage: "thermometer.medium", tint: .orange)
                        BigNumber(text: monitor.snapshot.thermal.rawValue, size: 26)
                        Text(monitor.snapshot.thermal == .nominal ? "macOS is not slowing anything down." : "macOS is reducing performance to cool down.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if monitor.history.cpuTemperature.values.count > 2 {
                    Card {
                        CardHeader(title: "CPU temperature", systemImage: "chart.xyaxis.line", tint: .red)
                        LiveChart(lines: [.init(name: "CPU", values: monitor.history.cpuTemperature.values, color: .red)],
                                  format: { String(format: "%.0f°", $0) }, maxValue: 110, interval: monitor.interval)
                            .frame(height: 160)
                    }
                }
                Card {
                    CardHeader(title: "Fans", systemImage: "fan", tint: .blue)
                    if sensors.fans.isEmpty {
                        Text("This Mac has no fans, or does not report them.").foregroundStyle(.secondary)
                    }
                    ForEach(sensors.fans, id: \.name) { fan in
                        HStack {
                            Image(systemName: "fan").symbolEffect(.rotate, isActive: fan.rpm > 0)
                            Text(fan.name)
                            Spacer()
                            if let max = fan.maxRPM, max > 0 {
                                UsageBar(fraction: (fan.rpm - (fan.minRPM ?? 0)) / (max - (fan.minRPM ?? 0)), tint: .blue).frame(width: 140)
                            }
                            Text("\(Int(fan.rpm)) rpm").monospacedDigit().frame(width: 90, alignment: .trailing)
                        }
                    }
                }
            }
            .padding(20)
        }
        .navigationTitle("Temperatures")
    }

    private func temperatureCard(_ title: String, _ value: Double, _ symbol: String) -> some View {
        Card {
            CardHeader(title: title, systemImage: symbol, tint: Self.color(for: value))
            BigNumber(text: String(format: "%.0f °C", value), size: 32)
            UsageBar(fraction: value / 105, tint: Self.color(for: value))
        }
    }

    static func color(for celsius: Double) -> Color {
        switch celsius {
        case ..<60: .green
        case ..<80: .orange
        default: .red
        }
    }
}
