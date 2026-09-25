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
                                  format: { Format.temperature($0, unit: false) }, maxValue: 110, interval: monitor.interval)
                            .frame(height: 160)
                    }
                }
                SensorListCard(readings: monitor.snapshot.sensorList)
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
        .onAppear { monitor.sensorListWanted = true }
        .onDisappear { monitor.sensorListWanted = false }
    }

    private func temperatureCard(_ title: String, _ value: Double, _ symbol: String) -> some View {
        Card {
            CardHeader(title: title, systemImage: symbol, tint: Self.color(for: value))
            BigNumber(text: Format.temperature(value), size: 32)
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

/// Every sensor the Mac reports, grouped, with a kind filter and search.
struct SensorListCard: View {
    let readings: [SensorReading]
    @State private var kind: SensorReading.Kind? = nil
    @State private var search = ""
    @AppStorage("sensorListShowRawKeys") private var showRaw = false

    var body: some View {
        Card {
            HStack {
                CardHeader(title: "All sensors", systemImage: "list.bullet.rectangle", tint: .secondary,
                           trailing: readings.isEmpty ? "reading…" : "\(filtered.count) of \(readings.count)")
            }
            HStack {
                Picker("", selection: $kind) {
                    Text("All").tag(SensorReading.Kind?.none)
                    ForEach(SensorReading.Kind.allCases, id: \.self) { Text($0.rawValue.capitalized).tag(Optional($0)) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 420)
                TextField("Search", text: $search).textFieldStyle(.roundedBorder).frame(width: 160)
                Toggle("Unnamed", isOn: $showRaw).toggleStyle(.checkbox).help("Also show SMC keys without a known name")
            }
            let groups = Dictionary(grouping: filtered, by: \.group).sorted { $0.key < $1.key }
            ForEach(groups, id: \.key) { group, items in
                Text(group).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 4)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 8)], spacing: 4) {
                    ForEach(items.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) { reading in
                        HStack {
                            Text(reading.name).lineLimit(1).help(reading.id)
                            Spacer()
                            Text(format(reading)).monospacedDigit().foregroundStyle(.secondary)
                        }
                        .font(.callout)
                    }
                }
            }
        }
    }

    private var filtered: [SensorReading] {
        readings.filter { reading in
            (kind == nil || reading.kind == kind)
                && (showRaw || reading.name != reading.id)
                && (search.isEmpty || reading.name.localizedCaseInsensitiveContains(search) || reading.id.localizedCaseInsensitiveContains(search))
        }
    }

    private func format(_ reading: SensorReading) -> String {
        switch reading.kind {
        case .temperature: Format.temperature(reading.value, decimals: 1)
        case .voltage: String(format: "%.3f V", reading.value)
        case .current: String(format: "%.3f A", reading.value)
        case .power: String(format: "%.2f W", reading.value)
        case .fan: "\(Int(reading.value)) rpm"
        }
    }
}
