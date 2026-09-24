import Foundation
import IOKit

/// Battery levels of connected accessories: AirPods (left, right, case), Magic Mouse/Keyboard/Trackpad,
/// game controllers. Sources: Apple HID devices report `BatteryPercent` in the IORegistry; everything
/// else comes from `system_profiler SPBluetoothDataType -json` (~150 ms, so poll at most once a minute).
public struct DeviceBattery: Sendable, Identifiable, Hashable {
    public let name: String
    public let kind: String          // "Headphones", "Mouse", "Keyboard", …
    public let levels: [Level]
    public var id: String { name }

    public struct Level: Sendable, Hashable {
        public let label: String?    // nil for single-battery devices, else "Left", "Right", "Case"
        public let percent: Int
    }

    public var lowest: Int { levels.map(\.percent).min() ?? 0 }
}

public enum DeviceBatterySampler {
    public static func sample() -> [DeviceBattery] {
        var devices = bluetoothDevices()
        for hid in hidDevices() where !devices.contains(where: { $0.name == hid.name }) {
            devices.append(hid)
        }
        return devices.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func bluetoothDevices() -> [DeviceBattery] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPBluetoothDataType", "-json", "-detailLevel", "basic"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return parseBluetooth(data)
    }

    /// `SPBluetoothDataType[0].device_connected` is a list of one-key dictionaries: `[{ "AirPods Pro": {…} }]`.
    static func parseBluetooth(_ data: Data) -> [DeviceBattery] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sections = root["SPBluetoothDataType"] as? [[String: Any]]
        else { return [] }
        var result: [DeviceBattery] = []
        for section in sections {
            for entry in section["device_connected"] as? [[String: Any]] ?? [] {
                for (name, value) in entry {
                    guard let info = value as? [String: Any] else { continue }
                    let fields: [(String, String?)] = [
                        ("device_batteryLevelMain", nil), ("device_batteryLevel", nil),
                        ("device_batteryLevelLeft", "Left"), ("device_batteryLevelRight", "Right"),
                        ("device_batteryLevelCase", "Case"),
                    ]
                    let levels = fields.compactMap { key, label -> DeviceBattery.Level? in
                        guard let text = info[key] as? String, let percent = Int(text.trimmingCharacters(in: CharacterSet(charactersIn: "% "))) else { return nil }
                        return DeviceBattery.Level(label: label, percent: percent)
                    }
                    guard !levels.isEmpty else { continue }
                    result.append(DeviceBattery(name: name, kind: info["device_minorType"] as? String ?? "Accessory", levels: levels))
                }
            }
        }
        return result
    }

    static func hidDevices() -> [DeviceBattery] {
        var iterator: io_iterator_t = 0
        guard let matching = IOServiceMatching("IOHIDDevice") else { return [] }
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var result: [DeviceBattery] = []
        var service = IOIteratorNext(iterator)
        while service != 0 {
            if let percent = (IOKitProperty(service, "BatteryPercent") as? NSNumber)?.intValue,
               let name = IOKitProperty(service, "Product") as? String,
               !result.contains(where: { $0.name == name }) {
                let lower = name.lowercased()
                let kind = lower.contains("keyboard") ? "Keyboard" : lower.contains("trackpad") ? "Trackpad" : lower.contains("mouse") ? "Mouse" : "Accessory"
                result.append(DeviceBattery(name: name, kind: kind, levels: [.init(label: nil, percent: percent)]))
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        return result
    }
}
