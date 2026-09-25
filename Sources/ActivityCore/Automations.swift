import Foundation

/// "When this happens, do that." Every rule either asks first (a notification with a button)
/// or, only if the user explicitly switched it to automatic, acts on its own.
public struct AutomationRule: Codable, Sendable, Identifiable, Hashable {
    public enum Trigger: Codable, Sendable, Hashable {
        case devServerIdle(hours: Double)
        case batteryBelow(percent: Double)
        case appMemoryAbove(appID: String, appName: String, gigabytes: Double)
        case appCPUAbove(appID: String, appName: String, percent: Double, minutes: Int)
        case memoryPressureCritical(minutes: Int)
    }

    public enum Action: Codable, Sendable, Hashable {
        case notify
        /// Quit the app the trigger is about (app triggers) …
        case quitTriggeringApp
        /// … or a specific app (battery and memory-pressure triggers).
        case quitApp(appID: String, appName: String)
        case stopDevServer
    }

    public enum Mode: String, Codable, Sendable { case ask, automatic }

    public var id = UUID()
    public var enabled = true
    public var trigger: Trigger
    public var action: Action
    public var mode: Mode = .ask

    public init(trigger: Trigger, action: Action, mode: Mode = .ask) {
        self.trigger = trigger
        self.action = action
        self.mode = mode
    }

    public var summary: String {
        let when: String = switch trigger {
        case .devServerIdle(let hours): "a dev server has been idle for \(Self.hours(hours))"
        case .batteryBelow(let percent): "the battery drops below \(Int(percent)) %"
        case .appMemoryAbove(_, let name, let gb): "\(name) uses more than \(String(format: "%g", gb)) GB of memory"
        case .appCPUAbove(_, let name, let percent, let minutes): "\(name) stays above \(Int(percent)) % CPU for \(minutes) min"
        case .memoryPressureCritical(let minutes): "memory pressure is critical for \(minutes) min"
        }
        let then: String = switch action {
        case .notify: "notify me"
        case .quitTriggeringApp: "quit it"
        case .quitApp(_, let name): "quit \(name)"
        case .stopDevServer: "stop the server"
        }
        return "When \(when), \(then)"
    }

    /// Which actions make sense for a trigger.
    public static func actions(for trigger: Trigger) -> [Action] {
        switch trigger {
        case .devServerIdle: [.stopDevServer, .notify]
        case .appMemoryAbove, .appCPUAbove: [.quitTriggeringApp, .notify]
        case .batteryBelow, .memoryPressureCritical: [.notify]
        }
    }

    static func hours(_ hours: Double) -> String {
        hours >= 24 && hours.truncatingRemainder(dividingBy: 24) == 0 ? "\(Int(hours / 24)) day\(hours == 24 ? "" : "s")" : "\(String(format: "%g", hours)) h"
    }
}

/// A rule whose trigger is met, with what it would act on.
public struct AutomationMatch: Sendable, Identifiable, Hashable {
    public enum Target: Sendable, Hashable {
        case app(AppGroup)
        case server(DevServer)
        case none
    }
    public let rule: AutomationRule
    public let target: Target
    public let reason: String
    public let date: Date
    public var id: String {
        switch target {
        case .app(let app): "\(rule.id):\(app.id)"
        case .server(let server): "\(rule.id):\(server.pid)"
        case .none: "\(rule.id)"
        }
    }
}

/// Evaluates rules against the live data. Keeps its own state for "for N minutes" conditions and
/// a cooldown so a rule does not fire again for the same target within an hour.
public final class AutomationEngine: @unchecked Sendable {
    private var conditionSince: [String: Date] = [:]
    private var lastFired: [String: Date] = [:]
    /// When this engine first saw each dev server. Idleness only counts from here on: before that,
    /// nobody watched it, and lifetime numbers ("barely used") say nothing about the last hours.
    private var firstSeen: [String: Date] = [:]
    public var cooldown: TimeInterval = 3600

    public init() {}

    public func evaluate(_ rules: [AutomationRule], snapshot: SystemSnapshot, servers: [DevServer], now: Date = Date()) -> [AutomationMatch] {
        var matches: [AutomationMatch] = []
        var active: Set<String> = []

        func sustained(_ key: String, minutes: Int) -> Bool {
            active.insert(key)
            let since = conditionSince[key] ?? now
            conditionSince[key] = since
            return now.timeIntervalSince(since) >= Double(minutes) * 60
        }

        for rule in rules where rule.enabled {
            switch rule.trigger {
            case .devServerIdle(let hours):
                var current: Set<String> = []
                for server in servers {
                    let key = "\(server.pid):\(server.startTime.timeIntervalSince1970)"
                    current.insert(key)
                    let seen = firstSeen[key] ?? now
                    firstSeen[key] = seen
                    if case .working = server.activity(now: now) { continue }
                    // Observed inactivity only: since its last burst of work, and never longer than we watched it.
                    let idleFor = min(now.timeIntervalSince(server.lastActive ?? server.startTime), now.timeIntervalSince(seen))
                    if idleFor >= hours * 3600 {
                        let project = server.directory.map { ($0 as NSString).lastPathComponent } ?? server.name
                        matches.append(AutomationMatch(rule: rule, target: .server(server),
                            reason: "\(project) (port \(server.ports.map(String.init).joined(separator: ", "))) has done nothing for \(Format.duration(idleFor)).", date: now))
                    }
                }
                if !servers.isEmpty { firstSeen = firstSeen.filter { current.contains($0.key) } }
            case .batteryBelow(let percent):
                if let battery = snapshot.battery, !battery.isPluggedIn, battery.percent < percent {
                    matches.append(AutomationMatch(rule: rule, target: .none,
                        reason: "Battery at \(Format.percent(battery.percent)).", date: now))
                }
            case .appMemoryAbove(let appID, _, let gb):
                if let app = snapshot.apps.first(where: { $0.id == appID }), Double(app.memory) > gb * 1_073_741_824 {
                    matches.append(AutomationMatch(rule: rule, target: .app(app),
                        reason: "\(app.name) uses \(Format.memory(app.memory)).", date: now))
                }
            case .appCPUAbove(let appID, _, let percent, let minutes):
                let key = "\(rule.id):cpu"
                if let app = snapshot.apps.first(where: { $0.id == appID }), app.cpuPercent > percent {
                    if sustained(key, minutes: minutes) {
                        matches.append(AutomationMatch(rule: rule, target: .app(app),
                            reason: "\(app.name) has been above \(Int(percent)) % CPU for \(minutes) minutes.", date: now))
                    }
                }
            case .memoryPressureCritical(let minutes):
                if snapshot.memory.pressure == .critical, sustained("\(rule.id):pressure", minutes: minutes) {
                    matches.append(AutomationMatch(rule: rule, target: .none,
                        reason: "Memory pressure has been critical for \(minutes) minutes.", date: now))
                }
            }
        }
        // Conditions that stopped holding start over next time.
        conditionSince = conditionSince.filter { active.contains($0.key) }

        return matches.filter { match in
            if let last = lastFired[match.id], now.timeIntervalSince(last) < cooldown { return false }
            lastFired[match.id] = now
            return true
        }
    }
}
