import Foundation
import SQLite3

/// 30 days of history in one small SQLite file.
///
/// Live samples arrive every few seconds; storing them raw would be ~1 GB a month.
/// Instead `record` averages them and writes one system row per minute and one row per
/// noticeable app every five minutes (≈10 MB for 30 days).
public final class HistoryStore: @unchecked Sendable {
    public enum Range: String, CaseIterable, Identifiable, Sendable {
        case hours12 = "12 h", hours24 = "24 h", days7 = "7 d", days30 = "30 d"
        public var id: String { rawValue }
        public var seconds: TimeInterval {
            switch self {
            case .hours12: 12 * 3600
            case .hours24: 24 * 3600
            case .days7: 7 * 86_400
            case .days30: 30 * 86_400
            }
        }
        /// Bucket size so every range draws ~150–300 points.
        var bucket: Int {
            switch self {
            case .hours12: 180
            case .hours24: 300
            case .days7: 1800
            case .days30: 7200
            }
        }
    }

    public struct SystemPoint: Sendable, Identifiable {
        public let date: Date
        public let cpu: Double
        public let memory: Double
        public let gpu: Double
        public let diskRead: Double
        public let diskWrite: Double
        public let netIn: Double
        public let netOut: Double
        public let battery: Double?
        public let power: Double?
        public var id: Date { date }
    }

    public struct AppTotal: Sendable, Identifiable {
        public let appID: String
        public let name: String
        public let bundlePath: String?
        public let averageCPU: Double
        public let averageMemory: Double
        public let peakMemory: Double
        public let diskBytes: Double
        public let networkBytes: Double
        public let energyWh: Double
        public let gpuAverage: Double
        public var id: String { appID }
    }

    public struct Totals: Sendable {
        public var diskWritten: Double = 0
        public var diskRead: Double = 0
        public var received: Double = 0
        public var sent: Double = 0
        public var energyWh: Double = 0
        public var averageCPU: Double = 0
        public init() {}
        init(diskWritten: Double, diskRead: Double, received: Double, sent: Double, energyWh: Double, averageCPU: Double) {
            (self.diskWritten, self.diskRead, self.received, self.sent, self.energyWh, self.averageCPU) =
                (diskWritten, diskRead, received, sent, energyWh, averageCPU)
        }
    }

    var db: OpaquePointer?   // internal: Sessions.swift shares the connection
    let queue = DispatchQueue(label: "at.hifiteam.activityplus.history")
    /// Per-app totals of running recording sessions, keyed by session id (touched only on `queue`).
    var sessionAppTotals: [Int64: [String: SessionAppAccumulator]] = [:]
    public let url: URL

    // Accumulators (touched only on `queue`)
    private var minute = Accumulator()
    private var appWindow: [String: AppAccumulator] = [:]
    private var appWindowStart = Date()

    public init(url: URL? = nil) {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Activity+", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        self.url = url ?? folder.appendingPathComponent("history.sqlite")
        queue.sync { open() }
    }

    deinit { sqlite3_close(db) }

    // MARK: Writing

    /// Longer gaps between samples mean the Mac slept (or the app hung): the first sample after
    /// such a gap must not be stretched over the whole gap, so it is left out.
    static let maxSampleGap: TimeInterval = 120

    public func record(_ snapshot: SystemSnapshot) {
        guard snapshot.interval > 0, snapshot.interval <= Self.maxSampleGap else { return }
        queue.async { [self] in
            minute.add(snapshot)
            windowSampleCount += 1
            if let battery = snapshot.battery, !battery.isPluggedIn { windowOnBattery += 1 }
            for app in snapshot.apps where app.cpuPercent > 0.2 || app.memory > 50_000_000
                || app.diskWriteRate + app.diskReadRate > 10_000 || app.netInRate + app.netOutRate > 5_000 || app.powerWatts > 0.05
            {
                appWindow[app.id, default: AppAccumulator(name: app.name, bundlePath: app.bundlePath)].add(app, interval: snapshot.interval)
            }

            let now = snapshot.date
            if now.timeIntervalSince(minute.start) >= 60 {
                writeSystemRow(minute, at: now)
                minute = Accumulator()
            }
            if now.timeIntervalSince(appWindowStart) >= 300 {
                writeAppRows(at: now)
                appWindow = [:]
                appWindowStart = now
            }
        }
    }

    /// Write whatever is buffered (called when quitting).
    public func flush() {
        queue.sync {
            if minute.count > 0 { writeSystemRow(minute, at: Date()) }
            if !appWindow.isEmpty { writeAppRows(at: Date()) }
            minute = Accumulator()
            appWindow = [:]
        }
    }

    public func prune(olderThan days: Int = 30) {
        queue.async { [self] in
            let cutoff = Int(Date().timeIntervalSince1970) - days * 86_400
            exec("DELETE FROM system WHERE ts < \(cutoff)")
            exec("DELETE FROM apps WHERE ts < \(cutoff)")
            exec("DELETE FROM pings WHERE ts < \(cutoff)")
            exec("DELETE FROM app_procs WHERE ts < \(cutoff)")
        }
    }

    // MARK: Reading

    public func systemSeries(_ range: Range, until end: Date = Date()) -> [SystemPoint] {
        queue.sync {
            let from = Int(end.timeIntervalSince1970 - range.seconds)
            let bucket = range.bucket
            let sql = """
                SELECT (ts / \(bucket)) * \(bucket) AS b, AVG(cpu), AVG(mem), AVG(gpu), AVG(disk_r), AVG(disk_w),
                       AVG(net_in), AVG(net_out), AVG(battery), AVG(power)
                FROM system WHERE ts >= \(from) GROUP BY b ORDER BY b
                """
            return query(sql) { s in
                SystemPoint(
                    date: Date(timeIntervalSince1970: sqlite3_column_double(s, 0)),
                    cpu: sqlite3_column_double(s, 1), memory: sqlite3_column_double(s, 2),
                    gpu: sqlite3_column_double(s, 3), diskRead: sqlite3_column_double(s, 4),
                    diskWrite: sqlite3_column_double(s, 5), netIn: sqlite3_column_double(s, 6),
                    netOut: sqlite3_column_double(s, 7),
                    battery: sqlite3_column_type(s, 8) == SQLITE_NULL ? nil : sqlite3_column_double(s, 8),
                    power: sqlite3_column_type(s, 9) == SQLITE_NULL ? nil : sqlite3_column_double(s, 9)
                )
            }
        }
    }

    public func topApps(_ range: Range, until end: Date = Date()) -> [AppTotal] {
        topApps(from: end.addingTimeInterval(-range.seconds), to: end)
    }

    /// Per-app totals for any period. `onBatteryOnly` keeps only 5-minute windows spent on battery.
    public func topApps(from start: Date, to end: Date, onBatteryOnly: Bool = false) -> [AppTotal] {
        queue.sync {
            let from = Int(start.timeIntervalSince1970), to = Int(end.timeIntervalSince1970)
            let filter = "ts >= \(from) AND ts <= \(to)" + (onBatteryOnly ? " AND on_battery = 1" : "")
            // Averages are over every recorded 5-minute window (an app that ran 1 of 24 hours counts 1/24).
            let recorded = query("SELECT COUNT(DISTINCT ts) FROM apps WHERE \(filter)") { sqlite3_column_int64($0, 0) }.first ?? 1
            let windows = max(1, recorded)
            let sql = """
                SELECT app_id, MAX(name), MAX(bundle), SUM(cpu) / \(windows), SUM(mem) / \(windows), MAX(mem_peak),
                       SUM(disk), SUM(net), SUM(energy), SUM(gpu) / \(windows)
                FROM apps WHERE \(filter) GROUP BY app_id
                """
            return query(sql) { s in
                AppTotal(
                    appID: Self.text(s, 0), name: Self.text(s, 1),
                    bundlePath: sqlite3_column_type(s, 2) == SQLITE_NULL ? nil : Self.text(s, 2),
                    averageCPU: sqlite3_column_double(s, 3), averageMemory: sqlite3_column_double(s, 4),
                    peakMemory: sqlite3_column_double(s, 5), diskBytes: sqlite3_column_double(s, 6),
                    networkBytes: sqlite3_column_double(s, 7), energyWh: sqlite3_column_double(s, 8),
                    gpuAverage: sqlite3_column_double(s, 9)
                )
            }
        }
    }

    public struct AppPoint: Sendable, Identifiable {
        public let date: Date
        public let cpu: Double
        public let memory: Double
        /// nil for rows written before v0.2.
        public let processes: Int?
        public var id: Date { date }
    }

    /// One app's 5-minute averages, oldest first (for its history chart and leak detection).
    public func appSeries(_ appID: String, since start: Date) -> [AppPoint] {
        queue.sync {
            var statement: OpaquePointer?
            let sql = "SELECT ts, cpu, mem, procs FROM apps WHERE app_id = ? AND ts >= ? ORDER BY ts"
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return [] }
            defer { sqlite3_finalize(statement) }
            bindText(statement, 1, appID)
            sqlite3_bind_int64(statement, 2, Int64(start.timeIntervalSince1970))
            var points: [AppPoint] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                points.append(AppPoint(date: Date(timeIntervalSince1970: sqlite3_column_double(statement, 0)),
                                       cpu: sqlite3_column_double(statement, 1), memory: sqlite3_column_double(statement, 2),
                                       processes: sqlite3_column_type(statement, 3) == SQLITE_NULL ? nil : Int(sqlite3_column_int(statement, 3))))
            }
            return points
        }
    }

    /// What is normal for each app: averages over the windows in which it was running.
    public struct Baseline: Sendable {
        public let appID: String
        public let averageCPU: Double
        public let averageMemory: Double
        public let typicalPeakMemory: Double
        public let windows: Int
    }

    public func baselines(from start: Date, to end: Date) -> [String: Baseline] {
        queue.sync {
            let sql = """
                SELECT app_id, AVG(cpu), AVG(mem), AVG(mem_peak), COUNT(*) FROM apps
                WHERE ts >= \(Int(start.timeIntervalSince1970)) AND ts <= \(Int(end.timeIntervalSince1970)) GROUP BY app_id
                """
            let rows = query(sql) { s in
                Baseline(appID: Self.text(s, 0), averageCPU: sqlite3_column_double(s, 1), averageMemory: sqlite3_column_double(s, 2),
                         typicalPeakMemory: sqlite3_column_double(s, 3), windows: Int(sqlite3_column_int64(s, 4)))
            }
            return Dictionary(rows.map { ($0.appID, $0) }, uniquingKeysWith: { a, _ in a })
        }
    }

    public struct BatteryDrain: Sendable {
        public var hoursOnBattery: Double = 0
        public var percentUsed: Double = 0
        public var energyWh: Double = 0
        public init() {}
    }

    /// How much battery was used while unplugged since `start`, from the per-minute system rows.
    public func batteryDrain(since start: Date) -> BatteryDrain {
        queue.sync {
            let rows = query("SELECT ts, secs, battery, power FROM system WHERE on_battery = 1 AND ts >= \(Int(start.timeIntervalSince1970)) ORDER BY ts") { s in
                (ts: sqlite3_column_int64(s, 0), secs: sqlite3_column_double(s, 1),
                 battery: sqlite3_column_type(s, 2) == SQLITE_NULL ? nil : sqlite3_column_double(s, 2),
                 power: sqlite3_column_type(s, 3) == SQLITE_NULL ? 0 : sqlite3_column_double(s, 3))
            }
            var drain = BatteryDrain()
            var previous: (ts: Int64, battery: Double?)?
            for row in rows {
                drain.hoursOnBattery += row.secs / 3600
                drain.energyWh += row.power * row.secs / 3600
                // Sum the drops between consecutive minutes; a gap (sleep, charging) starts a new run.
                if let prev = previous, let before = prev.battery, let now = row.battery, row.ts - prev.ts <= 180, now < before {
                    drain.percentUsed += before - now
                }
                previous = (row.ts, row.battery)
            }
            return drain
        }
    }

    /// Byte and energy totals between two dates (for week-over-week comparisons).
    public func totals(from start: Date, to end: Date) -> Totals {
        queue.sync {
            let sql = "SELECT SUM(disk_w * secs), SUM(disk_r * secs), SUM(net_in * secs), SUM(net_out * secs), SUM(power * secs) / 3600, AVG(cpu) FROM system WHERE ts >= \(Int(start.timeIntervalSince1970)) AND ts <= \(Int(end.timeIntervalSince1970))"
            return query(sql) { s in
                Totals(diskWritten: sqlite3_column_double(s, 0), diskRead: sqlite3_column_double(s, 1),
                       received: sqlite3_column_double(s, 2), sent: sqlite3_column_double(s, 3),
                       energyWh: sqlite3_column_double(s, 4), averageCPU: sqlite3_column_double(s, 5))
            }.first ?? Totals()
        }
    }

    /// When the oldest stored sample is from (for "not enough history yet").
    public var oldestSample: Date? {
        queue.sync {
            query("SELECT MIN(ts) FROM system") { s in
                sqlite3_column_type(s, 0) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(s, 0))
            }.first ?? nil
        }
    }

    /// Byte and energy totals, e.g. "written today" or "downloaded in the last 7 days".
    public func totals(since start: Date) -> Totals {
        queue.sync {
            let from = Int(start.timeIntervalSince1970)
            let sql = "SELECT SUM(disk_w * secs), SUM(disk_r * secs), SUM(net_in * secs), SUM(net_out * secs), SUM(power * secs) / 3600, AVG(cpu) FROM system WHERE ts >= \(from)"
            var totals = query(sql) { s in
                Totals(diskWritten: sqlite3_column_double(s, 0), diskRead: sqlite3_column_double(s, 1),
                       received: sqlite3_column_double(s, 2), sent: sqlite3_column_double(s, 3),
                       energyWh: sqlite3_column_double(s, 4), averageCPU: sqlite3_column_double(s, 5))
            }.first ?? Totals()
            // Include the minute that has not been written yet.
            if minute.count > 0, minute.start >= start {
                totals.diskWritten += minute.diskWrite / Double(minute.count) * minute.seconds
                totals.diskRead += minute.diskRead / Double(minute.count) * minute.seconds
                totals.received += minute.netIn / Double(minute.count) * minute.seconds
                totals.sent += minute.netOut / Double(minute.count) * minute.seconds
            }
            return totals
        }
    }

    public var fileSize: UInt64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
    }

    public func eraseAll() {
        queue.sync {
            exec("DELETE FROM system")
            exec("DELETE FROM apps")
            exec("VACUUM")
        }
    }

    // MARK: SQLite plumbing

    private func open() {
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { return }
        exec("PRAGMA journal_mode = WAL")
        exec("PRAGMA synchronous = NORMAL")
        exec("""
            CREATE TABLE IF NOT EXISTS system (
                ts INTEGER NOT NULL, secs REAL NOT NULL, cpu REAL, mem REAL, gpu REAL,
                disk_r REAL, disk_w REAL, net_in REAL, net_out REAL, battery REAL, power REAL)
            """)
        exec("CREATE INDEX IF NOT EXISTS system_ts ON system(ts)")
        createSessionTables()
        createPingTable()
        createProcessTable()
        exec("""
            CREATE TABLE IF NOT EXISTS apps (
                ts INTEGER NOT NULL, app_id TEXT NOT NULL, name TEXT, bundle TEXT,
                cpu REAL, mem REAL, mem_peak REAL, disk REAL, net REAL, energy REAL, gpu REAL)
            """)
        exec("CREATE INDEX IF NOT EXISTS apps_ts ON apps(ts)")
        // v0.2: remember whether the Mac ran on battery (fails harmlessly when the column exists).
        exec("ALTER TABLE system ADD COLUMN on_battery INTEGER DEFAULT 0")
        exec("ALTER TABLE apps ADD COLUMN on_battery INTEGER DEFAULT 0")
        // v0.2: how many processes the app had, so growth from new processes is not mistaken for a leak.
        exec("ALTER TABLE apps ADD COLUMN procs INTEGER")
        exec("CREATE INDEX IF NOT EXISTS apps_app ON apps(app_id, ts)")
    }

    private func writeSystemRow(_ a: Accumulator, at date: Date) {
        guard a.count > 0, a.seconds > 0 else { return }
        let n = a.seconds   // time-weighted sums ÷ covered seconds = averages
        var statement: OpaquePointer?
        let sql = "INSERT INTO system (ts, secs, cpu, mem, gpu, disk_r, disk_w, net_in, net_out, battery, power, on_battery) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Int64(date.timeIntervalSince1970))
        sqlite3_bind_double(statement, 2, a.seconds)
        sqlite3_bind_double(statement, 3, a.cpu / n)
        sqlite3_bind_double(statement, 4, a.memory / n)
        sqlite3_bind_double(statement, 5, a.gpu / n)
        sqlite3_bind_double(statement, 6, a.diskRead / n)
        sqlite3_bind_double(statement, 7, a.diskWrite / n)
        sqlite3_bind_double(statement, 8, a.netIn / n)
        sqlite3_bind_double(statement, 9, a.netOut / n)
        if a.batteryCount > 0 { sqlite3_bind_double(statement, 10, a.battery / Double(a.batteryCount)) } else { sqlite3_bind_null(statement, 10) }
        if a.powerCount > 0 { sqlite3_bind_double(statement, 11, a.power / Double(a.powerCount)) } else { sqlite3_bind_null(statement, 11) }
        sqlite3_bind_int(statement, 12, a.onBattery * 2 > a.count ? 1 : 0)
        sqlite3_step(statement)
    }

    private func writeAppRows(at date: Date) {
        exec("BEGIN")
        let sql = "INSERT INTO apps (ts, app_id, name, bundle, cpu, mem, mem_peak, disk, net, energy, gpu, on_battery, procs) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)"
        let onBattery: Int32 = windowOnBattery * 2 > windowSampleCount ? 1 : 0
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { exec("COMMIT"); return }
        let windowSamples = Double(max(1, minuteSamplesPerWindow))
        for (id, a) in appWindow {
            sqlite3_reset(statement)
            sqlite3_bind_int64(statement, 1, Int64(date.timeIntervalSince1970))
            bindText(statement, 2, id)
            bindText(statement, 3, a.name)
            if let bundle = a.bundlePath { bindText(statement, 4, bundle) } else { sqlite3_bind_null(statement, 4) }
            // Divide by all samples in the window, not only those where the app was noticeable.
            sqlite3_bind_double(statement, 5, a.cpu / windowSamples)
            sqlite3_bind_double(statement, 6, a.memory / windowSamples)
            sqlite3_bind_double(statement, 7, a.memoryPeak)
            sqlite3_bind_double(statement, 8, a.diskBytes)
            sqlite3_bind_double(statement, 9, a.netBytes)
            sqlite3_bind_double(statement, 10, a.energyJoules / 3600)
            sqlite3_bind_double(statement, 11, a.gpu / windowSamples)
            sqlite3_bind_int(statement, 12, onBattery)
            sqlite3_bind_int(statement, 13, Int32(a.processCount))
            sqlite3_step(statement)
        }
        for (id, a) in appWindow where !a.processes.isEmpty {
            writeProcessRows(appID: id, processes: Array(a.processes.values), windowSamples: windowSamples, at: Int64(date.timeIntervalSince1970))
        }
        sqlite3_finalize(statement)
        exec("COMMIT")
        windowSampleCount = 0
        windowOnBattery = 0
    }

    private var windowSampleCount = 0
    private var windowOnBattery = 0
    private var minuteSamplesPerWindow: Int { max(windowSampleCount, appWindow.values.map(\.count).max() ?? 1) }

    func exec(_ sql: String) {
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    func query<T>(_ sql: String, _ row: (OpaquePointer) -> T) -> [T] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return [] }
        defer { sqlite3_finalize(statement) }
        var rows: [T] = []
        while sqlite3_step(statement) == SQLITE_ROW { rows.append(row(statement)) }
        return rows
    }

    func bindText(_ statement: OpaquePointer?, _ index: Int32, _ text: String) {
        sqlite3_bind_text(statement, index, text, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }

    static func text(_ s: OpaquePointer, _ column: Int32) -> String {
        sqlite3_column_text(s, column).map { String(cString: $0) } ?? ""
    }
}

private struct Accumulator {
    var start = Date()
    var count = 0
    var seconds: Double = 0
    var cpu = 0.0, memory = 0.0, gpu = 0.0
    var diskRead = 0.0, diskWrite = 0.0, netIn = 0.0, netOut = 0.0
    var battery = 0.0, batteryCount = 0
    var power = 0.0, powerCount = 0
    var onBattery = 0

    /// Values are weighted by the time each sample covers: foreground (1–2 s) and background
    /// (5–15 s) samples mix within one minute, and a plain mean would count them equally.
    mutating func add(_ s: SystemSnapshot) {
        let dt = s.interval
        count += 1
        seconds += dt
        cpu += s.cpu.total * dt
        memory += Double(s.memory.used) * dt
        gpu += (s.gpu?.utilization ?? 0) * dt
        diskRead += s.disk.readRate * dt
        diskWrite += s.disk.writeRate * dt
        netIn += s.network.inRate * dt
        netOut += s.network.outRate * dt
        if let b = s.battery {
            battery += b.percent
            batteryCount += 1
            if let p = b.systemPower { power += p; powerCount += 1 }
            if !b.isPluggedIn { onBattery += 1 }
        }
    }
}

private struct AppAccumulator {
    let name: String
    let bundlePath: String?
    var count = 0
    var cpu = 0.0, memory = 0.0, memoryPeak = 0.0, gpu = 0.0
    var diskBytes = 0.0, netBytes = 0.0, energyJoules = 0.0
    var processCount = 0
    /// Per process (pid + start time), for tracing the app's numbers back to a child process.
    var processes: [String: ProcessAccumulator] = [:]

    mutating func add(_ app: AppGroup, interval: TimeInterval) {
        count += 1
        processCount = app.processes.count
        if app.processes.count > 1 {
            for p in app.processes where p.cpuPercent > 0.1 || p.memory > 20_000_000 {
                let key = "\(p.pid)@\(p.startTime.timeIntervalSince1970)"
                var acc = processes[key] ?? ProcessAccumulator(pid: p.pid, start: p.startTime, name: p.name)
                acc.cpu += p.cpuPercent
                acc.memoryPeak = max(acc.memoryPeak, Double(p.memory))
                acc.diskBytes += (p.diskReadRate + p.diskWriteRate) * interval
                acc.netBytes += (p.netInRate + p.netOutRate) * interval
                processes[key] = acc
            }
        }
        cpu += app.cpuPercent
        memory += Double(app.memory)
        memoryPeak = max(memoryPeak, Double(app.memory))
        gpu += app.gpuPercent
        diskBytes += (app.diskReadRate + app.diskWriteRate) * interval
        netBytes += (app.netInRate + app.netOutRate) * interval
        energyJoules += app.powerWatts * interval
    }
}
