import Foundation

// MARK: - Unusual for this app

/// An app doing something it normally does not: compared with its own history, not a fixed threshold.
public struct Anomaly: Sendable, Identifiable, Hashable {
    public enum Kind: String, Sendable, Codable { case memory, cpu, leak }
    public let appID: String
    public let appName: String
    public let kind: Kind
    public let title: String
    public let detail: String
    /// How far from normal (e.g. 3.2 = 3.2 × the usual value).
    public let factor: Double
    public var id: String { "\(kind.rawValue):\(appID)" }
}

public enum AnomalyDetector {
    /// Compares each running app with its baseline (typically the last 7 days, excluding today).
    /// `recentCPU` is the app's CPU over the last minutes, so short spikes do not count.
    public static func detect(apps: [AppGroup], baselines: [String: HistoryStore.Baseline],
                              recentCPU: [String: [Double]]) -> [Anomaly] {
        var result: [Anomaly] = []
        for app in apps where app.kind != .system {
            // Needs at least 3 hours of history (36 five-minute windows) to know what normal is.
            guard let base = baselines[app.id], base.windows >= 36 else { continue }

            let memory = Double(app.memory)
            let usualMemory = max(base.averageMemory, 1)
            let memoryFactor = memory / usualMemory
            if memory > 500_000_000, memoryFactor >= 2.5, memory > base.typicalPeakMemory * 1.5 {
                result.append(Anomaly(
                    appID: app.id, appName: app.name, kind: .memory,
                    title: "\(app.name) uses \(String(format: "%.1f", memoryFactor))× its usual memory",
                    detail: "\(Format.memory(app.memory)) now; normally about \(Format.memory(UInt64(usualMemory))).",
                    factor: memoryFactor))
            }

            if let series = recentCPU[app.id], series.count >= 30 {
                let window = series.suffix(60)
                let average = window.reduce(0, +) / Double(window.count)
                let usualCPU = max(base.averageCPU, 1)
                let cpuFactor = average / usualCPU
                if average > 30, cpuFactor >= 3 {
                    result.append(Anomaly(
                        appID: app.id, appName: app.name, kind: .cpu,
                        title: "\(app.name) is much busier than usual",
                        detail: "\(Format.percent(average)) CPU for the last minutes; it usually averages \(Format.percent(usualCPU)).",
                        factor: cpuFactor))
                }
            }
        }
        return result.sorted { $0.factor > $1.factor }
    }
}

// MARK: - Leak forecast

public struct LeakForecast: Sendable, Hashable {
    /// Bytes per hour.
    public let growthPerHour: Double
    /// Fit quality 0…1; only steady growth counts.
    public let confidence: Double
    public let current: Double

    /// Memory after `hours` at the current pace.
    public func projected(hours: Double) -> Double { current + growthPerHour * hours }

    /// Hours until the app reaches `bytes`, nil if it never will at this pace.
    public func hours(until bytes: Double) -> Double? {
        guard growthPerHour > 0, bytes > current else { return nil }
        return (bytes - current) / growthPerHour
    }
}

public enum LeakDetector {
    /// Linear fit over (date, memory) points. Reports only steady growth: at least 1 h of data,
    /// > 150 MB/h and a good fit (R² ≥ 0.8), so normal ups and downs do not look like leaks.
    public static func forecast(_ points: [(date: Date, memory: Double)]) -> LeakForecast? {
        guard points.count >= 6, let first = points.first?.date, let last = points.last?.date,
              last.timeIntervalSince(first) >= 3600 else { return nil }
        let xs = points.map { $0.date.timeIntervalSince(first) / 3600 }
        let ys = points.map(\.memory)
        let n = Double(points.count)
        let meanX = xs.reduce(0, +) / n
        let meanY = ys.reduce(0, +) / n
        var covariance = 0.0, varianceX = 0.0, varianceY = 0.0
        for (x, y) in zip(xs, ys) {
            covariance += (x - meanX) * (y - meanY)
            varianceX += (x - meanX) * (x - meanX)
            varianceY += (y - meanY) * (y - meanY)
        }
        guard varianceX > 0, varianceY > 0 else { return nil }
        let slope = covariance / varianceX
        let r2 = (covariance * covariance) / (varianceX * varianceY)
        guard slope > 150_000_000, r2 >= 0.8 else { return nil }
        return LeakForecast(growthPerHour: slope, confidence: r2, current: ys.last ?? 0)
    }
}

// MARK: - Weekly report

public struct WeeklyReport: Sendable {
    public struct Change: Sendable, Identifiable {
        public let appID: String
        public let name: String
        public let bundlePath: String?
        public let now: Double
        public let before: Double
        public var id: String { appID }
        public var factor: Double { before > 0 ? now / before : .infinity }
    }

    public let start: Date
    public let end: Date
    public let totals: HistoryStore.Totals
    public let previousTotals: HistoryStore.Totals
    public let topEnergy: [HistoryStore.AppTotal]
    public let topMemory: [HistoryStore.AppTotal]
    public let topCPU: [HistoryStore.AppTotal]
    public let topNetwork: [HistoryStore.AppTotal]
    /// Apps whose energy or memory grew the most compared with the week before.
    public let biggestIncreases: [Change]
    public let hasPreviousWeek: Bool

    /// The Monday-to-Monday week that ended before `date` (or the current week so far with `current`).
    public static func weekBounds(containing date: Date = Date(), current: Bool = false) -> (start: Date, end: Date) {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = .current
        let thisWeek = calendar.dateInterval(of: .weekOfYear, for: date)!
        if current { return (thisWeek.start, date) }
        let lastStart = calendar.date(byAdding: .weekOfYear, value: -1, to: thisWeek.start)!
        return (lastStart, thisWeek.start)
    }

    public static func build(from store: HistoryStore, start: Date, end: Date) -> WeeklyReport {
        let length = end.timeIntervalSince(start)
        let previousStart = start.addingTimeInterval(-length)
        let apps = store.topApps(from: start, to: end).filter { !$0.appID.hasPrefix("system") }
        let previous = store.topApps(from: previousStart, to: start)
        let previousByID = Dictionary(previous.map { ($0.appID, $0) }, uniquingKeysWith: { a, _ in a })

        let increases = apps.compactMap { app -> Change? in
            guard let before = previousByID[app.appID], before.energyWh > 0.5, app.energyWh > before.energyWh * 1.5,
                  app.energyWh - before.energyWh > 1 else { return nil }
            return Change(appID: app.appID, name: app.name, bundlePath: app.bundlePath, now: app.energyWh, before: before.energyWh)
        }
        .sorted { ($0.now - $0.before) > ($1.now - $1.before) }

        return WeeklyReport(
            start: start, end: end,
            totals: store.totals(from: start, to: end),
            previousTotals: store.totals(from: previousStart, to: start),
            topEnergy: Array(apps.sorted { $0.energyWh > $1.energyWh }.prefix(5)),
            topMemory: Array(apps.sorted { $0.averageMemory > $1.averageMemory }.prefix(5)),
            topCPU: Array(apps.sorted { $0.averageCPU > $1.averageCPU }.prefix(5)),
            topNetwork: Array(apps.sorted { $0.networkBytes > $1.networkBytes }.prefix(5)),
            biggestIncreases: Array(increases.prefix(3)),
            hasPreviousWeek: !previous.isEmpty
        )
    }

    /// One line for the Monday notification.
    public var headline: String {
        guard let top = topEnergy.first else { return "Not enough history for a weekly report yet." }
        var text = "\(top.name) used the most energy last week"
        if totals.energyWh > 0 { text += " (\(String(format: "%.0f", top.energyWh)) of \(String(format: "%.0f", totals.energyWh)) Wh)" }
        if let increase = biggestIncreases.first { text += ". \(increase.name) needed \(String(format: "%.1f", increase.factor))× more than the week before" }
        return text + "."
    }
}
