import Foundation

/// Time Machine as `tmutil` reports it: whether a backup runs, where backups go and when the last one finished.
public struct TimeMachineInfo: Sendable, Equatable {
    public struct Destination: Sendable, Equatable {
        public var name: String
        public var kind: String
        public var mountPoint: String?
        public init(name: String, kind: String, mountPoint: String? = nil) {
            (self.name, self.kind, self.mountPoint) = (name, kind, mountPoint)
        }
    }

    public struct Progress: Sendable, Equatable {
        public var running: Bool
        public var phase: String?
        /// 0...1, nil while macOS does not know yet (it reports -1).
        public var fraction: Double?
        public init(running: Bool, phase: String? = nil, fraction: Double? = nil) {
            (self.running, self.phase, self.fraction) = (running, phase, fraction)
        }
    }

    public var destinations: [Destination] = []
    public var progress = Progress(running: false)
    public var lastBackup: Date?
    /// The newest backup was found on the mounted destination (false: only the date macOS remembers).
    public var destinationReachable = false
    /// macOS refused to answer without Full Disk Access.
    public var needsFullDiskAccess = false

    public init() {}
}

public enum TimeMachine {
    /// Backups are named `2026-10-09-123456` (folder or `.backup` suffix) in local time.
    public static func backupDate(in text: String) -> Date? {
        guard let regex = try? NSRegularExpression(pattern: #"(\d{4})-(\d{2})-(\d{2})-(\d{2})(\d{2})(\d{2})"#) else { return nil }
        let ns = text as NSString
        // The last match: the path may contain the machine name first.
        guard let match = regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).last else { return nil }
        let parts = (1...6).compactMap { Int(ns.substring(with: match.range(at: $0))) }
        guard parts.count == 6 else { return nil }
        var components = DateComponents()
        (components.year, components.month, components.day) = (parts[0], parts[1], parts[2])
        (components.hour, components.minute, components.second) = (parts[3], parts[4], parts[5])
        return Calendar.current.date(from: components)
    }

    /// `tmutil latestbackup` prints the path of the newest backup, or an error such as "Failed to mount backup destination".
    public static func parseLatestBackup(_ text: String) -> Date? {
        let line = text.split(separator: "\n").first.map(String.init) ?? ""
        guard line.hasPrefix("/") else { return nil }
        return backupDate(in: line)
    }

    /// `tmutil status`: an old-style property list (`Running = 1; Percent = "0.42"; BackupPhase = Copying;`).
    public static func parseStatus(_ text: String) -> TimeMachineInfo.Progress {
        func value(_ key: String) -> String? {
            for raw in text.split(separator: "\n") {
                let line = raw.trimmingCharacters(in: .whitespaces)
                guard line.hasPrefix(key), let eq = line.firstIndex(of: "=") else { continue }
                guard line[line.startIndex..<eq].trimmingCharacters(in: .whitespaces) == key else { continue }
                return line[line.index(after: eq)...].trimmingCharacters(in: CharacterSet(charactersIn: " ;\""))
            }
            return nil
        }
        let running = value("Running") == "1"
        let percent = value("Percent").flatMap(Double.init)
        let fraction = percent.flatMap { $0 >= 0 ? min($0, 1) : nil }
        return TimeMachineInfo.Progress(running: running, phase: running ? value("BackupPhase") : nil, fraction: running ? fraction : nil)
    }

    /// `tmutil destinationinfo`: blocks of `Name : …` lines separated by a line of `=`.
    public static func parseDestinations(_ text: String) -> [TimeMachineInfo.Destination] {
        text.components(separatedBy: "====").compactMap { block in
            var fields: [String: String] = [:]
            for line in block.split(separator: "\n") {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let key = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces)
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if !key.isEmpty, fields[key] == nil { fields[key] = value }
            }
            guard let name = fields["Name"], !name.isEmpty else { return nil }
            return TimeMachineInfo.Destination(name: name, kind: fields["Kind"] ?? "", mountPoint: fields["Mount Point"])
        }
    }

    /// `LastBackupActivity` from the Time Machine preferences, e.g. "2025-10-21-134540".
    public static func parseActivity(_ text: String?) -> Date? {
        text.flatMap(backupDate(in:))
    }

    public static func needsFullDiskAccess(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("full disk access") || lower.contains("operation not permitted")
    }

    /// Whole days since `date`, rounded down.
    public static func daysSince(_ date: Date, now: Date = Date()) -> Int {
        max(0, Int(now.timeIntervalSince(date) / 86_400))
    }

    /// A destination is set up, no backup is running and the last one is at least `days` old.
    public static func isStale(_ info: TimeMachineInfo, days: Int = 7, now: Date = Date()) -> Bool {
        guard !info.destinations.isEmpty, !info.progress.running, let last = info.lastBackup else { return false }
        return daysSince(last, now: now) >= days
    }

    /// Reads everything. Slow (a few `tmutil` calls); call off the main thread.
    public static func read() -> TimeMachineInfo {
        var info = TimeMachineInfo()
        let status = ToolRunner.run("/usr/bin/tmutil", ["status"])
        let destinations = ToolRunner.run("/usr/bin/tmutil", ["destinationinfo"])
        if needsFullDiskAccess(status.output) || needsFullDiskAccess(destinations.output) {
            info.needsFullDiskAccess = true
            return info
        }
        info.progress = parseStatus(status.output)
        info.destinations = parseDestinations(destinations.output)
        guard !info.destinations.isEmpty else { return info }
        let latest = ToolRunner.run("/usr/bin/tmutil", ["latestbackup"])
        if needsFullDiskAccess(latest.output) {
            info.needsFullDiskAccess = true
            return info
        }
        if let date = parseLatestBackup(latest.output) {
            info.lastBackup = date
            info.destinationReachable = true
        } else {
            // Destination not connected: macOS still remembers when the last backup ran.
            let remembered = CFPreferencesCopyAppValue("LastBackupActivity" as CFString, "com.apple.TimeMachine" as CFString) as? String
            info.lastBackup = parseActivity(remembered)
        }
        return info
    }
}
