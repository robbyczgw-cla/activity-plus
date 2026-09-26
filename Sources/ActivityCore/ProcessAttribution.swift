import Darwin
import Foundation
import SQLite3

/// Which child process was behind an app's numbers: kept per 5-minute window in the history,
/// so a spike in "Terminal" can be traced back to "node (vite)" days later.
public struct ProcessTotal: Sendable, Identifiable, Hashable {
    public var id: String { "\(appID)|\(name)|\(command)" }
    public let appID: String
    public let appName: String
    public let pid: Int32
    public let name: String
    public let command: String
    public let averageCPU: Double
    public let peakMemory: Double
    public let diskBytes: Double
    public let networkBytes: Double
}

/// A short, readable command line that is safe to keep: program and first arguments, with anything
/// that looks like a token, password or key blanked out.
public enum ProcessCommand {
    static let secretKeys = #"(?i)(token|secret|passw|pwd|apikey|api[-_]?key|auth|bearer|cookie|session|credential|private[-_]?key)"#

    public static func short(pid: Int32, fallback: String) -> String {
        let args = ProjectScanner.arguments(of: pid)
        return args.isEmpty ? fallback : short(arguments: args)
    }

    public static func short(arguments args: [String]) -> String {
        guard !args.isEmpty else { return "" }
        var parts: [String] = []
        var hideNext = false
        for (index, raw) in args.prefix(8).enumerated() {
            if hideNext { parts.append("•••"); hideNext = false; continue }
            var arg = index == 0 ? (raw as NSString).lastPathComponent : raw
            // --token abc, -p secret: hide the value that follows.
            if arg.hasPrefix("-"), arg.range(of: secretKeys, options: .regularExpression) != nil, !arg.contains("=") {
                parts.append(arg); hideNext = true; continue
            }
            // KEY=value with a secret-looking key.
            if let eq = arg.firstIndex(of: "="), arg[..<eq].range(of: secretKeys, options: .regularExpression) != nil {
                arg = String(arg[...eq]) + "•••"
            }
            // user:password@host in URLs.
            arg = arg.replacingOccurrences(of: #"://[^/\s:@]+:[^/\s@]+@"#, with: "://•••@", options: .regularExpression)
            // Long opaque strings (keys, hashes) that are not paths.
            if !arg.contains("/"), arg.range(of: #"^[A-Za-z0-9_\-+=.]{28,}$"#, options: .regularExpression) != nil {
                arg = "•••"
            }
            // Paths: keep the last component.
            if arg.hasPrefix("/"), arg.contains("/") { arg = (arg as NSString).lastPathComponent }
            parts.append(arg)
        }
        let joined = parts.joined(separator: " ")
        return joined.count > 80 ? String(joined.prefix(77)) + "…" : joined
    }
}

struct ProcessAccumulator {
    let pid: Int32
    let start: Date
    let name: String
    var cpu = 0.0
    var memoryPeak = 0.0
    var diskBytes = 0.0
    var netBytes = 0.0
}

extension HistoryStore {
    func createProcessTable() {
        exec("""
            CREATE TABLE IF NOT EXISTS app_procs (
                ts INTEGER NOT NULL, app_id TEXT NOT NULL, pid INTEGER, name TEXT, command TEXT,
                cpu REAL, mem_peak REAL, disk REAL, net REAL)
            """)
        exec("CREATE INDEX IF NOT EXISTS app_procs_ts ON app_procs(ts)")
        exec("CREATE INDEX IF NOT EXISTS app_procs_app ON app_procs(app_id, ts)")
    }

    /// The busiest processes of one window: top 3 by CPU plus the one with the most memory.
    static func notable(_ processes: [ProcessAccumulator]) -> [ProcessAccumulator] {
        guard processes.count > 1 else { return processes }
        var picked = Array(processes.sorted { $0.cpu > $1.cpu }.prefix(3))
        if let memory = processes.max(by: { $0.memoryPeak < $1.memoryPeak }), !picked.contains(where: { $0.pid == memory.pid }) {
            picked.append(memory)
        }
        return picked
    }

    func writeProcessRows(appID: String, processes: [ProcessAccumulator], windowSamples: Double, at ts: Int64) {
        let sql = "INSERT INTO app_procs (ts, app_id, pid, name, command, cpu, mem_peak, disk, net) VALUES (?,?,?,?,?,?,?,?,?)"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        for p in Self.notable(processes) where p.cpu > 0 || p.memoryPeak > 0 {
            // The command line is read now, and only if the pid still belongs to the same process.
            let alive = ProcessIdentity.isSame(pid: p.pid, startTime: p.start)
            let command = alive ? ProcessCommand.short(pid: p.pid, fallback: p.name) : p.name
            sqlite3_reset(statement)
            sqlite3_bind_int64(statement, 1, ts)
            bindText(statement, 2, appID)
            sqlite3_bind_int(statement, 3, p.pid)
            bindText(statement, 4, p.name)
            bindText(statement, 5, command)
            sqlite3_bind_double(statement, 6, p.cpu / windowSamples)
            sqlite3_bind_double(statement, 7, p.memoryPeak)
            sqlite3_bind_double(statement, 8, p.diskBytes)
            sqlite3_bind_double(statement, 9, p.netBytes)
            sqlite3_step(statement)
        }
    }

    /// The child processes behind an app over a period, heaviest first.
    public func topProcesses(appID: String, from start: Date, to end: Date, limit: Int = 5) -> [ProcessTotal] {
        queue.sync {
            let from = Int(start.timeIntervalSince1970), to = Int(end.timeIntervalSince1970)
            let appFilter = "app_id = '\(appID.replacingOccurrences(of: "'", with: "''"))'"
            // Average over the windows in which the app itself was recorded, like topApps does.
            let windows = max(1, query("SELECT COUNT(DISTINCT ts) FROM apps WHERE \(appFilter) AND ts >= \(from) AND ts <= \(to)") { sqlite3_column_int64($0, 0) }.first ?? 1)
            return query("""
                SELECT p.name, p.command, MAX(p.pid), SUM(p.cpu), MAX(p.mem_peak), SUM(p.disk), SUM(p.net), MAX(a.name)
                FROM app_procs p LEFT JOIN (SELECT DISTINCT app_id, name FROM apps WHERE \(appFilter)) a ON a.app_id = p.app_id
                WHERE p.\(appFilter) AND p.ts >= \(from) AND p.ts <= \(to)
                GROUP BY p.name, p.command ORDER BY SUM(p.cpu) DESC, MAX(p.mem_peak) DESC LIMIT \(limit)
                """) { r in
                ProcessTotal(appID: appID, appName: Self.text(r, 7), pid: sqlite3_column_int(r, 2), name: Self.text(r, 0), command: Self.text(r, 1),
                             averageCPU: sqlite3_column_double(r, 3) / Double(windows), peakMemory: sqlite3_column_double(r, 4),
                             diskBytes: sqlite3_column_double(r, 5), networkBytes: sqlite3_column_double(r, 6))
            }
        }
    }

    /// Everything that was busy in the 5-minute window around a moment: for tracing a spike in the chart.
    public func processesAround(_ date: Date, limit: Int = 8) -> [ProcessTotal] {
        queue.sync {
            let t = Int(date.timeIntervalSince1970)
            // The window that ends closest after the moment (rows are stamped at the window's end).
            guard let ts = query("SELECT ts FROM app_procs WHERE ts >= \(t) ORDER BY ts LIMIT 1") { sqlite3_column_int64($0, 0) }.first
                    ?? query("SELECT MAX(ts) FROM app_procs WHERE ts <= \(t) AND ts > \(t - 600)") { sqlite3_column_int64($0, 0) }.first,
                  ts > 0, ts - Int64(t) <= 600 else { return [] }
            return query("""
                SELECT p.app_id, COALESCE(a.name, p.app_id), p.pid, p.name, p.command, p.cpu, p.mem_peak, p.disk, p.net
                FROM app_procs p LEFT JOIN apps a ON a.app_id = p.app_id AND a.ts = p.ts
                WHERE p.ts = \(ts) ORDER BY p.cpu DESC LIMIT \(limit)
                """) { r in
                ProcessTotal(appID: Self.text(r, 0), appName: Self.text(r, 1), pid: sqlite3_column_int(r, 2), name: Self.text(r, 3), command: Self.text(r, 4),
                             averageCPU: sqlite3_column_double(r, 5), peakMemory: sqlite3_column_double(r, 6),
                             diskBytes: sqlite3_column_double(r, 7), networkBytes: sqlite3_column_double(r, 8))
            }
        }
    }
}
