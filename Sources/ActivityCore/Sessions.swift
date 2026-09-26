import Foundation
import SQLite3

/// A recording: a build, a render or a slowdown, measured at full rate so it can be compared and exported.
public struct RecordingSession: Sendable, Identifiable, Hashable {
    public let id: Int64
    public var name: String
    public let started: Date
    public var ended: Date?
    public var samples = 0
    public var averageCPU = 0.0
    public var peakCPU = 0.0
    public var peakMemory = 0.0
    public var energyWh = 0.0
    public var diskBytes = 0.0
    public var networkBytes = 0.0

    public var duration: TimeInterval { (ended ?? Date()).timeIntervalSince(started) }

    public init(id: Int64, name: String, started: Date, ended: Date? = nil) {
        (self.id, self.name, self.started, self.ended) = (id, name, started, ended)
    }
}

public struct SessionSample: Sendable, Hashable {
    public let date: Date
    public let seconds: Double          // time covered by this sample
    public let cpu: Double
    public let memory: Double
    public let gpu: Double
    public let diskRead: Double
    public let diskWrite: Double
    public let netIn: Double
    public let netOut: Double
    public let power: Double?
    public let cpuTemperature: Double?
    public let pressure: Int
}

public struct SessionApp: Sendable, Identifiable, Hashable {
    public let id: String
    public let name: String
    public let averageCPU: Double
    public let peakCPU: Double
    public let peakMemory: Double
    public let energyWh: Double
    public let diskBytes: Double
    public let networkBytes: Double
    /// The child process that did most of the work, when the app has several.
    public var topProcess: String?
}

struct SessionAppAccumulator {
    var name: String
    var cpuSeconds = 0.0      // percent × seconds
    var seconds = 0.0
    var peakCPU = 0.0
    var peakMemory = 0.0
    var energyJoules = 0.0
    var diskBytes = 0.0
    var netBytes = 0.0
    var processCPU: [String: Double] = [:]
}

extension HistoryStore {
    func createSessionTables() {
        exec("""
            CREATE TABLE IF NOT EXISTS sessions (
                id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, started REAL NOT NULL, ended REAL)
            """)
        exec("""
            CREATE TABLE IF NOT EXISTS session_samples (
                session_id INTEGER NOT NULL, ts REAL NOT NULL, secs REAL NOT NULL, cpu REAL, mem REAL, gpu REAL,
                disk_r REAL, disk_w REAL, net_in REAL, net_out REAL, power REAL, cpu_temp REAL, pressure INTEGER)
            """)
        exec("CREATE INDEX IF NOT EXISTS session_samples_id ON session_samples(session_id, ts)")
        exec("""
            CREATE TABLE IF NOT EXISTS session_apps (
                session_id INTEGER NOT NULL, app_id TEXT NOT NULL, name TEXT, cpu_avg REAL, cpu_peak REAL,
                mem_peak REAL, energy_wh REAL, disk REAL, net REAL)
            """)
        exec("ALTER TABLE session_apps ADD COLUMN top_process TEXT")   // v0.2.5; fails harmlessly when present
    }

    // MARK: Recording

    public func startSession(name: String, at date: Date = Date()) -> Int64 {
        queue.sync {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "INSERT INTO sessions (name, started) VALUES (?, ?)", -1, &statement, nil) == SQLITE_OK else { return -1 }
            defer { sqlite3_finalize(statement) }
            bindText(statement, 1, name)
            sqlite3_bind_double(statement, 2, date.timeIntervalSince1970)
            guard sqlite3_step(statement) == SQLITE_DONE else { return -1 }
            let id = sqlite3_last_insert_rowid(db)
            sessionAppTotals[id] = [:]
            return id
        }
    }

    /// Call with every snapshot while the session runs.
    public func recordSession(_ id: Int64, snapshot s: SystemSnapshot) {
        let dt = s.interval
        guard dt > 0, dt <= Self.maxSampleGap else { return }
        queue.async { [self] in
            var statement: OpaquePointer?
            let sql = "INSERT INTO session_samples (session_id, ts, secs, cpu, mem, gpu, disk_r, disk_w, net_in, net_out, power, cpu_temp, pressure) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)"
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int64(statement, 1, id)
            sqlite3_bind_double(statement, 2, s.date.timeIntervalSince1970)
            sqlite3_bind_double(statement, 3, dt)
            sqlite3_bind_double(statement, 4, s.cpu.total)
            sqlite3_bind_double(statement, 5, Double(s.memory.used))
            sqlite3_bind_double(statement, 6, s.gpu?.utilization ?? 0)
            sqlite3_bind_double(statement, 7, s.disk.readRate)
            sqlite3_bind_double(statement, 8, s.disk.writeRate)
            sqlite3_bind_double(statement, 9, s.network.inRate)
            sqlite3_bind_double(statement, 10, s.network.outRate)
            if let p = s.battery?.systemPower { sqlite3_bind_double(statement, 11, p) } else { sqlite3_bind_null(statement, 11) }
            if let t = s.sensors.cpuTemperature { sqlite3_bind_double(statement, 12, t) } else { sqlite3_bind_null(statement, 12) }
            sqlite3_bind_int(statement, 13, Int32(s.memory.pressure.rawValue))
            sqlite3_step(statement)

            var totals = sessionAppTotals[id] ?? [:]
            for app in s.apps where app.cpuPercent > 0.1 || app.memory > 20_000_000 || app.powerWatts > 0.01 {
                var a = totals[app.id] ?? SessionAppAccumulator(name: app.name)
                a.cpuSeconds += app.cpuPercent * dt
                a.seconds += dt
                a.peakCPU = max(a.peakCPU, app.cpuPercent)
                a.peakMemory = max(a.peakMemory, Double(app.memory))
                a.energyJoules += app.powerWatts * dt
                a.diskBytes += (app.diskReadRate + app.diskWriteRate) * dt
                a.netBytes += (app.netInRate + app.netOutRate) * dt
                if app.processes.count > 1 {
                    for p in app.processes where p.cpuPercent > 0.5 { a.processCPU[p.name, default: 0] += p.cpuPercent * dt }
                }
                totals[app.id] = a
            }
            sessionAppTotals[id] = totals
        }
    }

    /// Ends the session and stores its top apps.
    public func stopSession(_ id: Int64, at date: Date = Date()) {
        queue.sync {
            exec("UPDATE sessions SET ended = \(date.timeIntervalSince1970) WHERE id = \(id)")
            // An app's average counts the whole session, including the time it was quiet.
            let total = query("SELECT SUM(secs) FROM session_samples WHERE session_id = \(id)") { sqlite3_column_double($0, 0) }.first ?? 0
            let top = (sessionAppTotals[id] ?? [:]).sorted { $0.value.cpuSeconds > $1.value.cpuSeconds }.prefix(25)
            exec("BEGIN")
            for (appID, a) in top {
                var statement: OpaquePointer?
                guard sqlite3_prepare_v2(db, "INSERT INTO session_apps (session_id, app_id, name, cpu_avg, cpu_peak, mem_peak, energy_wh, disk, net, top_process) VALUES (?,?,?,?,?,?,?,?,?,?)", -1, &statement, nil) == SQLITE_OK else { continue }
                sqlite3_bind_int64(statement, 1, id)
                bindText(statement, 2, appID)
                bindText(statement, 3, a.name)
                sqlite3_bind_double(statement, 4, total > 0 ? a.cpuSeconds / total : 0)
                sqlite3_bind_double(statement, 5, a.peakCPU)
                sqlite3_bind_double(statement, 6, a.peakMemory)
                sqlite3_bind_double(statement, 7, a.energyJoules / 3600)
                sqlite3_bind_double(statement, 8, a.diskBytes)
                sqlite3_bind_double(statement, 9, a.netBytes)
                if let top = a.processCPU.max(by: { $0.value < $1.value })?.key { bindText(statement, 10, top) } else { sqlite3_bind_null(statement, 10) }
                sqlite3_step(statement)
                sqlite3_finalize(statement)
            }
            exec("COMMIT")
            sessionAppTotals[id] = nil
        }
    }

    /// A session that was still open when the app quit or crashed: close it at its last sample.
    public func closeDanglingSessions() {
        queue.sync {
            exec("UPDATE sessions SET ended = COALESCE((SELECT MAX(ts) FROM session_samples WHERE session_id = sessions.id), started) WHERE ended IS NULL")
        }
    }

    // MARK: Reading

    public func sessions() -> [RecordingSession] {
        queue.sync {
            query("""
                SELECT s.id, s.name, s.started, s.ended, COUNT(x.ts), SUM(x.cpu * x.secs) / MAX(SUM(x.secs), 0.001), MAX(x.cpu), MAX(x.mem),
                       SUM(x.power * x.secs) / 3600, SUM((x.disk_r + x.disk_w) * x.secs), SUM((x.net_in + x.net_out) * x.secs)
                FROM sessions s LEFT JOIN session_samples x ON x.session_id = s.id
                GROUP BY s.id ORDER BY s.started DESC
                """) { r in
                var session = RecordingSession(id: sqlite3_column_int64(r, 0), name: Self.text(r, 1),
                                               started: Date(timeIntervalSince1970: sqlite3_column_double(r, 2)),
                                               ended: sqlite3_column_type(r, 3) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(r, 3)))
                session.samples = Int(sqlite3_column_int(r, 4))
                session.averageCPU = sqlite3_column_double(r, 5)
                session.peakCPU = sqlite3_column_double(r, 6)
                session.peakMemory = sqlite3_column_double(r, 7)
                session.energyWh = sqlite3_column_double(r, 8)
                session.diskBytes = sqlite3_column_double(r, 9)
                session.networkBytes = sqlite3_column_double(r, 10)
                return session
            }
        }
    }

    public func sessionSamples(_ id: Int64) -> [SessionSample] {
        queue.sync {
            query("SELECT ts, secs, cpu, mem, gpu, disk_r, disk_w, net_in, net_out, power, cpu_temp, pressure FROM session_samples WHERE session_id = \(id) ORDER BY ts") { r in
                SessionSample(date: Date(timeIntervalSince1970: sqlite3_column_double(r, 0)), seconds: sqlite3_column_double(r, 1),
                              cpu: sqlite3_column_double(r, 2), memory: sqlite3_column_double(r, 3), gpu: sqlite3_column_double(r, 4),
                              diskRead: sqlite3_column_double(r, 5), diskWrite: sqlite3_column_double(r, 6),
                              netIn: sqlite3_column_double(r, 7), netOut: sqlite3_column_double(r, 8),
                              power: sqlite3_column_type(r, 9) == SQLITE_NULL ? nil : sqlite3_column_double(r, 9),
                              cpuTemperature: sqlite3_column_type(r, 10) == SQLITE_NULL ? nil : sqlite3_column_double(r, 10),
                              pressure: Int(sqlite3_column_int(r, 11)))
            }
        }
    }

    public func sessionApps(_ id: Int64) -> [SessionApp] {
        queue.sync {
            query("SELECT app_id, name, cpu_avg, cpu_peak, mem_peak, energy_wh, disk, net, top_process FROM session_apps WHERE session_id = \(id) ORDER BY cpu_avg DESC") { r in
                SessionApp(id: Self.text(r, 0), name: Self.text(r, 1), averageCPU: sqlite3_column_double(r, 2), peakCPU: sqlite3_column_double(r, 3),
                           peakMemory: sqlite3_column_double(r, 4), energyWh: sqlite3_column_double(r, 5),
                           diskBytes: sqlite3_column_double(r, 6), networkBytes: sqlite3_column_double(r, 7),
                           topProcess: sqlite3_column_type(r, 8) == SQLITE_NULL ? nil : Self.text(r, 8))
            }
        }
    }

    public func renameSession(_ id: Int64, to name: String) {
        queue.sync {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "UPDATE sessions SET name = ? WHERE id = ?", -1, &statement, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(statement) }
            bindText(statement, 1, name)
            sqlite3_bind_int64(statement, 2, id)
            sqlite3_step(statement)
        }
    }

    public func deleteSession(_ id: Int64) {
        queue.sync {
            exec("DELETE FROM session_samples WHERE session_id = \(id)")
            exec("DELETE FROM session_apps WHERE session_id = \(id)")
            exec("DELETE FROM sessions WHERE id = \(id)")
        }
    }
}

/// CSV and JSON for a recorded session: plain numbers in SI units, one row per sample.
public enum SessionExport {
    public static func csv(_ samples: [SessionSample], started: Date) -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var lines = ["time,elapsed_s,cpu_percent,memory_bytes,gpu_percent,disk_read_Bps,disk_write_Bps,net_in_Bps,net_out_Bps,power_W,cpu_temp_C,memory_pressure"]
        for s in samples {
            let fields: [String] = [
                iso.string(from: s.date), String(format: "%.3f", s.date.timeIntervalSince(started)),
                String(format: "%.2f", s.cpu), String(format: "%.0f", s.memory), String(format: "%.2f", s.gpu),
                String(format: "%.0f", s.diskRead), String(format: "%.0f", s.diskWrite),
                String(format: "%.0f", s.netIn), String(format: "%.0f", s.netOut),
                s.power.map { String(format: "%.2f", $0) } ?? "", s.cpuTemperature.map { String(format: "%.1f", $0) } ?? "",
                String(s.pressure),
            ]
            lines.append(fields.joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    public static func json(_ session: RecordingSession, samples: [SessionSample], apps: [SessionApp]) -> Data {
        let iso = ISO8601DateFormatter()
        let payload: [String: Any] = [
            "name": session.name,
            "started": iso.string(from: session.started),
            "ended": session.ended.map { iso.string(from: $0) } as Any? ?? NSNull(),
            "duration_s": session.duration,
            "summary": ["average_cpu_percent": session.averageCPU, "peak_cpu_percent": session.peakCPU,
                        "peak_memory_bytes": session.peakMemory, "energy_Wh": session.energyWh,
                        "disk_bytes": session.diskBytes, "network_bytes": session.networkBytes],
            "apps": apps.map { ["name": $0.name, "id": $0.id, "average_cpu_percent": $0.averageCPU, "peak_cpu_percent": $0.peakCPU,
                                "peak_memory_bytes": $0.peakMemory, "energy_Wh": $0.energyWh, "disk_bytes": $0.diskBytes,
                                "network_bytes": $0.networkBytes, "top_process": $0.topProcess as Any? ?? NSNull()] },
            "samples": samples.map { s -> [String: Any] in
                ["time": iso.string(from: s.date), "elapsed_s": s.date.timeIntervalSince(session.started), "cpu_percent": s.cpu,
                 "memory_bytes": s.memory, "gpu_percent": s.gpu, "disk_read_Bps": s.diskRead, "disk_write_Bps": s.diskWrite,
                 "net_in_Bps": s.netIn, "net_out_Bps": s.netOut, "power_W": s.power as Any? ?? NSNull(),
                 "cpu_temp_C": s.cpuTemperature as Any? ?? NSNull(), "memory_pressure": s.pressure]
            },
        ]
        return (try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    }
}
