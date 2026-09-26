import Foundation

public struct AlertSettings: Codable, Sendable, Hashable {
    public var enabled = true
    public var cpuPercent: Double = 70        // average, of one core
    public var cpuMinutes: Int = 10
    public var memoryGrowthGB: Double = 1     // within `memoryWindowMinutes`
    public var memoryWindowMinutes: Int = 60
    public var diskMBps: Double = 50
    public var networkMBps: Double = 20
    public var ioMinutes: Int = 5
    public var systemAlerts = true
    public var cooldownMinutes: Int = 60
    public var ignoredApps: Set<String> = []
    public init() {}
}

public struct AppAlert: Codable, Sendable, Identifiable, Hashable {
    public enum Kind: String, Codable, Sendable {
        case cpu, memoryGrowth, disk, network, memoryPressure, diskFull, thermal, accessory
        case unusual, leak, hang, automation, weekly, power
    }
    public var id = UUID()
    public let date: Date
    public let kind: Kind
    public let appID: String?
    public let appName: String
    public let title: String
    public let detail: String

    public init(date: Date, kind: Kind, appID: String?, appName: String, title: String, detail: String) {
        (self.date, self.kind, self.appID, self.appName, self.title, self.detail) = (date, kind, appID, appName, title, detail)
    }
}

/// Watches snapshots and reports apps that misbehave for a sustained period.
/// Samples are folded into one-minute buckets so decisions are stable and memory stays small.
public final class AlertEngine: @unchecked Sendable {
    public var settings: AlertSettings

    private struct Bucket {
        var minute: Int
        var samples = 0
        var cpu = 0.0, memory = 0.0, disk = 0.0, network = 0.0
        var averageCPU: Double { cpu / Double(max(samples, 1)) }
        var averageMemory: Double { memory / Double(max(samples, 1)) }
        var averageDisk: Double { disk / Double(max(samples, 1)) }
        var averageNetwork: Double { network / Double(max(samples, 1)) }
    }

    private var buckets: [String: [Bucket]] = [:]
    private var names: [String: String] = [:]
    private var lastFired: [String: Date] = [:]
    private var pressureSince: Date?
    private var drainSince: Date?

    public init(settings: AlertSettings = AlertSettings()) {
        self.settings = settings
    }

    public func evaluate(_ snapshot: SystemSnapshot) -> [AppAlert] {
        guard snapshot.interval > 0 else { return [] }
        let now = snapshot.date
        let minute = Int(now.timeIntervalSince1970 / 60)
        let keep = max(settings.memoryWindowMinutes, settings.cpuMinutes, settings.ioMinutes) + 2

        for app in snapshot.apps where app.kind != .system {
            names[app.id] = app.name
            var list = buckets[app.id] ?? []
            if list.last?.minute != minute { list.append(Bucket(minute: minute)) }
            list[list.count - 1].samples += 1
            list[list.count - 1].cpu += app.cpuPercent
            list[list.count - 1].memory += Double(app.memory)
            list[list.count - 1].disk += app.diskReadRate + app.diskWriteRate
            list[list.count - 1].network += app.netInRate + app.netOutRate
            if list.count > keep { list.removeFirst(list.count - keep) }
            buckets[app.id] = list
        }
        let live = Set(snapshot.apps.map(\.id))
        buckets = buckets.filter { live.contains($0.key) }

        guard settings.enabled else { return [] }
        var alerts: [AppAlert] = []

        for (id, list) in buckets where !settings.ignoredApps.contains(id) {
            let name = names[id] ?? id
            // Only complete minutes count; the current one is still filling.
            let complete = list.dropLast().filter { $0.samples > 0 }

            let cpuWindow = complete.suffix(settings.cpuMinutes)
            if cpuWindow.count >= settings.cpuMinutes, isConsecutive(cpuWindow) {
                let average = cpuWindow.reduce(0) { $0 + $1.averageCPU } / Double(cpuWindow.count)
                // Sustained, not a burst: most minutes must be above the threshold on their own.
                let busyMinutes = cpuWindow.filter { $0.averageCPU >= settings.cpuPercent }.count
                if average >= settings.cpuPercent, Double(busyMinutes) >= Double(cpuWindow.count) * 0.8 {
                    fire(&alerts, .cpu, id, name, now,
                         title: "\(name) is keeping the CPU busy",
                         detail: "\(Format.percent(average)) on average for \(settings.cpuMinutes) minutes.")
                }
            }

            let memoryWindow = complete.suffix(settings.memoryWindowMinutes)
            if memoryWindow.count >= settings.memoryWindowMinutes, let first = memoryWindow.first, let last = memoryWindow.last {
                let growth = last.averageMemory - first.averageMemory
                let rising = zip(memoryWindow.dropFirst(), memoryWindow).filter { $0.averageMemory > $1.averageMemory }.count
                // Steady growth, not a single jump: most minutes must go up.
                if growth >= settings.memoryGrowthGB * 1_073_741_824, Double(rising) >= Double(memoryWindow.count - 1) * 0.6 {
                    fire(&alerts, .memoryGrowth, id, name, now,
                         title: "\(name) keeps using more memory",
                         detail: "Up \(Format.memory(UInt64(growth))) in \(Self.minutesText(settings.memoryWindowMinutes)), now \(Format.memory(UInt64(last.averageMemory))).")
                }
            }

            let ioWindow = complete.suffix(settings.ioMinutes)
            if ioWindow.count >= settings.ioMinutes, isConsecutive(ioWindow) {
                let disk = ioWindow.reduce(0) { $0 + $1.averageDisk } / Double(ioWindow.count)
                if disk >= settings.diskMBps * 1_000_000 {
                    fire(&alerts, .disk, id, name, now,
                         title: "\(name) is hammering the disk",
                         detail: "\(Format.rate(disk)) for \(settings.ioMinutes) minutes, \(Format.storage(UInt64(disk * Double(settings.ioMinutes) * 60))) in total.")
                }
                let network = ioWindow.reduce(0) { $0 + $1.averageNetwork } / Double(ioWindow.count)
                if network >= settings.networkMBps * 1_000_000 {
                    fire(&alerts, .network, id, name, now,
                         title: "\(name) is using a lot of network",
                         detail: "\(Format.rate(network)) for \(settings.ioMinutes) minutes.")
                }
            }
        }

        if settings.systemAlerts {
            if snapshot.memory.pressure == .critical {
                pressureSince = pressureSince ?? now
                if now.timeIntervalSince(pressureSince!) >= 120 {
                    let top = snapshot.apps.filter { $0.kind != .system }.max { $0.memory < $1.memory }
                    fire(&alerts, .memoryPressure, nil, "Memory", now,
                         title: "Your Mac is running out of memory",
                         detail: top.map { "\($0.name) uses the most: \(Format.memory($0.memory))." } ?? "Quit apps you are not using.")
                }
            } else {
                pressureSince = nil
            }
            let disk = snapshot.disk
            if disk.total > 0, disk.free < 10_000_000_000 || Double(disk.free) / Double(disk.total) < 0.05 {
                fire(&alerts, .diskFull, nil, "Disk", now,
                     title: "The disk is almost full",
                     detail: "Only \(Format.storage(disk.free)) free on \(disk.volumeName).")
            }
            if let battery = snapshot.battery, battery.drainsWhilePluggedIn {
                drainSince = drainSince ?? now
                if now.timeIntervalSince(drainSince!) >= 180 {
                    let adapter = battery.adapterWatts.map { "The \($0) W adapter" } ?? "The adapter"
                    let draw = battery.systemPower.map { "the Mac draws \(Format.watts($0))" } ?? "the Mac draws more than it delivers"
                    fire(&alerts, .power, nil, "Power", now,
                         title: "The battery drains while plugged in",
                         detail: "\(adapter) cannot keep up: \(draw). Use a stronger adapter or close heavy apps.")
                }
            } else {
                drainSince = nil
            }
            if snapshot.thermal == .serious || snapshot.thermal == .critical {
                fire(&alerts, .thermal, nil, "Temperature", now,
                     title: "Your Mac is running hot",
                     detail: "macOS is slowing the processor down to cool it.")
            }
        }
        return alerts
    }

    private func isConsecutive<C: Collection>(_ window: C) -> Bool where C.Element == Bucket {
        guard let first = window.first?.minute, let last = window.map(\.minute).last else { return false }
        return last - first == window.count - 1
    }

    private func fire(_ alerts: inout [AppAlert], _ kind: AppAlert.Kind, _ id: String?, _ name: String, _ now: Date, title: String, detail: String) {
        let key = "\(kind.rawValue):\(id ?? "system")"
        if let last = lastFired[key], now.timeIntervalSince(last) < Double(settings.cooldownMinutes) * 60 { return }
        lastFired[key] = now
        alerts.append(AppAlert(date: now, kind: kind, appID: id, appName: name, title: title, detail: detail))
    }

    private static func minutesText(_ minutes: Int) -> String {
        minutes % 60 == 0 ? (minutes == 60 ? "an hour" : "\(minutes / 60) hours") : "\(minutes) minutes"
    }
}
