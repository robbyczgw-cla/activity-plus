import ActivityCore
import Charts
import SwiftUI

// Charging detail for the Battery page: where the power goes, what the adapter
// negotiated, what the battery holds, and how the current charge is going.

/// "Charging at 20 W · full in 1 h 43 min · +31 %/h", or why it is not charging.
struct BatteryHeroCard: View {
    let battery: BatteryStats

    var body: some View {
        Card {
            CardHeader(title: "Battery", systemImage: BatteryView.symbol(for: battery), tint: tint, trailing: BatteryView.stateText(battery))
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                BigNumber(text: Format.percent(battery.percent), size: 40)
                if let rate = battery.chargeRate, abs(rate) >= 0.5 {
                    Text(String(format: "%+.0f %%/h", rate))
                        .appFont(.title3, weight: .semibold).monospacedDigit()
                        .foregroundStyle(rate > 0 ? .green : .secondary)
                }
                Spacer()
            }
            UsageBar(fraction: battery.percent / 100, tint: battery.percent < 20 ? .red : .green)
            Text(headline).appFont(.callout, weight: .medium)
            if let hold = battery.hold {
                Label(BatteryText.explanation(hold), systemImage: BatteryText.symbol(hold))
                    .appFont(.caption).foregroundStyle(hold == .adapterTooWeak ? .orange : .secondary)
            } else if let slow = battery.slowCharging {
                Label(BatteryText.explanation(slow), systemImage: "tortoise")
                    .appFont(.caption).foregroundStyle(.secondary)
            } else if let note = BatteryText.loadNote(battery) {
                Label(note, systemImage: "tortoise")
                    .appFont(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var tint: Color { battery.isCharging ? .green : battery.drainsWhilePluggedIn ? .orange : .green }

    private var headline: String {
        let b = battery
        if b.drainsWhilePluggedIn { return "Losing \(Format.watts(abs(b.batteryPower))) although plugged in" }
        if b.isCharging {
            var parts = ["Charging at \(Format.watts(abs(b.batteryPower)))"]
            if let t = b.timeToFull, t > 0 { parts.append("full in \(Format.duration(t))") }
            return parts.joined(separator: " · ")
        }
        if b.isPluggedIn, let hold = b.hold { return BatteryText.title(hold) }
        if b.isPluggedIn { return String(localized: "Plugged in, the adapter powers the Mac") }
        var parts = [String(localized: "Supplying \(Format.watts(abs(b.batteryPower)))")]
        if let t = b.timeRemaining { parts.append(String(localized: "\(Format.duration(t)) left")) }
        return parts.joined(separator: " · ")
    }
}

/// Adapter -> Mac + Battery, with the conversion loss; on battery: Battery -> Mac.
struct PowerFlowCard: View {
    let battery: BatteryStats

    var body: some View {
        Card {
            CardHeader(title: "Power flow", systemImage: "arrow.triangle.branch", tint: .yellow)
            HStack(spacing: 0) {
                if battery.isPluggedIn {
                    node("Adapter", watts: battery.adapterInputPower, symbol: "powerplug.fill", tint: .yellow,
                         note: battery.adapterWatts.map { "\($0) W rated" })
                    arrow
                    VStack(spacing: 10) {
                        node("Mac", watts: battery.systemPower, symbol: "laptopcomputer", tint: .blue, note: String(localized: "system load"))
                        node(batteryLabel, watts: abs(battery.batteryPower), symbol: "battery.100percent.bolt",
                             tint: battery.batteryPower >= 0 ? .green : .orange, note: batteryNote)
                    }
                } else {
                    node("Battery", watts: abs(battery.batteryPower), symbol: BatteryView.symbol(for: battery), tint: .green, note: Format.percent(battery.percent))
                    arrow
                    node("Mac", watts: battery.systemPower ?? abs(battery.batteryPower), symbol: "laptopcomputer", tint: .blue, note: String(localized: "system load"))
                }
            }
            if let loss = battery.adapterLoss, loss > 0.05, battery.isPluggedIn {
                Text("\(Format.watts(loss)) turn into heat converting the adapter's voltage.")
                    .appFont(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var batteryLabel: String { battery.batteryPower >= 0 ? "Battery" : String(localized: "Battery (helping)") }
    private var batteryNote: String {
        if battery.batteryPower > 0.5 { return "charging" }
        if battery.batteryPower < -0.5 { return String(localized: "adapter too weak") }
        return "resting"
    }

    private var arrow: some View {
        Image(systemName: "arrow.right")
            .appFont(.title3, weight: .semibold).foregroundStyle(.tertiary)
            .frame(width: 36)
    }

    private func node(_ title: String, watts: Double?, symbol: String, tint: Color, note: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(LocalizedStringKey(title), systemImage: symbol).appFont(.caption, weight: .semibold).foregroundStyle(tint)
            BigNumber(text: watts.map(Format.watts) ?? "–", size: 22)
            if let note { Text(note).appFont(.caption2).foregroundStyle(.secondary) }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// What the adapter is and what it agreed to deliver.
struct ChargerCard: View {
    let battery: BatteryStats

    var body: some View {
        Card {
            CardHeader(title: "Power adapter", systemImage: battery.adapterIsWireless ? "wave.3.right" : "powerplug",
                       tint: .yellow, trailing: battery.adapterPort.map { "Port \($0)" })
            BigNumber(text: battery.adapterWatts.map { "\($0) W" } ?? "–", size: 30)
            if let name = battery.adapterName, !name.isEmpty {
                StatLine(label: "Type", value: BatteryText.adapterName(name))
            }
            if let v = battery.adapterVoltage, let a = battery.adapterCurrent {
                StatLine(label: "Negotiated", value: String(format: "%.0f V × %.2f A = %.0f W", v, a, v * a))
            }
            if let input = battery.adapterInputPower {
                StatLine(label: "Drawing now", value: Format.watts(input))
            }
            if !battery.adapterProfiles.isEmpty {
                Text("Offers").appFont(.caption).foregroundStyle(.secondary)
                FlowChips(profiles: battery.adapterProfiles, active: battery.adapterVoltage)
            }
            if battery.thermallyLimitedSeconds > 0 {
                StatLine(label: "Slowed by heat", value: Format.duration(TimeInterval(battery.thermallyLimitedSeconds)))
            }
        }
    }
}

private struct FlowChips: View {
    let profiles: [PowerProfile]
    let active: Double?

    var body: some View {
        HStack(spacing: 6) {
            ForEach(profiles, id: \.self) { p in
                let on = active.map { abs($0 - p.volts) < 0.5 } ?? false
                Text(String(format: "%.0f V · %.0f W", p.volts, p.watts))
                    .appFont(.caption, monospacedDigit: true)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(on ? Color.yellow.opacity(0.25) : Color.secondary.opacity(0.12), in: Capsule())
                    .fontWeight(on ? .semibold : .regular)
            }
        }
    }
}

/// Health, capacity in mAh, cycles against the rating, temperature, voltage and current.
struct BatteryHealthCard: View {
    let battery: BatteryStats

    var body: some View {
        Card {
            CardHeader(title: "Health", systemImage: "heart", tint: .pink)
            BigNumber(text: battery.health.map { Format.percent($0) } ?? "–", size: 30)
            if let design = battery.designCapacity, let full = battery.fullChargeCapacity, design > 0 {
                CapacityBar(design: design, full: full, remaining: battery.remainingCapacity)
                    .frame(height: 12)
                HStack {
                    legend("Now", battery.remainingCapacity, .green)
                    legend(String(localized: "Full"), full, .green.opacity(0.4))
                    legend(String(localized: "New"), design, .secondary.opacity(0.3))
                }
            }
            if let rated = battery.designCycleCount, rated > 0 {
                StatLine(label: "Charge cycles", value: String(localized: "\(battery.cycleCount) of \(rated.formatted()) rated"))
                UsageBar(fraction: Double(battery.cycleCount) / Double(rated), tint: .pink)
            } else {
                StatLine(label: "Charge cycles", value: "\(battery.cycleCount)")
            }
            if let t = battery.temperature { StatLine(label: "Temperature", value: Format.temperature(t, decimals: 1)) }
            if battery.voltage > 0 {
                StatLine(label: "Voltage · current", value: String(format: String(localized: "%.2f V · %+.0f mA"), battery.voltage, battery.amperage))
            }
            Text("Health is what a full charge holds today compared with the battery when new.")
                .appFont(.caption).foregroundStyle(.secondary)
        }
    }

    private func legend(_ label: String, _ mAh: Int?, _ color: Color) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 6)
            Text(LocalizedStringKey(label)).foregroundStyle(.secondary)
            Text(mAh.map { "\($0.formatted()) mAh" } ?? "–").monospacedDigit()
        }
        .appFont(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Three nested bars: capacity when new, what a full charge holds, what is in it now.
private struct CapacityBar: View {
    let design: Int
    let full: Int
    let remaining: Int?

    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            let scale = Double(max(design, full, 1))
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.18))
                Capsule().fill(Color.green.opacity(0.35)).frame(width: w * Double(full) / scale)
                if let remaining {
                    Capsule().fill(Color.green.gradient).frame(width: max(2, w * Double(remaining) / scale))
                }
            }
        }
    }
}

/// The charge in progress (or the last one): gain, energy, speed, and its curve.
struct ChargeSessionCard: View {
    let session: ChargeSession
    let live: Bool
    var sinceLaunch = false

    var body: some View {
        Card {
            CardHeader(title: live ? "This charge" : "Last charge", systemImage: "bolt.fill", tint: .green,
                       trailing: (sinceLaunch ? "measured since Activity+ started, " : "since ")
                        + session.start.formatted(date: .omitted, time: .shortened))
            HStack(spacing: 18) {
                figure(String(localized: "Gained"), String(format: "%+.0f %%", session.gainedPercent))
                figure("Energy", String(format: String(localized: "%.1f Wh"), session.energyWh))
                figure("Average", Format.watts(session.averageWatts))
                figure("Peak", Format.watts(session.peakWatts))
            }
            if session.points.count > 1 {
                Chart {
                    ForEach(session.points, id: \.date) { p in
                        AreaMark(x: .value("Time", p.date), y: .value("Watts", max(0, p.watts)))
                            .foregroundStyle(Color.yellow.opacity(0.25).gradient)
                            .interpolationMethod(.monotone)
                    }
                    ForEach(session.points, id: \.date) { p in
                        // Percent drawn on the watts scale: 100 % = the chart's top.
                        LineMark(x: .value("Time", p.date), y: .value("Percent", p.percent / 100 * wattsTop))
                            .foregroundStyle(.green)
                            .lineStyle(StrokeStyle(lineWidth: 2))
                            .interpolationMethod(.monotone)
                    }
                }
                .chartYScale(domain: 0...wattsTop)
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine()
                        AxisValueLabel { if let w = value.as(Double.self) { Text("\(Int(w)) W") } }
                    }
                    AxisMarks(position: .trailing, values: [0, wattsTop / 2, wattsTop]) { value in
                        AxisValueLabel { if let w = value.as(Double.self) { Text("\(Int((w / wattsTop * 100).rounded())) %") } }
                    }
                }
                .frame(height: 150)
                HStack(spacing: 14) {
                    Label("Charge", systemImage: "circle.fill").foregroundStyle(.green)
                    Label("Watts into the battery", systemImage: "square.fill").foregroundStyle(.yellow)
                }
                .appFont(.caption).labelStyle(.titleAndIcon)
            }
        }
    }

    private var wattsTop: Double { max(10, ((session.points.map(\.watts).max() ?? 10) / 10).rounded(.up) * 10) }

    private func figure(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(LocalizedStringKey(label)).appFont(.caption).foregroundStyle(.secondary)
            Text(value).appFont(.title3, weight: .semibold).monospacedDigit()
        }
    }
}

/// Plain-language texts for hold and slow-charging reasons.
enum BatteryText {
    static func title(_ hold: ChargeHold) -> String { hold.summary }

    static func explanation(_ hold: ChargeHold) -> String {
        switch hold {
        case .full: String(localized: "The battery is full; the adapter powers the Mac directly.")
        case .optimized: String(localized: "macOS learned when you usually unplug and finishes charging shortly before. This keeps the battery healthier.")
        case .chargeLimit(let p): String(localized: "You set a charge limit of \(p) % in Battery settings. Staying below full slows battery ageing.")
        case .temperature: String(localized: "Charging pauses while the battery is too hot or too cold, and resumes on its own.")
        case .adapterTooWeak: String(localized: "The Mac needs more than the adapter delivers, so the battery makes up the rest. A stronger adapter or fewer heavy apps help.")
        case .other(let code): String(localized: "The battery controller paused charging (reason \(code)).")
        }
    }

    static func symbol(_ hold: ChargeHold) -> String {
        switch hold {
        case .full: "checkmark.circle"
        case .optimized, .chargeLimit: "leaf"
        case .temperature: "thermometer.medium"
        case .adapterTooWeak: "exclamationmark.triangle.fill"
        case .other: "pause.circle"
        }
    }

    static func explanation(_ slow: SlowCharging) -> String {
        switch slow {
        case .temperature: String(localized: "Charging is slowed to keep the battery cool.")
        case .adapterLimited: String(localized: "The adapter or cable limits the charging speed.")
        case .nearFull: String(localized: "Above about 80 % the battery takes charge more slowly by design.")
        case .other(let code): String(localized: "The battery controller is charging slowly (reason \(code)).")
        }
    }

    /// The most common reason for slow charging needs no controller code: the Mac
    /// itself takes most of what the adapter delivers.
    static func loadNote(_ b: BatteryStats) -> String? {
        guard b.isCharging, let input = b.adapterInputPower, let load = b.systemPower, input > 5,
              load / input > 0.6 else { return nil }
        return "Charging slowly: the Mac itself uses \(Format.watts(load)) of the \(Format.watts(input)) the adapter delivers."
    }

    /// IOKit names USB-C adapters "pd charger"; say what that means.
    static func adapterName(_ raw: String) -> String {
        switch raw.lowercased() {
        case "pd charger": String(localized: "USB-C Power Delivery")
        default: raw
        }
    }
}
