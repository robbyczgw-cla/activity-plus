import Foundation
import IOKit

public struct SleepBlocker: Sendable, Identifiable, Hashable {
    public let id: String
    public let pid: Int32
    public let processName: String
    public let kind: String
    public let reason: String
    public let since: Date?
    public let preventsDisplaySleep: Bool
}

public struct PowerEvent: Sendable, Identifiable, Hashable {
    public enum Kind: String, Sendable { case sleep, wake, darkWake }
    public let id: String
    public let date: Date
    public let kind: Kind
    public let reason: String
    public let batteryPercent: Int?
}

public enum SleepAnalyzer {
    private static let dateFormat = "yyyy-MM-dd HH:mm:ss Z"
    private static let eventLineRegex = try? NSRegularExpression(pattern: #"^.{25}\s+(Sleep|Wake|DarkWake)\s"#)

    public static func blockers() -> [SleepBlocker] {
        guard let output = run("/usr/bin/pmset", ["-g", "assertions"]) else { return [] }
        var inOwners = false
        var result: [SleepBlocker] = []
        let pattern = #"^\s*pid\s+(\d+)\(([^)]+)\):\s+\[[^]]+\]\s+(\S+)\s+([A-Za-z0-9_]+)\s+named:\s+\"([^\"]*)\""#
        let regex = try? NSRegularExpression(pattern: pattern)
        for line in output.components(separatedBy: .newlines) {
            if line.contains("Listed by owning process:") { inOwners = true; continue }
            if line.hasPrefix("Kernel Assertions:") || line.hasPrefix("PM ASL") { inOwners = false }
            guard inOwners, let regex,
                  let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let pidRange = Range(match.range(at: 1), in: line), let pid = Int32(line[pidRange]),
                  let nameRange = Range(match.range(at: 2), in: line),
                  let ageRange = Range(match.range(at: 3), in: line),
                  let kindRange = Range(match.range(at: 4), in: line),
                  let reasonRange = Range(match.range(at: 5), in: line) else { continue }
            let kind = String(line[kindRange])
            guard kind.contains("Sleep") else { continue }
            let age = parseAge(String(line[ageRange]))
            let since = age.map { Date().addingTimeInterval(-$0) }
            let reason = String(line[reasonRange])
            let id = "\(pid):\(kind):\(reason)"
            result.append(SleepBlocker(id: id, pid: pid, processName: String(line[nameRange]), kind: kind,
                                       reason: reason, since: since,
                                       preventsDisplaySleep: kind.localizedCaseInsensitiveContains("DisplaySleep")))
        }
        return result
    }

    public static func events(since: Date) -> [PowerEvent] {
        let cutoff = max(since, Date().addingTimeInterval(-7 * 24 * 60 * 60))
        guard let lines = streamedPowerLines() else { return [] }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = dateFormat
        let batteryRE = try? NSRegularExpression(pattern: #"Using BATT \(Charge:\s*(\d+)%\)"#, options: [.caseInsensitive])
        var result: [PowerEvent] = []
        for line in lines {
            guard let eventKind = loggedKind(line) else { continue }
            guard line.count >= 25 else { continue }
            let dateText = String(line.prefix(25)).trimmingCharacters(in: .whitespaces)
            guard let date = formatter.date(from: dateText), date >= cutoff else { continue }
            let kind: PowerEvent.Kind
            kind = eventKind
            let reason: String
            if let range = line.range(of: "due to ") {
                reason = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                    .components(separatedBy: "\t").first ?? "Unknown"
            } else if let marker = line.range(of: "\t") {
                reason = String(line[marker.upperBound...]).trimmingCharacters(in: .whitespaces)
                    .components(separatedBy: "Using ").first?.trimmingCharacters(in: .whitespaces) ?? "Unknown"
            } else if line.contains(" Wake ") || line.contains(" DarkWake ") {
                reason = line.components(separatedBy: "\t").dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespaces)
            } else { reason = "Sleep" }
            let ns = NSRange(line.startIndex..., in: line)
            let percent = batteryRE?.firstMatch(in: line, range: ns).flatMap { match -> Int? in
                guard let r = Range(match.range(at: 1), in: line) else { return nil }
                return Int(line[r])
            }
            let id = "\(Int(date.timeIntervalSince1970)):\(kind.rawValue):\(reason)"
            result.append(PowerEvent(id: id, date: date, kind: kind, reason: reason, batteryPercent: percent))
        }
        return result.sorted { $0.date < $1.date }
    }

    public static func explain(_ reason: String) -> String {
        let value = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = value.lowercased()
        if lower.contains("lidopen") || lower.contains("lid open") { return "The lid was opened." }
        if lower.contains("powerbutton") || lower.contains("power button") { return "The power button was pressed." }
        if lower.contains("rtc") || lower.contains("maintenance") || lower.contains("alarm") { return "The Mac woke for a scheduled timer or maintenance task." }
        if lower.contains("network") || lower.contains("tcpkeepalive") || lower.contains("magic packet") { return "Network activity or a network wake request woke the Mac." }
        if lower.contains("usb") { return "A USB device or USB activity woke the Mac." }
        if lower.contains("bluetooth") || lower.contains("btstack") { return "Bluetooth activity, often a paired input device, woke the Mac." }
        if lower.hasPrefix("ec.") || lower.contains("ec.") { return "The embedded controller reported the wake reason: \(value)." }
        if lower.contains("user") || lower.contains("keyboard") || lower.contains("trackpad") { return "User input woke the Mac." }
        return value
    }

    private static func run(_ path: String, _ arguments: [String]) -> String? {
        let process = Process(); process.executableURL = URL(fileURLWithPath: path); process.arguments = arguments
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = Pipe()
        do { try process.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit(); return String(data: data, encoding: .utf8) }
        catch { return nil }
    }

    // Consume pmset's large output in chunks; retain only candidate event lines.
    private static func streamedPowerLines() -> [String]? {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset"); process.arguments = ["-g", "log"]
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        var pending = Data(), matches: [String] = []
        let handle = pipe.fileHandleForReading
        while true {
            let chunk = handle.readData(ofLength: 64 * 1024)
            if chunk.isEmpty { break }
            pending.append(chunk)
            while let newline = pending.firstIndex(of: 10) {
                let lineData = pending.prefix(upTo: newline)
                if let line = String(data: lineData, encoding: .utf8), loggedKind(line) != nil { matches.append(line) }
                pending.removeSubrange(...newline)
            }
        }
        process.waitUntilExit()
        if !pending.isEmpty, let line = String(data: pending, encoding: .utf8), loggedKind(line) != nil { matches.append(line) }
        return matches
    }

    private static func loggedKind(_ line: String) -> PowerEvent.Kind? {
        guard let regex = eventLineRegex,
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let range = Range(match.range(at: 1), in: line) else { return nil }
        switch line[range] {
        case "Sleep": return .sleep
        case "Wake": return .wake
        default: return .darkWake
        }
    }

    private static func parseAge(_ text: String) -> TimeInterval? {
        let pieces = text.split(separator: ":").compactMap { Double($0) }
        guard pieces.count == 3 else { return nil }
        return pieces[0] * 3600 + pieces[1] * 60 + pieces[2]
    }
}
