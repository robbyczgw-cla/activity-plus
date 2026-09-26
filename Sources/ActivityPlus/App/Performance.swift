import Foundation

/// Settings → Performance. Every switch here removes measurable work; the costs are from
/// `aplus --bench` and `sample` on an M1 Max with ~900 processes.
enum Performance {
    static let changed = Notification.Name("ActivityPlusPerformanceChanged")

    private static func flag(_ key: String) -> Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }

    static var perAppNetwork: Bool { flag("perf.perAppNetwork") }
    static var perAppGPU: Bool { flag("perf.perAppGPU") }
    static var sensors: Bool { flag("perf.sensors") }
    static var chip: Bool { flag("perf.chip") }
    static var drives: Bool { flag("perf.drives") }
    static var networkDetails: Bool { flag("perf.networkDetails") }
    static var devServers: Bool { flag("perf.devServers") }
    static var hangs: Bool { flag("perf.hangs") }
    static var insights: Bool { flag("perf.insights") }
    /// Pings the router (and an optional host you choose) every 30 s. Off unless you turn it on.
    static var connectionQuality: Bool { UserDefaults.standard.object(forKey: "perf.connectionQuality") as? Bool ?? false }
    /// Optional public host for connection quality; empty = only the router.
    static var pingTarget: String { UserDefaults.standard.string(forKey: "pingTarget")?.trimmingCharacters(in: .whitespaces) ?? "" }
    /// Sampling interval while no window or panel is open.
    static var backgroundInterval: TimeInterval {
        let value = UserDefaults.standard.double(forKey: "perf.backgroundInterval")
        return value > 0 ? value : 5
    }

    static func notify() { NotificationCenter.default.post(name: changed, object: nil) }
}
