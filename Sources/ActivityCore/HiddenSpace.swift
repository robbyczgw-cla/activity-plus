import Foundation

/// Space that Finder's numbers don't explain: APFS snapshots (local Time Machine backups, macOS
/// update leftovers) and purgeable space macOS frees on its own when it needs room.
public enum HiddenSpace {
    public struct Snapshot: Sendable, Hashable, Identifiable {
        public enum Kind: Sendable { case timeMachine, macOSUpdate, other }
        public let name: String
        public let kind: Kind
        public let purgeable: Bool
        /// Taken-at time for Time Machine snapshots (their name carries it).
        public let date: Date?
        public var id: String { name }
    }

    public struct Summary: Sendable {
        public let snapshots: [Snapshot]
        /// Free space counting what macOS can purge, minus plain free space.
        public let purgeableBytes: UInt64
    }

    public static func read(volume: URL = URL(fileURLWithPath: "/")) -> Summary {
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        let values = try? volume.resourceValues(forKeys: keys)
        let plain = UInt64(values?.volumeAvailableCapacity ?? 0)
        let important = UInt64(values?.volumeAvailableCapacityForImportantUsage ?? 0)
        return Summary(snapshots: snapshots(parse: run("/usr/sbin/diskutil", ["apfs", "listSnapshots", volume.path])),
                       purgeableBytes: important > plain ? important - plain : 0)
    }

    /// Parses `diskutil apfs listSnapshots /`: blocks with "Name:" and "Purgeable:" lines.
    public static func snapshots(parse text: String) -> [Snapshot] {
        var result: [Snapshot] = []
        var name: String?
        func flush(purgeable: Bool) {
            guard let current = name else { return }
            result.append(Snapshot(name: current, kind: kind(current), purgeable: purgeable, date: date(current)))
            name = nil
        }
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: CharacterSet(charactersIn: "|+- ").union(.whitespaces))
            if line.hasPrefix("Name:") {
                flush(purgeable: false)
                name = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("Purgeable:") {
                flush(purgeable: line.lowercased().contains("yes"))
            }
        }
        flush(purgeable: false)
        return result
    }

    static func kind(_ name: String) -> Snapshot.Kind {
        if name.hasPrefix("com.apple.TimeMachine.") { return .timeMachine }
        if name.hasPrefix("com.apple.os.update-") { return .macOSUpdate }
        return .other
    }

    /// "com.apple.TimeMachine.2026-10-07-123456.local" → that moment.
    static func date(_ name: String) -> Date? {
        guard name.hasPrefix("com.apple.TimeMachine.") else { return nil }
        let stamp = name.dropFirst("com.apple.TimeMachine.".count).prefix(17)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter.date(from: String(stamp))
    }

    private static func run(_ path: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
