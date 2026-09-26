import Foundation
import SQLite3

/// One ping round to a host: latency, jitter (standard deviation) and packet loss.
public struct PingResult: Sendable, Hashable {
    public let target: String
    public let date: Date
    public let sent: Int
    public let received: Int
    public let averageMs: Double?
    public let jitterMs: Double?

    public var lossPercent: Double { sent > 0 ? Double(sent - received) / Double(sent) * 100 : 0 }
    public var isOutage: Bool { sent > 0 && received == 0 }
}

/// Latency and loss with the system `ping` (no root needed). Nothing leaves the Mac unless the user
/// entered a public host: by default only the router on the local network is asked.
public enum ConnectionProbe {
    /// Host names and IP addresses only; nothing that `ping` could read as an option.
    public static func isValidTarget(_ host: String) -> Bool {
        guard !host.isEmpty, host.count <= 253, !host.hasPrefix("-") else { return false }
        return host.range(of: #"^[A-Za-z0-9.:\-]+$"#, options: .regularExpression) != nil
    }

    public static func ping(_ host: String, count: Int = 5, timeoutSeconds: Int = 4) -> PingResult? {
        guard isValidTarget(host) else { return nil }
        let process = Process(), out = Pipe()
        process.executableURL = URL(fileURLWithPath: host.contains(":") ? "/sbin/ping6" : "/sbin/ping")
        process.arguments = host.contains(":")
            ? ["-c", String(count), "-i", "0.2", "-q", host]
            : ["-c", String(count), "-i", "0.2", "-t", String(timeoutSeconds), "-q", host]
        process.standardOutput = out
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return parse(String(decoding: data, as: UTF8.self), target: host, date: Date())
    }

    /// Parses `ping -q` output ("5 packets transmitted, 4 packets received" and "min/avg/max/stddev = …").
    public static func parse(_ output: String, target: String, date: Date) -> PingResult? {
        guard let counts = output.range(of: #"(\d+) packets transmitted, (\d+) (packets )?received"#, options: .regularExpression) else { return nil }
        let numbers = output[counts].split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        guard numbers.count >= 2 else { return nil }
        var average: Double?, jitter: Double?
        if let stats = output.range(of: #"= [0-9.]+/[0-9.]+/[0-9.]+/[0-9.]+ ms"#, options: .regularExpression) {
            let values = output[stats].dropFirst(2).dropLast(3).split(separator: "/").compactMap { Double($0) }
            if values.count == 4 { average = values[1]; jitter = values[3] }
        }
        return PingResult(target: target, date: date, sent: numbers[0], received: numbers[1], averageMs: average, jitterMs: jitter)
    }
}

extension HistoryStore {
    func createPingTable() {
        exec("CREATE TABLE IF NOT EXISTS pings (ts REAL NOT NULL, target TEXT NOT NULL, sent INTEGER, received INTEGER, avg_ms REAL, jitter_ms REAL)")
        exec("CREATE INDEX IF NOT EXISTS pings_ts ON pings(ts)")
    }

    public func record(_ ping: PingResult) {
        queue.async { [self] in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "INSERT INTO pings VALUES (?,?,?,?,?,?)", -1, &statement, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_double(statement, 1, ping.date.timeIntervalSince1970)
            bindText(statement, 2, ping.target)
            sqlite3_bind_int(statement, 3, Int32(ping.sent))
            sqlite3_bind_int(statement, 4, Int32(ping.received))
            if let a = ping.averageMs { sqlite3_bind_double(statement, 5, a) } else { sqlite3_bind_null(statement, 5) }
            if let j = ping.jitterMs { sqlite3_bind_double(statement, 6, j) } else { sqlite3_bind_null(statement, 6) }
            sqlite3_step(statement)
        }
    }

    public func pings(since: Date) -> [PingResult] {
        queue.sync {
            query("SELECT ts, target, sent, received, avg_ms, jitter_ms FROM pings WHERE ts >= \(since.timeIntervalSince1970) ORDER BY ts") { r in
                PingResult(target: Self.text(r, 1), date: Date(timeIntervalSince1970: sqlite3_column_double(r, 0)),
                           sent: Int(sqlite3_column_int(r, 2)), received: Int(sqlite3_column_int(r, 3)),
                           averageMs: sqlite3_column_type(r, 4) == SQLITE_NULL ? nil : sqlite3_column_double(r, 4),
                           jitterMs: sqlite3_column_type(r, 5) == SQLITE_NULL ? nil : sqlite3_column_double(r, 5))
            }
        }
    }
}
