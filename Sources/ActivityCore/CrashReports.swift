import Foundation

/// One diagnostic report macOS wrote about an app: a crash, a freeze (hang) or a resource warning.
public struct CrashReport: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable { case crash, hang, resource }

    public var id: String { path }
    public let path: String
    public let appName: String
    public let bundleID: String?
    public let appVersion: String?
    public let date: Date
    public let kind: Kind
    /// Mach exception ("EXC_BAD_ACCESS"), signal ("SIGABRT") and the termination namespace/indicator, as the report has them.
    public let exceptionType: String?
    public let signal: String?
    public let terminationNamespace: String?
    public let terminationIndicator: String?

    public init(path: String, appName: String, bundleID: String?, appVersion: String? = nil, date: Date, kind: Kind,
                exceptionType: String? = nil, signal: String? = nil, terminationNamespace: String? = nil, terminationIndicator: String? = nil) {
        self.path = path; self.appName = appName; self.bundleID = bundleID; self.appVersion = appVersion; self.date = date; self.kind = kind
        self.exceptionType = exceptionType; self.signal = signal
        self.terminationNamespace = terminationNamespace; self.terminationIndicator = terminationIndicator
    }

    /// The app a helper process belongs to: "Google Chrome Helper (Renderer)" and "Google Chrome" are one app.
    public var appKey: String { CrashReportParser.baseName(appName) }

    /// What went wrong, in plain words (the technical code first, then what it means).
    public var reason: String {
        switch kind {
        case .hang: return String(localized: "The app stopped responding")
        case .resource: return terminationIndicator ?? String(localized: "It used more resources than macOS allows in the background")
        case .crash:
            return CrashReportParser.plainReason(exceptionType: exceptionType, signal: signal,
                                                 namespace: terminationNamespace, indicator: terminationIndicator)
        }
    }
}

/// One app's crash history over the last weeks.
public struct CrashSummary: Sendable, Hashable, Identifiable {
    public var id: String { appName }
    public let appName: String
    public let bundleID: String?
    public let crashes7: Int
    public let crashes30: Int
    public let hangs7: Int
    public let hangs30: Int
    /// Resource warnings (".diag"): too much CPU or disk writing in the background. Not counted as crashes.
    public let resource30: Int
    public let lastDate: Date
    public let lastKind: CrashReport.Kind
    public let lastReason: String
    /// The newest report, for "Show report".
    public let latestReportPath: String
}

public enum CrashReportParser {
    static let reportExtensions: Set<String> = ["ips", "crash", "hang", "spin", "diag"]

    // MARK: Parsing

    /// Reads one report. Returns nil for files that are not about an app crashing or freezing
    /// (simulated "user fault" reports, system panics, unreadable files).
    public static func parse(path: String, text: String, modified: Date) -> CrashReport? {
        let fileName = (path as NSString).lastPathComponent
        let ext = (fileName as NSString).pathExtension.lowercased()
        if fileName.hasPrefix("ExcUserFault") { return nil }
        if ext == "ips" { return parseIPS(path: path, fileName: fileName, text: text, modified: modified) }
        if ["crash", "hang", "spin", "diag"].contains(ext) { return parseText(path: path, fileName: fileName, ext: ext, text: text, modified: modified) }
        return nil
    }

    private static func parseIPS(path: String, fileName: String, text: String, modified: Date) -> CrashReport? {
        let lines = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
        guard let first = lines.first,
              let header = (try? JSONSerialization.jsonObject(with: Data(first.utf8))) as? [String: Any] else { return nil }
        // The body is the second JSON document; very small reports have only the header.
        var body: [String: Any] = [:]
        if lines.count > 1, let parsed = (try? JSONSerialization.jsonObject(with: Data(lines[1].utf8))) as? [String: Any] { body = parsed }
        if (header["is_simulated"] as? Int) == 1 || (body["isSimulated"] as? Bool) == true { return nil }

        let bundleInfo = body["bundleInfo"] as? [String: Any]
        var name = (header["app_name"] as? String) ?? (header["name"] as? String) ?? (body["procName"] as? String) ?? ""
        var bundleID = (header["bundleID"] as? String) ?? (bundleInfo?["CFBundleIdentifier"] as? String)
        let version = (header["app_version"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (bundleInfo?["CFBundleShortVersionString"] as? String)
        let date = parseDate(header["timestamp"] as? String) ?? parseDate(body["captureTime"] as? String) ?? modified

        // Memory pressure kills are written as "JetsamEvent" reports about the whole system; the app that was killed is the largest process.
        if fileName.hasPrefix("JetsamEvent") {
            guard let largest = body["largestProcess"] as? String, !largest.isEmpty else { return nil }
            return CrashReport(path: path, appName: largest, bundleID: nil, appVersion: nil, date: date, kind: .crash,
                               exceptionType: nil, signal: nil, terminationNamespace: "JETSAM", terminationIndicator: "Jetsam")
        }

        let exception = body["exception"] as? [String: Any]
        let termination = body["termination"] as? [String: Any]
        let lowerName = fileName.lowercased()
        let kind: CrashReport.Kind
        if exception != nil { kind = .crash }
        else if lowerName.contains("hang") || lowerName.contains("spin") { kind = .hang }
        else if lowerName.contains("resource") || lowerName.contains("diskwrites") || lowerName.contains("wakeups") { kind = .resource }
        else { return nil }
        if name.isEmpty { name = fileName.components(separatedBy: "-20").first ?? fileName }
        if bundleID?.isEmpty == true { bundleID = nil }
        return CrashReport(path: path, appName: name, bundleID: bundleID, appVersion: version, date: date, kind: kind,
                           exceptionType: exception?["type"] as? String, signal: exception?["signal"] as? String,
                           terminationNamespace: termination?["namespace"] as? String, terminationIndicator: termination?["indicator"] as? String)
    }

    /// The text formats: ".crash" (older macOS), ".hang", ".spin" and ".diag" share "Key:   value" lines.
    private static func parseText(path: String, fileName: String, ext: String, text: String, modified: Date) -> CrashReport? {
        func value(_ key: String) -> String? {
            for line in text.split(separator: "\n", maxSplits: 400, omittingEmptySubsequences: true).prefix(120) where line.hasPrefix(key + ":") {
                let v = line.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)
                if !v.isEmpty { return v }
            }
            return nil
        }
        var name = value("Process") ?? value("Command") ?? ""
        if let bracket = name.range(of: " [") { name = String(name[..<bracket.lowerBound]) }
        if name.isEmpty { name = fileName.components(separatedBy: "_20").first ?? fileName.components(separatedBy: "-20").first ?? fileName }
        let date = parseDate(value("Date/Time")) ?? modified
        let kind: CrashReport.Kind
        switch ext {
        case "crash": kind = .crash
        case "hang", "spin": kind = .hang
        default:
            // A ".diag" is a resource warning, unless it says the app froze.
            kind = (value("Event")?.lowercased().contains("hang") == true) ? .hang : .resource
        }
        var exceptionType: String?, signal: String?
        if let raw = value("Exception Type") {
            let parts = raw.split(separator: " ", maxSplits: 1).map(String.init)
            exceptionType = parts.first
            if parts.count > 1 { signal = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "()")) }
        }
        var namespace: String?, indicator: String?
        if let raw = value("Termination Reason") {
            // "Namespace SIGNAL, Code 11 Segmentation fault: 11"
            if let r = raw.range(of: "Namespace ") {
                namespace = String(raw[r.upperBound...].prefix { $0 != "," && $0 != " " })
            }
            if let c = raw.range(of: "Code ") {
                let rest = raw[c.upperBound...].drop { $0 != " " }.trimmingCharacters(in: .whitespaces)
                if !rest.isEmpty { indicator = rest }
            }
        }
        if kind == .resource { indicator = value("Event").map { String(localized: "Resource warning: \($0)") } }
        return CrashReport(path: path, appName: name, bundleID: value("Identifier"), appVersion: value("Version"), date: date, kind: kind,
                           exceptionType: exceptionType, signal: signal, terminationNamespace: namespace, terminationIndicator: indicator)
    }

    /// "2026-10-08 13:55:48.00 +0200", "2026-10-04 19:48:30.879 +0200" or "2018-01-01 10:00:00 +0100".
    static func parseDate(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 19 else { return nil }
        let datePart = String(trimmed.prefix(19))
        let tail = trimmed.dropFirst(19).drop { $0 != " " }.trimmingCharacters(in: .whitespaces)
        if tail.count == 5, tail.first == "+" || tail.first == "-" {
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
            return formatter.date(from: datePart + " " + tail)
        }
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: datePart)
    }

    /// "Google Chrome Helper (Renderer)" → "Google Chrome".
    static func baseName(_ name: String) -> String {
        if let r = name.range(of: " Helper") { return String(name[..<r.lowerBound]) }
        return name
    }

    // MARK: Plain words

    public static func plainReason(exceptionType: String?, signal: String?, namespace: String?, indicator: String?) -> String {
        let ns = namespace?.uppercased() ?? ""
        let ind = indicator?.lowercased() ?? ""
        if ns == "JETSAM" || ind.contains("jetsam") || ind.contains("memory limit") {
            return String(localized: "Killed for using too much memory (jetsam)")
        }
        if ns == "CODESIGNING" { return String(localized: "Blocked because its code signature is not valid") }
        if ns == "WATCHDOG" || ind.contains("watchdog") { return String(localized: "Stopped because it took too long to start or answer (watchdog)") }
        if ns == "DYLD" { return String(localized: "Could not load a library it needs") }
        if ns == "TCC" { return String(localized: "Tried to use private data without permission") }
        switch exceptionType {
        case "EXC_BAD_ACCESS": return String(localized: "EXC_BAD_ACCESS — the app read memory it shouldn't")
        case "EXC_BAD_INSTRUCTION": return String(localized: "EXC_BAD_INSTRUCTION — the app ran into an instruction that is not valid, often a failed internal check")
        case "EXC_BREAKPOINT": return String(localized: "EXC_BREAKPOINT — the app stopped itself after an internal check failed")
        case "EXC_ARITHMETIC": return String(localized: "EXC_ARITHMETIC — the app did an invalid calculation, such as dividing by zero")
        case "EXC_RESOURCE": return String(localized: "EXC_RESOURCE — the app used more CPU, memory or disk than macOS allows")
        case "EXC_GUARD": return String(localized: "EXC_GUARD — the app broke a system rule about files or ports")
        case "EXC_CRASH":
            switch signal {
            case "SIGABRT": return String(localized: "SIGABRT — the app stopped itself after an error it could not handle")
            case "SIGKILL": return String(localized: "SIGKILL — macOS or another process ended it by force")
            case "SIGQUIT": return String(localized: "SIGQUIT — the app was told to quit and wrote a report")
            default: return String(localized: "EXC_CRASH — the app was ended after an unhandled error")
            }
        default:
            if let exceptionType { return exceptionType }
            if let signal { return signal }
            return String(localized: "The report does not say why")
        }
    }
}

public enum CrashReports {
    public static var defaultDirectories: [String] {
        [FileManager.default.homeDirectoryForCurrentUser.path + "/Library/Logs/DiagnosticReports", "/Library/Logs/DiagnosticReports"]
    }

    /// Reads the reports of the last `days` days. Folders that cannot be read are skipped silently.
    public static func scan(directories: [String] = defaultDirectories, now: Date = Date(), days: Int = 30) -> [CrashReport] {
        let fm = FileManager.default
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        var reports: [CrashReport] = []
        for directory in directories {
            guard let names = try? fm.contentsOfDirectory(atPath: directory) else { continue }
            for name in names where CrashReportParser.reportExtensions.contains((name as NSString).pathExtension.lowercased()) {
                let path = directory + "/" + name
                guard let attributes = try? fm.attributesOfItem(atPath: path),
                      let modified = attributes[.modificationDate] as? Date, modified >= cutoff,
                      (attributes[.size] as? Int ?? 0) < 16_000_000,
                      let data = fm.contents(atPath: path) else { continue }
                if let report = CrashReportParser.parse(path: path, text: String(decoding: data, as: UTF8.self), modified: modified), report.date >= cutoff {
                    reports.append(report)
                }
            }
        }
        return reports
    }

    /// Reports of one app and kind written within seconds of each other (a browser and its helpers going down together,
    /// or a crash written twice) are one incident. The newest report of each incident stands for it.
    public static func incidents(_ reports: [CrashReport], mergeWithin gap: TimeInterval = 10) -> [CrashReport] {
        var result: [CrashReport] = []
        let groups = Dictionary(grouping: reports) { "\($0.appKey)|\($0.kind.rawValue)" }
        for (_, group) in groups {
            let sorted = group.sorted { $0.date < $1.date }
            var last: CrashReport?
            for report in sorted {
                if let previous = last, report.date.timeIntervalSince(previous.date) <= gap {
                    result.removeLast()
                }
                result.append(report)
                last = report
            }
        }
        return result.sorted { $0.date > $1.date }
    }

    /// Per app: how often it crashed or froze in the last 7 and 30 days. Apps with only resource warnings are left out.
    public static func summarize(_ reports: [CrashReport], now: Date = Date()) -> [CrashSummary] {
        let since7 = now.addingTimeInterval(-7 * 86_400), since30 = now.addingTimeInterval(-30 * 86_400)
        let events = incidents(reports.filter { $0.date >= since30 && $0.date <= now.addingTimeInterval(3600) })
        var summaries: [CrashSummary] = []
        for (app, group) in Dictionary(grouping: events, by: \.appKey) {
            let crashes = group.filter { $0.kind == .crash }, hangs = group.filter { $0.kind == .hang }
            guard !crashes.isEmpty || !hangs.isEmpty else { continue }
            let newest = (crashes + hangs).max { $0.date < $1.date }!
            summaries.append(CrashSummary(
                appName: app, bundleID: group.compactMap(\.bundleID).first,
                crashes7: crashes.filter { $0.date >= since7 }.count, crashes30: crashes.count,
                hangs7: hangs.filter { $0.date >= since7 }.count, hangs30: hangs.count,
                resource30: group.filter { $0.kind == .resource }.count,
                lastDate: newest.date, lastKind: newest.kind, lastReason: newest.reason, latestReportPath: newest.path))
        }
        return summaries.sorted {
            let a = $0.crashes7 * 2 + $0.hangs7, b = $1.crashes7 * 2 + $1.hangs7
            return a != b ? a > b : $0.lastDate > $1.lastDate
        }
    }
}
