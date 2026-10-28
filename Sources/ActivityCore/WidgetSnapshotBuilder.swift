import Foundation
import WidgetData

extension WidgetSnapshot {
    /// The widget's view of one sample, formatted with the app's current units and locale.
    /// `icon` supplies a small PNG per app (the app layer has AppKit; ActivityCore does not).
    public init(_ s: SystemSnapshot, icon: (AppGroup) -> Data? = { _ in nil }) {
        let memoryUsed = s.memory.used
        let memoryTotal = max(1, s.memory.total)
        let diskTotal = max(1, s.disk.total)
        var battery: Reading?
        if let b = s.battery {
            let state: String
            if b.isCharging { state = String(localized: "Charging") }
            else if b.isPluggedIn { state = b.isFullyCharged ? String(localized: "Charged") : String(localized: "Plugged in") }
            else if let t = b.timeRemaining, t > 0 { state = String(localized: "\(Format.duration(t)) left") }
            else { state = String(localized: "On battery") }
            battery = Reading(text: Format.percent(b.percent), fraction: b.percent / 100, detail: state)
        }
        let temperature = s.sensors.cpuTemperature.map {
            Reading(text: Format.temperature($0), fraction: $0 / 100, detail: s.thermal == .nominal ? nil : String(localized: "Thermal state: \(s.thermal.rawValue)"))
        }
        self.init(
            date: s.date,
            cpu: Reading(text: Format.percent(s.cpu.total), fraction: s.cpu.total / 100,
                         detail: String(localized: "User \(Format.percent(s.cpu.user)) · System \(Format.percent(s.cpu.system))")),
            memory: Reading(text: Format.memory(memoryUsed), fraction: Double(memoryUsed) / Double(memoryTotal),
                            detail: String(localized: "Pressure: \(s.memory.pressure.label)")),
            memoryPressure: Pressure(rawValue: s.memory.pressure.rawValue) ?? .normal,
            gpu: s.gpu.map { Reading(text: Format.percent($0.utilization), fraction: $0.utilization / 100, detail: nil) },
            disk: Reading(text: String(localized: "\(Format.storage(s.disk.free)) free"),
                          fraction: 1 - Double(s.disk.free) / Double(diskTotal),
                          detail: String(localized: "of \(Format.storage(s.disk.total))")),
            networkIn: Reading(text: Format.networkRate(s.network.inRate)),
            networkOut: Reading(text: Format.networkRate(s.network.outRate)),
            temperature: temperature,
            temperatureCelsius: s.sensors.cpuTemperature,
            battery: battery,
            batteryCharging: s.battery?.isCharging ?? false,
            topApps: Self.topApps(s.apps).map {
                App(id: $0.id, name: $0.name, cpuText: Format.percent($0.cpuPercent, decimals: $0.cpuPercent < 10 ? 1 : 0),
                    memoryText: Format.memory($0.memory), cpuPercent: $0.cpuPercent, icon: icon($0),
                    symbol: $0.bundlePath != nil ? nil : ($0.kind == .system ? "apple.logo" : "terminal.fill"))
            })
    }

    /// The three apps using the most CPU right now; memory breaks ties so an idle Mac still lists something.
    public static func topApps(_ apps: [AppGroup], count: Int = 3) -> [AppGroup] {
        Array(apps.sorted { ($0.cpuPercent, $0.memory) > ($1.cpuPercent, $1.memory) }.prefix(count))
    }
}

/// When the app writes the widget snapshot and asks WidgetKit to reload. Writes are cheap (one small file),
/// reloads are not (WidgetKit budgets them), and with no widget placed nothing is written at all.
public struct WidgetPublishSchedule: Sendable {
    public var writeInterval: TimeInterval = 60
    public var reloadInterval: TimeInterval = 5 * 60
    /// How often to ask WidgetKit whether any widget is placed.
    public var checkInterval: TimeInterval = 3 * 60

    public private(set) var hasWidgets: Bool?
    private var lastCheck: Date?
    private var lastWrite: Date?
    private var lastReload: Date?

    public init() {}

    public struct Decision: Equatable, Sendable {
        public var checkWidgets = false
        public var write = false
        public var reload = false
    }

    /// Called for every sample.
    public mutating func decide(at now: Date) -> Decision {
        var decision = Decision()
        if lastCheck.map({ now.timeIntervalSince($0) >= checkInterval }) ?? true {
            decision.checkWidgets = true
            lastCheck = now
        }
        // The very first sample is written anyway, so a widget placed later has something to show at once.
        let wanted = hasWidgets ?? (lastWrite == nil)
        guard wanted else { return decision }
        if lastWrite.map({ now.timeIntervalSince($0) >= writeInterval }) ?? true {
            decision.write = true
            lastWrite = now
            if hasWidgets == true, lastReload.map({ now.timeIntervalSince($0) >= reloadInterval }) ?? true {
                decision.reload = true
                lastReload = now
            }
        }
        return decision
    }

    /// The answer to `checkWidgets`. A widget that just appeared gets fresh numbers with the next sample.
    public mutating func widgetsFound(_ found: Bool) {
        if found, hasWidgets != true {
            lastWrite = nil
            lastReload = nil
        }
        hasWidgets = found
    }
}
