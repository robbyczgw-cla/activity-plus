import Foundation

public extension ChargeHold {
    /// One line for lists, the CLI and AI agents.
    var summary: String {
        switch self {
        case .full: String(localized: "Charged")
        case .optimized: String(localized: "Holding at 80 % (Optimized Charging)")
        case .chargeLimit(let percent): String(localized: "Holding at the \(percent) % charge limit")
        case .temperature: String(localized: "Not charging: battery temperature")
        case .adapterTooWeak: String(localized: "Adapter too weak for the current load")
        case .other(let code): String(localized: "Charging paused by the battery controller (reason \(code))")
        }
    }
}

public extension BatteryStats {
    /// Charging detail for `aplus --json` and the MCP server; nil values become JSON null.
    var details: [String: Any] {
        func value(_ v: Any?) -> Any { v ?? NSNull() }
        func round(_ v: Double?, _ places: Double = 10) -> Any { v.map { ($0 * places).rounded() / places } ?? NSNull() }
        return [
            "percent": percent, "charging": isCharging, "plugged_in": isPluggedIn, "fully_charged": isFullyCharged,
            "battery_watts": round(batteryPower), "system_watts": round(systemPower),
            "adapter_input_watts": round(adapterInputPower), "adapter_loss_watts": round(adapterLoss),
            "percent_per_hour": round(chargeRate),
            "time_to_full_seconds": value(timeToFull.map { Int($0) }),
            "time_remaining_seconds": value(timeRemaining.map { Int($0) }),
            "adapter": isPluggedIn ? [
                "rated_watts": value(adapterWatts), "name": value(adapterName),
                "volts": round(adapterVoltage), "amps": round(adapterCurrent, 100),
                "port": value(adapterPort), "wireless": adapterIsWireless,
                "profiles": adapterProfiles.map { ["volts": $0.volts, "amps": $0.amps, "watts": ($0.watts).rounded()] },
            ] as [String: Any] : NSNull(),
            "hold": value(hold?.summary),
            "health_percent": round(health), "cycles": cycleCount, "rated_cycles": value(designCycleCount),
            "capacity_mah": ["design": value(designCapacity), "full": value(fullChargeCapacity), "now": value(remainingCapacity)],
            "temperature": round(temperature), "volts": round(voltage, 100), "milliamps": amperage.rounded(),
            "thermally_limited_seconds": thermallyLimitedSeconds,
            "formatted": Format.percent(percent),
        ]
    }
}
