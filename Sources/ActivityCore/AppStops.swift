import Foundation

/// A process that macOS ended on its own: killed for using too much memory (jetsam), for hanging,
/// for a broken code signature and so on. Read from RunningBoard's "termination reported by launchd
/// (namespace, code, signal)" lines in the unified log, which are readable without admin rights.
public struct AppStop: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable {
        case app           // a regular app
        case appService    // a helper (XPC service, web content…) running for an app
        case service       // a macOS or third-party background service
        case process       // a plain process
    }

    public enum Reason: Sendable, Hashable {
        /// The process went over the memory limit macOS gives it.
        case memoryLimit
        /// macOS ran low on memory and freed some by ending it.
        case memoryPressure
        case diskSpace
        case hang
        case codeSigning
        case privacy
        case securityRule
        case missingLibrary
        case other(namespace: Int, code: UInt64)
    }

    public let date: Date
    public let pid: Int32
    /// A readable name: the bundle id's or label's last part until the app layer resolves a real app name.
    public let name: String
    /// Bundle id (apps), service label, or executable name.
    public let identifier: String
    /// For helpers: the bundle id of the app they belong to.
    public let hostBundleID: String?
    public let kind: Kind
    /// The exit reason namespace and code the kernel recorded (OS_REASON_*).
    public let namespace: Int
    public let code: UInt64

    public var id: String { "\(Int(date.timeIntervalSince1970)):\(pid):\(namespace):\(code)" }

    public init(date: Date, pid: Int32, name: String, identifier: String, hostBundleID: String?, kind: Kind, namespace: Int, code: UInt64) {
        self.date = date; self.pid = pid; self.name = name; self.identifier = identifier
        self.hostBundleID = hostBundleID; self.kind = kind; self.namespace = namespace; self.code = code
    }

    public var reason: Reason { AppStops.reason(namespace: namespace, code: code) }

    /// True when the stop has to do with memory (shown as "for using too much memory").
    public var isMemory: Bool {
        switch reason {
        case .memoryLimit, .memoryPressure: true
        default: false
        }
    }

    /// "for using too much memory", "because it stopped responding"…
    public var reasonPhrase: String {
        switch reason {
        case .memoryLimit: String(localized: "for using too much memory")
        case .memoryPressure: String(localized: "because the Mac ran short of memory")
        case .diskSpace: String(localized: "because the disk was almost full")
        case .hang: String(localized: "because it stopped responding")
        case .codeSigning: String(localized: "because its code signature was not valid")
        case .privacy: String(localized: "for accessing private data without permission")
        case .securityRule: String(localized: "for breaking a system security rule")
        case .missingLibrary: String(localized: "because a part it needs is missing")
        case .other(let namespace, let code): String(localized: "for system reason \(namespace)/\(code)")
        }
    }

    /// A plain explanation and what helps.
    public var explanation: String {
        switch reason {
        case .memoryLimit:
            String(localized: "macOS gives every app and background service a memory limit. Going over it usually means a leak or a very large document, tab or project. Updating the app, or restarting it now and then, helps.")
        case .memoryPressure:
            String(localized: "The Mac as a whole ran out of memory, so macOS ended processes to keep it usable. Quitting apps you do not need, or closing tabs, prevents it.")
        case .diskSpace:
            String(localized: "With the disk almost full, macOS has no room for swap and ends processes. Free up space.")
        case .hang:
            String(localized: "It did not respond for so long that macOS ended it. An update often fixes it.")
        case .codeSigning:
            String(localized: "Its signature did not match, often after a damaged or half-finished update. Reinstalling it helps.")
        case .privacy:
            String(localized: "It tried to use something protected, like the camera or your files, without permission.")
        case .securityRule, .missingLibrary, .other:
            String(localized: "macOS ended it on purpose. If it keeps happening, update or reinstall the app.")
        }
    }
}

public enum AppStops {
    /// OS_REASON_* namespaces from xnu's sys/reason.h.
    enum Namespace {
        static let jetsam = 1, signal = 2, codeSigning = 3, hangTracer = 4, dyld = 6, tcc = 11
        static let runningBoard = 15, watchdog = 20, guardRule = 23, sandbox = 25, pac = 28
    }

    /// JETSAM_REASON_* codes from xnu's kern_memorystatus.h.
    enum Jetsam {
        static let highwater: UInt64 = 2, vnode: UInt64 = 3, pageShortage: UInt64 = 4, procThrashing: UInt64 = 5
        static let fcThrashing: UInt64 = 6, perProcessLimit: UInt64 = 7, diskSpace: UInt64 = 8, idleExit: UInt64 = 9
        static let zoneMap: UInt64 = 10, compressorThrashing: UInt64 = 11, compressorSpace: UInt64 = 12, lowSwap: UInt64 = 13
        static let sustainedPressure: UInt64 = 14, pageoutStarvation: UInt64 = 15, longIdleExit: UInt64 = 17
    }

    /// The predicate for `log show`: only RunningBoard's termination lines that are not a normal exit,
    /// a signal (quit or force quit by a person or another app) or RunningBoard's own housekeeping.
    public static let logPredicate = #"process == "runningboardd" AND eventMessage CONTAINS "termination reported by launchd (" AND NOT eventMessage CONTAINS "(0, 0, 0)" AND NOT eventMessage CONTAINS "launchd (2, " AND NOT eventMessage CONTAINS "launchd (15, ""#

    static func reason(namespace: Int, code: UInt64) -> AppStop.Reason {
        switch namespace {
        case Namespace.jetsam:
            switch code {
            case Jetsam.highwater, Jetsam.perProcessLimit: .memoryLimit
            case Jetsam.diskSpace: .diskSpace
            default: .memoryPressure
            }
        case Namespace.hangTracer, Namespace.watchdog: .hang
        case Namespace.codeSigning: .codeSigning
        case Namespace.tcc: .privacy
        case Namespace.guardRule, Namespace.sandbox, Namespace.pac: .securityRule
        case Namespace.dyld: .missingLibrary
        default: .other(namespace: namespace, code: code)
        }
    }

    /// Whether a stop is worth showing: ordinary exits, quits by signal, RunningBoard housekeeping and
    /// idle services macOS ends to tidy up are left out.
    static func isForced(namespace: Int, code: UInt64) -> Bool {
        switch namespace {
        case Namespace.jetsam: code != Jetsam.idleExit && code != Jetsam.longIdleExit && code != 0
        case Namespace.codeSigning, Namespace.hangTracer, Namespace.dyld, Namespace.tcc, Namespace.watchdog,
             Namespace.guardRule, Namespace.sandbox, Namespace.pac: true
        default: false
        }
    }

    private static let tupleRegex = try! NSRegularExpression(pattern: #"\] termination reported by launchd \((\d+), (\d+), (\d+)\)"#)
    private static let pidRegex = try! NSRegularExpression(pattern: #":(\d+)(?::\d+)?\] termination reported"#)

    /// Parses one RunningBoard message, e.g.
    /// `[app<application.com.example.Editor.1234.5678(501)>:812] termination reported by launchd (1, 7, 9)`.
    public static func parse(message: String, date: Date) -> AppStop? {
        let ns = NSRange(message.startIndex..., in: message)
        guard let tuple = tupleRegex.firstMatch(in: message, range: ns),
              let a = Range(tuple.range(at: 1), in: message), let b = Range(tuple.range(at: 2), in: message),
              let namespace = Int(message[a]), let code = UInt64(message[b]),
              isForced(namespace: namespace, code: code) else { return nil }
        let pid = pidRegex.firstMatch(in: message, range: ns).flatMap { Range($0.range(at: 1), in: message) }.flatMap { Int32(message[$0]) } ?? 0
        guard let identity = identity(of: message) else { return nil }
        return AppStop(date: date, pid: pid, name: identity.name, identifier: identity.identifier, hostBundleID: identity.host,
                       kind: identity.kind, namespace: namespace, code: code)
    }

    /// What the bracketed RunningBoard identity names: `app<…>`, `xpcservice<…([app<…>:pid])…>`, `osservice<…>`,
    /// `extension<…>` or `anon<…>`.
    static func identity(of message: String) -> (kind: AppStop.Kind, identifier: String, name: String, host: String?)? {
        guard message.hasPrefix("["), let open = message.firstIndex(of: "<") else { return nil }
        let type = message[message.index(after: message.startIndex)..<open]
        let rest = message[message.index(after: open)...]
        // The identifier runs up to the first "(", "[", "{" or ">".
        let identifier = String(rest.prefix { !"([{>".contains($0) })
        guard !identifier.isEmpty else { return nil }
        let host = rest.range(of: "[app<application.").map { range -> String in
            bundleID(fromApplication: String(rest[range.upperBound...].prefix { !"(>".contains($0) }))
        }
        switch type {
        case "app":
            let id = bundleID(fromApplication: identifier.hasPrefix("application.") ? String(identifier.dropFirst("application.".count)) : identifier)
            return (.app, id, shortName(id), nil)
        case "xpcservice", "extension":
            return (host == nil ? .service : .appService, identifier, shortName(identifier), host)
        case "osservice":
            return (.service, identifier, shortName(identifier), nil)
        default:
            return (.process, identifier, identifier, host)
        }
    }

    /// `com.example.Editor.30257551.30257607` → `com.example.Editor`: RunningBoard appends two instance numbers.
    static func bundleID(fromApplication text: String) -> String {
        var parts = text.split(separator: ".", omittingEmptySubsequences: false)
        var dropped = 0
        while dropped < 2, let last = parts.last, !last.isEmpty, last.allSatisfy(\.isNumber), parts.count > 1 {
            parts.removeLast()
            dropped += 1
        }
        return parts.joined(separator: ".")
    }

    /// `com.apple.WebKit.WebContent` → `WebContent`.
    public static func shortName(_ identifier: String) -> String {
        identifier.split(separator: ".").last.map(String.init) ?? identifier
    }

    /// Parses `log show --style ndjson` output. Unknown or ordinary lines are skipped.
    public static func parse(ndjson data: Data) -> [AppStop] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = DateFormatter()
        plain.locale = Locale(identifier: "en_US_POSIX")
        plain.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSSZ"
        var stops: [AppStop] = []
        for line in data.split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let message = object["eventMessage"] as? String,
                  let stamp = object["timestamp"] as? String,
                  let date = plain.date(from: stamp) ?? formatter.date(from: stamp),
                  let stop = parse(message: message, date: date) else { continue }
            stops.append(stop)
        }
        return stops
    }

    /// Reads the unified log since `start` (at most 24 hours back). Runs `log show` at background priority and
    /// gives up after `timeout`; returns nil when the log could not be read.
    public static func read(since start: Date, timeout: TimeInterval = 180) -> [AppStop]? {
        let from = max(start, Date().addingTimeInterval(-86_400))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ssZ"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = ["show", "--start", formatter.string(from: from), "--style", "ndjson", "--predicate", logPredicate]
        process.qualityOfService = .background
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + timeout, execute: deadline)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        deadline.cancel()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else { return nil }
        return parse(ndjson: data)
    }

    /// Stops grouped by app, most first: "stickersd ×5".
    public struct Group: Sendable, Identifiable {
        public let key: String
        public let name: String
        public let stops: [AppStop]
        public var id: String { key }
        public var latest: Date { stops.map(\.date).max() ?? .distantPast }
    }

    /// Groups by the app (or the app a helper belongs to) and reason; `name` resolves a bundle id to an app name.
    public static func grouped(_ stops: [AppStop], name: (AppStop) -> String) -> [Group] {
        let groups = Dictionary(grouping: stops) { stop in "\(stop.hostBundleID ?? stop.identifier)|\(stop.reasonPhrase)" }
        return groups.map { key, stops in Group(key: key, name: name(stops[0]), stops: stops.sorted { $0.date > $1.date }) }
            .sorted { ($0.stops.count, $0.latest) > ($1.stops.count, $1.latest) }
    }
}
