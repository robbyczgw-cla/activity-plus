import ActivityCore
import Foundation
import SwiftUI

/// One user-defined item in the menu bar. Any number of them, each with its own module and look.
struct MenuBarItemConfig: Codable, Identifiable, Hashable {
    enum Module: String, Codable, CaseIterable, Identifiable {
        case status, cpu, memory, gpu, disk, network, temperature, fans, battery, power, clock
        var id: String { rawValue }
        var title: String {
            switch self {
            case .status: String(localized: "Activity+ icon")
            case .cpu: String(localized: "CPU")
            case .memory: String(localized: "Memory")
            case .gpu: String(localized: "GPU")
            case .disk: String(localized: "Disk")
            case .network: String(localized: "Network")
            case .temperature: String(localized: "Temperature")
            case .fans: String(localized: "Fans")
            case .battery: String(localized: "Battery")
            case .power: String(localized: "Power draw")
            case .clock: String(localized: "Clock")
            }
        }
        var shortLabel: String {
            switch self {
            case .status: ""
            case .cpu: String(localized: "CPU")
            case .memory: String(localized: "MEM")
            case .gpu: String(localized: "GPU")
            case .disk: String(localized: "SSD")
            case .network: String(localized: "NET")
            case .temperature: String(localized: "TMP")
            case .fans: String(localized: "FAN")
            case .battery: String(localized: "BAT")
            case .power: String(localized: "PWR")
            case .clock: ""
            }
        }
        var systemImage: String {
            switch self {
            case .status: "waveform.path.ecg"
            case .cpu: "cpu"
            case .memory: "memorychip"
            case .gpu: "square.stack.3d.up"
            case .disk: "internaldrive"
            case .network: "network"
            case .temperature: "thermometer.medium"
            case .fans: "fan"
            case .battery: "battery.75percent"
            case .power: "bolt"
            case .clock: "clock"
            }
        }
        /// Which looks make sense for this module.
        var styles: [Style] {
            switch self {
            case .status: [.icon]
            case .cpu: [.text, .labeled, .line, .bars, .coreBars, .ring, .gauge, .dot, .icon]
            case .memory, .gpu, .disk: [.text, .labeled, .line, .bars, .ring, .gauge, .dot, .icon]
            case .network: [.speed, .text, .labeled, .line, .bars, .dot, .icon]
            case .temperature, .power: [.text, .labeled, .line, .bars, .gauge, .dot, .icon]
            case .fans: [.text, .labeled, .gauge, .dot, .icon]
            case .battery: [.battery, .text, .labeled, .ring, .line, .dot, .icon]
            case .clock: [.text, .labeled]
            }
        }
        /// The panel tab a click opens.
        var panelTab: MenuBarPanel.Tab {
            switch self {
            case .cpu, .temperature, .fans: .cpu
            case .memory: .memory
            case .gpu: .gpu
            case .disk: .disk
            case .network: .network
            case .battery, .power: .battery
            case .status, .clock: .overview
            }
        }
    }

    enum Style: String, Codable, CaseIterable, Identifiable {
        case icon, text, labeled, line, bars, coreBars, ring, gauge, dot, speed, battery
        var id: String { rawValue }
        var title: String {
            switch self {
            case .icon: String(localized: "Icon")
            case .text: String(localized: "Value")
            case .labeled: String(localized: "Label + value")
            case .line: String(localized: "Line chart")
            case .bars: String(localized: "Bar chart")
            case .coreBars: String(localized: "Bar per core")
            case .ring: String(localized: "Ring")
            case .gauge: String(localized: "Gauge")
            case .dot: String(localized: "Dot")
            case .speed: String(localized: "Up / down")
            case .battery: String(localized: "Battery")
            }
        }
    }

    enum ColorMode: String, Codable, CaseIterable, Identifiable {
        case monochrome, byLevel, fixed
        var id: String { rawValue }
        var title: String {
            switch self {
            case .monochrome: String(localized: "Match the menu bar")
            case .byLevel: String(localized: "Green → red by load")
            case .fixed: String(localized: "Fixed color")
            }
        }
    }

    enum MemoryFigure: String, Codable, CaseIterable, Identifiable {
        case percent, used, free, pressure
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }

    enum DiskFigure: String, Codable, CaseIterable, Identifiable {
        case free, usedPercent, activity
        var id: String { rawValue }
        var title: String {
            switch self {
            case .free: String(localized: "Free space")
            case .usedPercent: String(localized: "Used %")
            case .activity: String(localized: "Read + write")
            }
        }
    }

    var id = UUID()
    var module: Module
    var style: Style
    var showLabel = false
    var customLabel = ""
    var colorMode: ColorMode = .monochrome
    var fixedColor = "#4F8CFF"
    var memoryFigure: MemoryFigure = .percent
    var diskFigure: DiskFigure = .free
    var showDecimals = false
    /// Clock: time zone identifiers; empty = local time only.
    var timeZones: [String] = []
    var clockShowsSeconds = false
    /// Hide the item while the value is below this (e.g. show CPU only when busy). 0 = always.
    var hideBelowPercent: Double = 0
    /// A small symbol (cpu, memory chip, thermometer…) in front of the value.
    var showIcon = false
    /// Battery: while charging or discharging, show watts ("+18 W") instead of the percentage.
    var batteryShowsPower = false

    init(module: Module, style: Style) {
        self.module = module
        self.style = style
    }

    var label: String { customLabel.isEmpty ? module.shortLabel : customLabel }

    static let defaults: [MenuBarItemConfig] = [MenuBarItemConfig(module: .cpu, style: .text)]

    // Decode leniently so settings from older versions never lose the whole list.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        module = (try? c.decode(Module.self, forKey: .module)) ?? .cpu
        style = (try? c.decode(Style.self, forKey: .style)) ?? .text
        showLabel = (try? c.decode(Bool.self, forKey: .showLabel)) ?? false
        customLabel = (try? c.decode(String.self, forKey: .customLabel)) ?? ""
        colorMode = (try? c.decode(ColorMode.self, forKey: .colorMode)) ?? .monochrome
        fixedColor = (try? c.decode(String.self, forKey: .fixedColor)) ?? "#4F8CFF"
        memoryFigure = (try? c.decode(MemoryFigure.self, forKey: .memoryFigure)) ?? .percent
        diskFigure = (try? c.decode(DiskFigure.self, forKey: .diskFigure)) ?? .free
        showDecimals = (try? c.decode(Bool.self, forKey: .showDecimals)) ?? false
        timeZones = (try? c.decode([String].self, forKey: .timeZones)) ?? []
        clockShowsSeconds = (try? c.decode(Bool.self, forKey: .clockShowsSeconds)) ?? false
        hideBelowPercent = (try? c.decode(Double.self, forKey: .hideBelowPercent)) ?? 0
        showIcon = (try? c.decode(Bool.self, forKey: .showIcon)) ?? false
        batteryShowsPower = (try? c.decode(Bool.self, forKey: .batteryShowsPower)) ?? false
    }

    /// A good first look when a module is switched on from the quick menu.
    static func quick(_ module: Module) -> MenuBarItemConfig {
        var item: MenuBarItemConfig
        switch module {
        case .network: item = MenuBarItemConfig(module: .network, style: .speed)
        case .battery: item = MenuBarItemConfig(module: .battery, style: .battery); item.showLabel = true
        case .status: item = MenuBarItemConfig(module: .status, style: .icon)
        case .clock: item = MenuBarItemConfig(module: .clock, style: .text)
        case .disk: item = MenuBarItemConfig(module: .disk, style: .text); item.showIcon = true
        default: item = MenuBarItemConfig(module: module, style: .text); item.showIcon = true
        }
        return item
    }

    /// Ready-made menu bars for the quick menu.
    enum Preset: String, CaseIterable, Identifiable {
        case minimal, balanced, everything, iconOnly
        var id: String { rawValue }
        var title: String {
            switch self {
            case .minimal: String(localized: "Minimal (CPU)")
            case .balanced: String(localized: "Balanced (CPU, memory, network, temperature)")
            case .everything: String(localized: "Everything")
            case .iconOnly: String(localized: "Just the Activity+ icon")
            }
        }
        var items: [MenuBarItemConfig] {
            switch self {
            case .minimal:
                return [MenuBarItemConfig.quick(.cpu)]
            case .balanced:
                var cpu = MenuBarItemConfig(module: .cpu, style: .ring)
                cpu.showLabel = true
                cpu.colorMode = .byLevel
                return [cpu, MenuBarItemConfig.quick(.memory), MenuBarItemConfig.quick(.network), MenuBarItemConfig.quick(.temperature)]
            case .everything:
                let modules: [Module] = [.cpu, .memory, .gpu, .network, .disk, .temperature, .battery, .clock]
                return modules.map(MenuBarItemConfig.quick)
            case .iconOnly:
                return [MenuBarItemConfig.quick(.status)]
            }
        }
    }
}

/// The list of items, stored in UserDefaults as JSON.
enum MenuBarItemStore {
    static let key = "menuBarItems"

    static func load() -> [MenuBarItemConfig] {
        if let data = UserDefaults.standard.data(forKey: key),
           let items = try? JSONDecoder().decode([MenuBarItemConfig].self, from: data) {
            return items
        }
        // Persist the first result so item IDs (and with them the menu bar positions macOS remembers) stay stable.
        let migrated = migrateFromSingleItem()
        if let data = try? JSONEncoder().encode(migrated) { UserDefaults.standard.set(data, forKey: key) }
        return migrated
    }

    static func save(_ items: [MenuBarItemConfig]) {
        if let data = try? JSONEncoder().encode(items) { UserDefaults.standard.set(data, forKey: key) }
        NotificationCenter.default.post(name: changed, object: nil)
    }

    static let changed = Notification.Name("ActivityPlusMenuBarItemsChanged")

    /// v0.1 had one item configured by "menuBarStyle" / "menuBarFigure"; keep what the user picked.
    private static func migrateFromSingleItem() -> [MenuBarItemConfig] {
        let defaults = UserDefaults.standard
        guard let style = defaults.string(forKey: "menuBarStyle") else { return MenuBarItemConfig.defaults }
        let figure = defaults.string(forKey: "menuBarFigure") ?? "cpu"
        let module: MenuBarItemConfig.Module = switch figure {
        case "memory": .memory
        case "gpu": .gpu
        case "network": .network
        case "temperature": .temperature
        case "battery": .battery
        default: .cpu
        }
        switch style {
        case "icon": return [MenuBarItemConfig(module: .status, style: .icon)]
        case "graph": return [MenuBarItemConfig(module: module, style: .line)]
        case "stacked":
            var first = MenuBarItemConfig(module: .cpu, style: .labeled)
            first.showLabel = true
            var second = MenuBarItemConfig(module: .memory, style: .labeled)
            second.showLabel = true
            return [first, second]
        default: return [MenuBarItemConfig(module: module, style: .text)]
        }
    }
}

extension Color {
    init(hex: String) {
        var value: UInt64 = 0
        Scanner(string: hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))).scanHexInt64(&value)
        self.init(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }

    var hexString: String {
        let color = NSColor(self).usingColorSpace(.sRGB) ?? .systemBlue
        return String(format: "#%02X%02X%02X", Int(color.redComponent * 255), Int(color.greenComponent * 255), Int(color.blueComponent * 255))
    }
}
