import Foundation

/// Human-readable numbers, matching how macOS itself prints them (decimal units: 1 GB = 10⁹ bytes
/// for disk and network, binary for memory like Activity Monitor).
public enum Format {
    public enum TemperatureUnit: String, Sendable, CaseIterable { case celsius, fahrenheit }

    /// User preferences, set once by the app at launch and when changed in Settings.
    nonisolated(unsafe) public static var temperatureUnit: TemperatureUnit = .celsius
    /// Show network speeds in bits (Mbit/s) like ISPs do, instead of bytes.
    nonisolated(unsafe) public static var networkInBits = false

    public static func temperature(_ celsius: Double, decimals: Int = 0, unit: Bool = true) -> String {
        let value = temperatureUnit == .celsius ? celsius : celsius * 9 / 5 + 32
        let symbol = temperatureUnit == .celsius ? "°C" : "°F"
        return String(format: "%.\(decimals)f", value) + (unit ? " \(symbol)" : "°")
    }

    /// Network throughput, in bits or bytes per the user's choice.
    public static func networkRate(_ bytesPerSecond: Double) -> String {
        guard networkInBits else { return rate(bytesPerSecond) }
        let units = ["bit/s", "kbit/s", "Mbit/s", "Gbit/s"]
        var value = max(0, bytesPerSecond * 8)
        var index = 0
        while value >= 1000, index < units.count - 1 { value /= 1000; index += 1 }
        let decimals = index == 0 || value >= 100 ? 0 : (value >= 10 ? 1 : 2)
        return String(format: "%.\(decimals)f %@", value, units[index])
    }

    public static func memory(_ bytes: UInt64) -> String {
        scaled(Double(bytes), base: 1024)
    }

    public static func storage(_ bytes: UInt64) -> String {
        scaled(Double(bytes), base: 1000)
    }

    public static func rate(_ bytesPerSecond: Double) -> String {
        scaled(bytesPerSecond, base: 1000) + "/s"
    }

    public static func percent(_ value: Double, decimals: Int = 0) -> String {
        String(format: "%.\(decimals)f%%", value)
    }

    public static func watts(_ value: Double) -> String {
        value < 10 ? String(format: "%.1f W", value) : String(format: "%.0f W", value)
    }

    public static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        let days = minutes / 1440
        let hours = (minutes % 1440) / 60
        let mins = minutes % 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(mins)m" }
        return "\(mins)m"
    }

    /// Splits "54.76 GB" into ("54.76", "GB") for big-number displays.
    public static func split(_ formatted: String) -> (value: String, unit: String) {
        let parts = formatted.split(separator: " ", maxSplits: 1)
        guard parts.count == 2 else { return (formatted, "") }
        return (String(parts[0]), String(parts[1]))
    }

    private static func scaled(_ value: Double, base: Double) -> String {
        let units = ["B", "kB", "MB", "GB", "TB"]
        var value = max(0, value)
        var index = 0
        while value >= base, index < units.count - 1 {
            value /= base
            index += 1
        }
        if index == 0 { return String(format: "%.0f %@", value, units[index]) }
        let decimals = value >= 100 ? 0 : (value >= 10 ? 1 : 2)
        return String(format: "%.\(decimals)f %@", value, units[index])
    }
}
