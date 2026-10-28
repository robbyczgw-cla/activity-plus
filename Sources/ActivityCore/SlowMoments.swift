import Foundation

/// A stretch of at least ~20 seconds in which the Mac was clearly struggling, with what caused it.
public struct SlowMoment: Sendable, Codable, Hashable, Identifiable {
    public enum Severity: Int, Sendable, Codable, Comparable {
        case noticeable = 1, bad = 2, severe = 3
        public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
        public var label: String {
            switch self {
            case .noticeable: String(localized: "Noticeable")
            case .bad: String(localized: "Slow")
            case .severe: String(localized: "Very slow")
            }
        }
    }

    public enum Kind: String, Sendable, Codable, CaseIterable {
        case memory, swap, cpu, gpu, thermal, hang, disk

        /// How much this kind of trouble is felt, used for ranking and severity.
        var weight: Double {
            switch self {
            case .memory, .hang: 3
            case .thermal: 2.5
            case .swap, .cpu: 2
            case .gpu, .disk: 1
            }
        }
    }

    /// An app behind a cause. `value` is bytes for memory and swap, percent of one core for CPU and heat,
    /// percent for the GPU, bytes moved for the disk and seconds for a hang.
    public struct Culprit: Sendable, Codable, Hashable, Identifiable {
        public let appID: String
        public let name: String
        public let value: Double
        public var id: String { appID }
        public init(appID: String, name: String, value: Double) { self.appID = appID; self.name = name; self.value = value }
    }

    public struct Cause: Sendable, Codable, Hashable, Identifiable {
        public let kind: Kind
        /// Seconds this condition held during the moment.
        public let seconds: Double
        /// The worst value: CPU/GPU percent, swap-out bytes/s, disk bytes/s, thermal level (2 hot, 3 critical),
        /// swap used in bytes for memory, longest hang in seconds.
        public let peak: Double
        public let apps: [Culprit]
        public var id: Kind { kind }
        public init(kind: Kind, seconds: Double, peak: Double, apps: [Culprit]) {
            self.kind = kind; self.seconds = seconds; self.peak = peak; self.apps = apps
        }
    }

    public let start: Date
    public let end: Date
    public let severity: Severity
    /// At most three, biggest first.
    public let causes: [Cause]
    public var id: Date { start }
    public var duration: TimeInterval { end.timeIntervalSince(start) }

    public init(start: Date, end: Date, severity: Severity, causes: [Cause]) {
        self.start = start; self.end = end; self.severity = severity; self.causes = causes
    }
}

extension SlowMoment {
    /// "45 s", "2 min 10 s", "1h 05m": short moments need seconds, which Format.duration leaves out.
    public static func lengthText(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return String(localized: "\(max(total, 1)) s") }
        if total < 600 { return total % 60 == 0 ? String(localized: "\(total / 60) min") : String(localized: "\(total / 60) min \(total % 60) s") }
        return Format.duration(seconds)
    }
}

extension SlowMoment.Cause {
    /// One short line: "Memory ran out", "CPU at up to 98 %"…
    public var title: String {
        switch kind {
        case .memory: String(localized: "Memory ran out (pressure critical)")
        case .swap: String(localized: "Heavy swapping to disk, up to \(Format.rate(peak))")
        case .cpu: String(localized: "Processor at up to \(Format.percent(peak))")
        case .gpu: String(localized: "Graphics at up to \(Format.percent(peak))")
        case .thermal: peak >= 3 ? String(localized: "Too hot: macOS slowed the chip down a lot") : String(localized: "Hot: macOS slowed the chip down")
        case .hang: apps.count == 1 ? String(localized: "\(apps[0].name) stopped responding") : String(localized: "Apps stopped responding")
        case .disk: String(localized: "Disk busy, up to \(Format.rate(peak))")
        }
    }

    /// The apps behind it, with the figure that matters for this cause: "Browser 6.1 GB, Mail 1.2 GB".
    public var appsLine: String {
        apps.map { app in
            switch kind {
            case .memory, .swap: "\(app.name) \(Format.memory(UInt64(max(0, app.value))))"
            case .cpu, .thermal: "\(app.name) \(Format.percent(app.value))"
            case .gpu: "\(app.name) \(Format.percent(app.value))"
            case .disk: "\(app.name) \(Format.storage(UInt64(max(0, app.value))))"
            case .hang: "\(app.name) \(Format.duration(app.value))"
            }
        }.joined(separator: ", ")
    }
}

/// Finds slow moments in the live samples, without sampling anything of its own.
///
/// Feed every snapshot (and the apps that are not responding at that moment) to `observe`; it returns a moment
/// once one has ended. A moment starts when any condition holds, survives short dips (≤ `dipTolerance`) and
/// counts only if it lasted at least `minimumDuration`.
public struct SlowMomentDetector: Sendable {
    public struct Thresholds: Sendable {
        public var cpu: Double = 90             // whole machine, percent
        public var gpu: Double = 95
        public var swapOut: Double = 10_000_000 // bytes per second
        public var disk: Double = 500_000_000   // read + write, bytes per second
        public init() {}
    }

    public var thresholds = Thresholds()
    public var minimumDuration: TimeInterval = 20
    public var dipTolerance: TimeInterval = 10
    /// Longer gaps between samples mean the Mac slept; a moment never spans one.
    public var maxGap: TimeInterval = 120

    private struct AppTally {
        var name: String
        var value = 0.0
        var seconds = 0.0
    }

    private struct CauseTally {
        var seconds = 0.0
        var peak = 0.0
        var apps: [String: AppTally] = [:]
    }

    private struct Episode {
        var start: Date
        var lastActive: Date
        var causes: [SlowMoment.Kind: CauseTally] = [:]
    }

    private var episode: Episode?
    private var lastSample: Date?

    public init() {}

    /// - Parameters:
    ///   - snapshot: the latest sample.
    ///   - hanging: apps that are not responding right now (id and name).
    /// - Returns: a moment that has just ended, if any.
    public mutating func observe(_ snapshot: SystemSnapshot, hanging: [(id: String, name: String)] = []) -> SlowMoment? {
        let now = snapshot.date
        var finished: SlowMoment?
        if let last = lastSample, now.timeIntervalSince(last) > maxGap || snapshot.interval > maxGap {
            finished = close()
        }
        lastSample = now
        // The first sample after a sleep covers the whole gap; like the history, leave it out.
        guard snapshot.interval > 0, snapshot.interval <= maxGap else { return finished }
        let dt = snapshot.interval

        let active = conditions(snapshot, hanging: hanging)
        if active.isEmpty {
            if let e = episode, now.timeIntervalSince(e.lastActive) > dipTolerance {
                finished = close() ?? finished
            }
            return finished
        }

        if episode == nil { episode = Episode(start: now.addingTimeInterval(-dt), lastActive: now) }
        episode!.lastActive = now
        for (kind, peak) in active {
            var tally = episode!.causes[kind] ?? CauseTally()
            tally.seconds += dt
            tally.peak = max(tally.peak, peak)
            add(kind, snapshot: snapshot, hanging: hanging, dt: dt, to: &tally)
            episode!.causes[kind] = tally
        }
        return finished
    }

    /// Ends a moment in progress (for example when the app quits or the Mac goes to sleep).
    public mutating func close() -> SlowMoment? {
        defer { episode = nil }
        guard let e = episode else { return nil }
        let duration = e.lastActive.timeIntervalSince(e.start)
        guard duration >= minimumDuration else { return nil }
        // A cause counts when it held for a good part of the moment (or at least 10 s).
        let floor = min(10, duration / 2)
        let ranked = e.causes.filter { $0.value.seconds >= floor }
            .sorted { a, b in
                let x = a.key.weight * a.value.seconds, y = b.key.weight * b.value.seconds
                if x != y { return x > y }
                return SlowMoment.Kind.allCases.firstIndex(of: a.key)! < SlowMoment.Kind.allCases.firstIndex(of: b.key)!
            }
        guard !ranked.isEmpty else { return nil }
        let causes = ranked.prefix(3).map { kind, tally in
            SlowMoment.Cause(kind: kind, seconds: tally.seconds, peak: tally.peak, apps: Self.culprits(kind, tally))
        }
        return SlowMoment(start: e.start, end: e.lastActive, severity: Self.severity(causes, duration: duration), causes: causes)
    }

    /// The conditions that hold in this sample, each with its value for "peak".
    func conditions(_ s: SystemSnapshot, hanging: [(id: String, name: String)]) -> [(SlowMoment.Kind, Double)] {
        var result: [(SlowMoment.Kind, Double)] = []
        if s.memory.pressure == .critical { result.append((.memory, Double(s.memory.swapUsed))) }
        if s.memory.swapOutRate >= thresholds.swapOut { result.append((.swap, s.memory.swapOutRate)) }
        if s.cpu.total >= thresholds.cpu { result.append((.cpu, s.cpu.total)) }
        if let gpu = s.gpu, gpu.utilization >= thresholds.gpu { result.append((.gpu, gpu.utilization)) }
        if s.thermal == .serious || s.thermal == .critical { result.append((.thermal, Double(s.thermal.level))) }
        if !hanging.isEmpty { result.append((.hang, 0)) }
        let io = s.disk.readRate + s.disk.writeRate
        if io >= thresholds.disk { result.append((.disk, io)) }
        return result
    }

    private func add(_ kind: SlowMoment.Kind, snapshot s: SystemSnapshot, hanging: [(id: String, name: String)], dt: Double, to tally: inout CauseTally) {
        func bump(_ id: String, _ name: String, _ value: Double, max useMax: Bool = false) {
            var app = tally.apps[id] ?? AppTally(name: name)
            app.value = useMax ? Swift.max(app.value, value) : app.value + value
            app.seconds += dt
            tally.apps[id] = app
        }
        switch kind {
        case .memory, .swap:
            for app in s.apps where app.memory > 100_000_000 { bump(app.id, app.name, Double(app.memory), max: true) }
        case .cpu, .thermal:
            for app in s.apps where app.cpuPercent > 5 { bump(app.id, app.name, app.cpuPercent * dt) }
        case .gpu:
            for app in s.apps where app.gpuPercent > 2 { bump(app.id, app.name, app.gpuPercent * dt) }
        case .disk:
            for app in s.apps where app.diskReadRate + app.diskWriteRate > 1_000_000 {
                bump(app.id, app.name, (app.diskReadRate + app.diskWriteRate) * dt)
            }
        case .hang:
            for app in hanging { bump(app.id, app.name, dt) }
            tally.peak = tally.apps.values.map(\.value).max() ?? 0
        }
    }

    private static func culprits(_ kind: SlowMoment.Kind, _ tally: CauseTally) -> [SlowMoment.Culprit] {
        let list: [SlowMoment.Culprit] = tally.apps.map { id, app in
            switch kind {
            // Rates summed over time: report the average over the time the cause held.
            case .cpu, .thermal, .gpu:
                SlowMoment.Culprit(appID: id, name: app.name, value: app.value / max(tally.seconds, 1))
            default:
                SlowMoment.Culprit(appID: id, name: app.name, value: app.value)
            }
        }
        let minimum: Double = switch kind {
        case .cpu, .thermal: 10     // percent of one core
        case .gpu: 5
        default: 0
        }
        return Array(list.filter { $0.value >= minimum }.sorted { $0.value > $1.value }.prefix(3))
    }

    static func severity(_ causes: [SlowMoment.Cause], duration: TimeInterval) -> SlowMoment.Severity {
        var level = 1
        for cause in causes {
            switch cause.kind {
            case .memory: level = max(level, 3)
            case .hang: level = max(level, cause.peak >= 10 ? 3 : 2)
            case .thermal: level = max(level, cause.peak >= 3 ? 3 : 2)
            case .swap: level = max(level, 2)
            case .cpu: level = max(level, cause.peak >= 98 && cause.seconds >= 60 ? 2 : 1)
            case .gpu, .disk: break
            }
        }
        // Several heavy conditions at once, or a long stretch, are felt more.
        if causes.filter({ $0.kind.weight >= 2 }).count >= 2 || duration >= 5 * 60 { level += 1 }
        return SlowMoment.Severity(rawValue: min(3, level)) ?? .noticeable
    }
}
