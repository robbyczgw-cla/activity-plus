import Foundation

/// One continuous charge: from plugging in (or starting to charge) until unplugged.
public struct ChargeSession: Sendable, Hashable {
    public var start: Date
    public var startPercent: Double
    public var percent: Double
    /// Energy put into the battery so far, watt-hours.
    public var energyWh: Double
    public var averageWatts: Double
    public var peakWatts: Double
    /// Watts into the battery and percent, one point per sample, oldest first.
    public var points: [Point]
    public struct Point: Sendable, Hashable {
        public var date: Date
        public var percent: Double
        public var watts: Double
        public init(date: Date, percent: Double, watts: Double) { self.date = date; self.percent = percent; self.watts = watts }
    }
    public var gainedPercent: Double { percent - startPercent }
}

/// Feed from one serial queue, just like the hardware samplers.
public final class ChargeSessionTracker {
    public private(set) var lastSession: ChargeSession?
    private var current: ChargeSession?
    private var previous: (date: Date, watts: Double)?
    private var chargingSeconds: TimeInterval = 0

    public init() {}

    public func update(_ battery: BatteryStats?, at date: Date) -> ChargeSession? {
        guard let battery else {
            previous = nil // Missing telemetry must not bridge an unobserved interval.
            return current
        }
        guard battery.isPluggedIn else {
            if let current { lastSession = current }
            current = nil
            previous = nil
            chargingSeconds = 0
            return nil
        }
        if current == nil {
            current = ChargeSession(start: date, startPercent: battery.percent, percent: battery.percent,
                                    energyWh: 0, averageWatts: 0, peakWatts: 0, points: [])
            chargingSeconds = 0
        }
        guard var session = current else { return nil }
        let watts = battery.batteryPower.isFinite ? max(0, battery.batteryPower) : 0
        if let previous {
            let dt = date.timeIntervalSince(previous.date)
            // Ignore out-of-order samples without moving the integration baseline backwards.
            guard dt > 0 else { return current }
            if dt <= 300 {
                session.energyWh += (previous.watts + watts) / 2 * dt / 3600
                // Linear interpolation gives the time above the charging threshold.
                if previous.watts > 0.5, watts > 0.5 {
                    chargingSeconds += dt
                } else if max(previous.watts, watts) > 0.5 {
                    chargingSeconds += dt * (max(previous.watts, watts) - 0.5) / abs(watts - previous.watts)
                }
            }
        }
        previous = (date, watts)
        session.percent = battery.percent
        session.peakWatts = max(session.peakWatts, watts)
        session.averageWatts = chargingSeconds > 0 ? session.energyWh * 3600 / chargingSeconds : 0
        session.points.removeAll { $0.date < date.addingTimeInterval(-86_400) }
        if session.points.last.map({ date.timeIntervalSince($0.date) >= 30 }) ?? true {
            session.points.append(.init(date: date, percent: battery.percent, watts: watts))
        }
        current = session
        return session
    }
}
