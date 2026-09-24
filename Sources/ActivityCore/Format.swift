import Foundation

/// Human-readable numbers, matching how macOS itself prints them (decimal units: 1 GB = 10⁹ bytes
/// for disk and network, binary for memory like Activity Monitor).
public enum Format {
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
