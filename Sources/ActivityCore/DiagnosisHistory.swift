import Foundation
import SQLite3

/// Slow moments and the apps macOS stopped, kept 30 days next to the rest of the history.
extension HistoryStore {
    func createDiagnosisTables() {
        exec("""
            CREATE TABLE IF NOT EXISTS slow_moments (
                start INTEGER NOT NULL, end INTEGER NOT NULL, severity INTEGER NOT NULL, causes TEXT NOT NULL)
            """)
        exec("CREATE INDEX IF NOT EXISTS slow_moments_start ON slow_moments(start)")
        exec("""
            CREATE TABLE IF NOT EXISTS app_stops (
                ts INTEGER NOT NULL, pid INTEGER NOT NULL, name TEXT NOT NULL, ident TEXT NOT NULL, host TEXT,
                kind TEXT NOT NULL, namespace INTEGER NOT NULL, code INTEGER NOT NULL,
                UNIQUE(ts, pid, namespace, code))
            """)
        exec("CREATE INDEX IF NOT EXISTS app_stops_ts ON app_stops(ts)")
    }

    func pruneDiagnosis(before cutoff: Int) {
        exec("DELETE FROM slow_moments WHERE end < \(cutoff)")
        exec("DELETE FROM app_stops WHERE ts < \(cutoff)")
    }

    // MARK: Slow moments

    public func recordSlowMoment(_ moment: SlowMoment) {
        guard let data = try? JSONEncoder().encode(moment.causes), let json = String(data: data, encoding: .utf8) else { return }
        queue.async { [self] in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "INSERT INTO slow_moments (start, end, severity, causes) VALUES (?,?,?,?)", -1, &statement, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int64(statement, 1, Int64(moment.start.timeIntervalSince1970))
            sqlite3_bind_int64(statement, 2, Int64(moment.end.timeIntervalSince1970.rounded(.up)))
            sqlite3_bind_int(statement, 3, Int32(moment.severity.rawValue))
            bindText(statement, 4, json)
            sqlite3_step(statement)
        }
    }

    /// Slow moments that ended after `start`, newest first.
    public func slowMoments(since start: Date, until end: Date = .distantFuture) -> [SlowMoment] {
        queue.sync {
            let to = end == .distantFuture ? Int64.max : Int64(end.timeIntervalSince1970)
            return query("SELECT start, end, severity, causes FROM slow_moments WHERE end >= \(Int64(start.timeIntervalSince1970)) AND start <= \(to) ORDER BY start DESC") { s in
                let causes = (try? JSONDecoder().decode([SlowMoment.Cause].self, from: Data(Self.text(s, 3).utf8))) ?? []
                return SlowMoment(start: Date(timeIntervalSince1970: sqlite3_column_double(s, 0)),
                                  end: Date(timeIntervalSince1970: sqlite3_column_double(s, 1)),
                                  severity: SlowMoment.Severity(rawValue: Int(sqlite3_column_int(s, 2))) ?? .noticeable,
                                  causes: causes)
            }
        }
    }

    // MARK: Apps macOS stopped

    /// Stores stops that are not known yet; the same stop read twice is kept once.
    public func recordAppStops(_ stops: [AppStop]) {
        guard !stops.isEmpty else { return }
        queue.async { [self] in
            exec("BEGIN")
            var statement: OpaquePointer?
            let sql = "INSERT OR IGNORE INTO app_stops (ts, pid, name, ident, host, kind, namespace, code) VALUES (?,?,?,?,?,?,?,?)"
            if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
                for stop in stops {
                    sqlite3_reset(statement)
                    sqlite3_bind_int64(statement, 1, Int64(stop.date.timeIntervalSince1970))
                    sqlite3_bind_int(statement, 2, stop.pid)
                    bindText(statement, 3, stop.name)
                    bindText(statement, 4, stop.identifier)
                    if let host = stop.hostBundleID { bindText(statement, 5, host) } else { sqlite3_bind_null(statement, 5) }
                    bindText(statement, 6, stop.kind.rawValue)
                    sqlite3_bind_int(statement, 7, Int32(stop.namespace))
                    sqlite3_bind_int64(statement, 8, Int64(stop.code))
                    sqlite3_step(statement)
                }
                sqlite3_finalize(statement)
            }
            exec("COMMIT")
        }
    }

    /// Stops since `start`, newest first.
    public func appStops(since start: Date, until end: Date = .distantFuture) -> [AppStop] {
        queue.sync {
            let to = end == .distantFuture ? Int64.max : Int64(end.timeIntervalSince1970)
            return query("SELECT ts, pid, name, ident, host, kind, namespace, code FROM app_stops WHERE ts >= \(Int64(start.timeIntervalSince1970)) AND ts <= \(to) ORDER BY ts DESC") { s in
                AppStop(date: Date(timeIntervalSince1970: sqlite3_column_double(s, 0)), pid: sqlite3_column_int(s, 1),
                        name: Self.text(s, 2), identifier: Self.text(s, 3),
                        hostBundleID: sqlite3_column_type(s, 4) == SQLITE_NULL ? nil : Self.text(s, 4),
                        kind: AppStop.Kind(rawValue: Self.text(s, 5)) ?? .service,
                        namespace: Int(sqlite3_column_int(s, 6)), code: UInt64(sqlite3_column_int64(s, 7)))
            }
        }
    }
}
