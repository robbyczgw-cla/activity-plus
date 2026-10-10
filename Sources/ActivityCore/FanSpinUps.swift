import Foundation
import SQLite3

/// Finds the moments the fans sped up and names the apps that were busiest just before.
public enum FanSpinUps {
    public struct FanPoint: Sendable, Equatable {
        public let date: Date
        public let rpm: Double
        public init(date: Date, rpm: Double) { self.date = date; self.rpm = rpm }
    }

    /// One app's average load over a recorded 5-minute window ending at `end` (see HistoryStore's apps table).
    public struct AppLoad: Sendable, Equatable, Identifiable {
        public let appID: String
        public let name: String
        /// Percent of one core.
        public let cpu: Double
        /// Percent of the GPU.
        public let gpu: Double
        public var id: String { appID }
        public init(appID: String, name: String, cpu: Double, gpu: Double) { self.appID = appID; self.name = name; self.cpu = cpu; self.gpu = gpu }
    }

    public struct AppWindow: Sendable, Equatable {
        public let end: Date
        public let apps: [AppLoad]
        public init(end: Date, apps: [AppLoad]) { self.end = end; self.apps = apps }
    }

    public struct Culprit: Sendable, Equatable, Identifiable {
        public let appID: String
        public let name: String
        public let cpu: Double
        public let gpu: Double
        /// Share of the whole machine's capacity, CPU and GPU together, used for ranking.
        public let score: Double
        public var id: String { appID }
    }

    public struct SpinUp: Sendable, Equatable, Identifiable {
        public let start: Date
        public let end: Date
        public let peakRPM: Double
        /// Busiest apps in the minutes before, busiest first.
        public let topApps: [Culprit]
        public var id: Date { start }
    }

    /// A fan counts as spun up when it runs this much faster than it does at rest.
    public static let riseRPM: Double = 800
    /// Minutes of load before the fans started that are held responsible.
    public static let lookback: TimeInterval = 10 * 60

    /// - Parameters:
    ///   - fan: Per-minute fastest-fan readings, oldest first. The slowest reading in the list is taken as "at rest".
    ///   - windows: Recorded app load windows around the same time.
    ///   - cores: Logical cores, to turn "percent of one core" into a share of the machine.
    public static func detect(fan: [FanPoint], windows: [AppWindow], cores: Int, maxApps: Int = 2) -> [SpinUp] {
        let points = fan.sorted { $0.date < $1.date }
        guard let rest = points.map(\.rpm).min() else { return [] }
        let threshold = rest + riseRPM
        var events: [(start: Date, end: Date, peak: Double)] = []
        var current: (start: Date, end: Date, peak: Double)?
        for point in points {
            if point.rpm >= threshold {
                if var c = current, point.date.timeIntervalSince(c.end) <= 3 * 60 {
                    c.end = point.date; c.peak = max(c.peak, point.rpm); current = c
                } else {
                    if let c = current { events.append(c) }
                    // A minute row is written at the end of its minute.
                    current = (point.date.addingTimeInterval(-60), point.date, point.rpm)
                }
            }
        }
        if let c = current { events.append(c) }
        return events.map { e in
            SpinUp(start: e.start, end: e.end, peakRPM: e.peak, topApps: culprits(before: e.start, until: e.end, windows: windows, cores: cores, limit: maxApps))
        }
    }

    /// Apps with the highest load in the windows that overlap the ten minutes before the spin-up (and the first minutes of it).
    static func culprits(before start: Date, until end: Date, windows: [AppWindow], cores: Int, limit: Int) -> [Culprit] {
        let from = start.addingTimeInterval(-lookback)
        let to = min(end, start.addingTimeInterval(5 * 60))
        var cpu: [String: Double] = [:], gpu: [String: Double] = [:], names: [String: String] = [:]
        var count = 0
        for window in windows {
            // The window covers the 5 minutes before `end`.
            let windowStart = window.end.addingTimeInterval(-300)
            guard window.end > from, windowStart < to else { continue }
            count += 1
            for app in window.apps {
                cpu[app.appID, default: 0] += app.cpu
                gpu[app.appID, default: 0] += app.gpu
                names[app.appID] = app.name
            }
        }
        guard count > 0 else { return [] }
        let capacity = Double(max(1, cores)) * 100
        let list = names.keys.map { id -> Culprit in
            let c = cpu[id, default: 0] / Double(count), g = gpu[id, default: 0] / Double(count)
            return Culprit(appID: id, name: names[id] ?? id, cpu: c, gpu: g, score: c / capacity * 100 + g)
        }
        // Below 3 % of the machine an app is background noise, not a reason for the fans.
        return list.filter { $0.score >= 3 }.sorted { $0.score > $1.score }.prefix(limit).map { $0 }
    }
}

extension HistoryStore {
    /// Fastest-fan readings per minute; minutes without a reading (older rows, Macs without fans) are left out.
    public func fanSeries(from start: Date, to end: Date) -> [FanSpinUps.FanPoint] {
        queue.sync {
            query("SELECT ts, fan_rpm FROM system WHERE fan_rpm IS NOT NULL AND ts >= \(Int(start.timeIntervalSince1970)) AND ts <= \(Int(end.timeIntervalSince1970)) ORDER BY ts") { s in
                FanSpinUps.FanPoint(date: Date(timeIntervalSince1970: sqlite3_column_double(s, 0)), rpm: sqlite3_column_double(s, 1))
            }
        }
    }

    /// The recorded 5-minute app windows between two dates, each with the apps that had a noticeable CPU or GPU load.
    public func appLoadWindows(from start: Date, to end: Date) -> [FanSpinUps.AppWindow] {
        queue.sync {
            let rows = query("SELECT ts, app_id, name, cpu, gpu FROM apps WHERE (cpu > 1 OR gpu > 1) AND ts >= \(Int(start.timeIntervalSince1970)) AND ts <= \(Int(end.timeIntervalSince1970)) ORDER BY ts") { s in
                (ts: sqlite3_column_double(s, 0), load: FanSpinUps.AppLoad(appID: Self.text(s, 1), name: Self.text(s, 2),
                                                                         cpu: sqlite3_column_double(s, 3), gpu: sqlite3_column_double(s, 4)))
            }
            return Dictionary(grouping: rows, by: \.ts).map { FanSpinUps.AppWindow(end: Date(timeIntervalSince1970: $0.key), apps: $0.value.map(\.load)) }
                .sorted { $0.end < $1.end }
        }
    }

    /// Fan spin-ups since `since`. The slowest reading of the last three days is taken as the fan at rest.
    public func fanSpinUps(since: Date, cores: Int = ProcessInfo.processInfo.activeProcessorCount) -> [FanSpinUps.SpinUp] {
        let now = Date()
        let fan = fanSeries(from: min(since, now.addingTimeInterval(-3 * 86_400)), to: now)
        let windows = appLoadWindows(from: since.addingTimeInterval(-FanSpinUps.lookback - 300), to: now.addingTimeInterval(600))
        return FanSpinUps.detect(fan: fan, windows: windows, cores: cores).filter { $0.end >= since }
    }
}
