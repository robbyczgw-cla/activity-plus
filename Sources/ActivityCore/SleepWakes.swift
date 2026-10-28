import Foundation

/// Who wakes the Mac while it sleeps: dark wakes from `pmset -g log`, each with its reason, the process that
/// asked for a scheduled wake, and the processes that held the Mac awake during it.
public enum SleepWakes {
    public enum Cause: String, Sendable, CaseIterable, Hashable {
        case backgroundTask, maintenance, timer
        case networkPacket, keepAlive, wifiFound, wifiChange, network
        case bluetooth, usb, power, lid, user, notification, unknown

        public var title: String {
            switch self {
            case .backgroundTask: String(localized: "Scheduled background tasks (Power Nap)")
            case .maintenance: String(localized: "Network upkeep")
            case .timer: String(localized: "A timer")
            case .networkPacket: String(localized: "Network traffic for this Mac")
            case .keepAlive: String(localized: "A kept-alive connection stopped answering")
            case .wifiFound: String(localized: "A known Wi-Fi network came in range")
            case .wifiChange: String(localized: "The Wi-Fi connection dropped")
            case .network: String(localized: "Wi-Fi or network")
            case .bluetooth: String(localized: "A Bluetooth device")
            case .usb: String(localized: "A USB device")
            case .power: String(localized: "Power adapter or cable plugged in or out")
            case .lid: String(localized: "The lid")
            case .user: String(localized: "Keyboard, trackpad or mouse")
            case .notification: String(localized: "A system notification")
            case .unknown: String(localized: "Another reason")
            }
        }

        /// What it means, in plain words.
        public var explanation: String {
            switch self {
            case .backgroundTask: String(localized: "macOS wakes for a few seconds to run background work: iCloud, Mail, Photos, Spotlight and updates. Each wake is short and cheap.")
            case .maintenance: String(localized: "About every two hours the Mac wakes to tell the network it can still be reached (Bonjour sleep proxy) and to renew its address.")
            case .timer: String(localized: "An app or macOS asked to be woken at a set time.")
            case .networkPacket: String(localized: "Wi-Fi received something for this Mac, for example a push notification, another device looking for shared folders or AirPlay, or Find My.")
            case .keepAlive: String(localized: "While asleep the Wi-Fi chip keeps connections to Apple's servers alive; when one stops answering, the Mac wakes to repair it.")
            case .wifiFound: String(localized: "The Mac noticed a saved Wi-Fi network and woke to join it. Harmless.")
            case .wifiChange: String(localized: "The Wi-Fi connection was lost and the Mac woke to deal with it. A weak signal or a router that restarts at night causes this.")
            case .network: String(localized: "The Wi-Fi or network chip woke the Mac.")
            case .bluetooth: String(localized: "A paired keyboard, mouse or headphones sent something.")
            case .usb: String(localized: "A connected USB device or hub sent a wake signal.")
            case .power: String(localized: "Plugging or unplugging power wakes the Mac briefly. Normal.")
            case .lid: String(localized: "The lid was opened or closed.")
            case .user: String(localized: "Someone pressed a key or touched the trackpad or mouse.")
            case .notification: String(localized: "macOS woke to deliver or handle a notification.")
            case .unknown: String(localized: "The power log names a hardware reason that Activity+ does not know.")
            }
        }

        /// What helps, when something does; nil when there is nothing to do.
        public var advice: String? {
            switch self {
            case .backgroundTask: String(localized: "Turning off Power Nap (Battery settings, Options) reduces them.")
            case .maintenance, .networkPacket, .keepAlive:
                String(localized: "Set \"Wake for network access\" to \"Only on power adapter\" or \"Never\" (Battery settings, Options). Find My and shared folders then reach the Mac less while it sleeps.")
            case .wifiChange: String(localized: "Moving closer to the router, or a router that does not restart at night, helps.")
            case .bluetooth: String(localized: "Switch off Bluetooth devices at night, or stop them from waking the Mac in Bluetooth settings.")
            case .usb: String(localized: "Unplug USB devices or hubs at night, or try another hub.")
            case .timer, .wifiFound, .network, .power, .lid, .user, .notification, .unknown: nil
            }
        }
    }

    /// One entry of a "Wake Requests" line: who asked to wake the Mac, and when.
    public struct Request: Sendable, Hashable {
        public let process: String
        public let kind: String
        public let wakeAt: Date
        public let info: String?
        /// Marked with * in the log: the request the next wake was set for.
        public let chosen: Bool

        /// A short label: the background task for dasd, otherwise the process.
        public var label: String {
            if process == "dasd", let info, let task = info.split(separator: ":").last, task.count > 2 {
                return "dasd (\(task))"
            }
            return process
        }
    }

    public struct Wake: Sendable, Identifiable, Hashable {
        public let date: Date
        /// How long the Mac stayed awake, when the log says.
        public let duration: TimeInterval?
        public let rawReason: String
        public let cause: Cause
        /// For scheduled wakes: who asked for it.
        public let requester: Request?
        /// Processes that took a power assertion during the wake, by how many they took.
        public let holders: [String: Int]
        public let batteryPercent: Int?
        public var id: Date { date }
        public var end: Date { date.addingTimeInterval(max(duration ?? 5, 1)) }
    }

    public struct Night: Sendable, Identifiable {
        /// Midnight of the evening the night began (nights run noon to noon).
        public let evening: Date
        public let wakes: [Wake]
        /// Time spent asleep in this night, from the log.
        public let asleep: TimeInterval
        public var id: Date { evening }
    }

    // MARK: Parsing

    static let typeColumn = 26   // after "yyyy-MM-dd HH:mm:ss +zzzz "

    /// The kind of a pmset line, from the column after the date.
    static func lineType(_ line: Substring) -> String? {
        guard line.count > typeColumn + 4, line.first?.isNumber == true else { return nil }
        let rest = line.dropFirst(typeColumn)
        guard let tab = rest.firstIndex(of: "\t") else { return nil }
        return rest[..<tab].trimmingCharacters(in: .whitespaces)
    }

    /// Lines worth keeping while streaming the large log.
    public static func isRelevant(_ line: Substring) -> Bool {
        switch lineType(line) {
        case "DarkWake", "Wake", "Sleep", "Wake Requests": true
        case "Assertions": line.contains(") Created ")
        default: false
        }
    }

    private static func dateFormatter() -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return f
    }

    private static let requestRegex = try! NSRegularExpression(
        pattern: #"\[(\*?)process=(\S+) request=(\S+) deltaSecs=\d+ wakeAt=(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d)(?: info="([^"]*)")?"#)
    private static let assertionRegex = try! NSRegularExpression(pattern: #"PID \d+\(([^)]+)\) Created (\w+) "#)
    private static let secondsRegex = try! NSRegularExpression(pattern: #"(\d+) secs\s*$"#)
    private static let batteryRegex = try! NSRegularExpression(pattern: #"\(Charge:\s*(\d+)%\)"#, options: [.caseInsensitive])

    private static func capture(_ regex: NSRegularExpression, _ text: String, _ group: Int = 1) -> String? {
        guard let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(m.range(at: group), in: text) else { return nil }
        return String(text[r])
    }

    /// Classifies the text after "due to".
    public static func cause(of reason: String) -> Cause {
        let r = reason.lowercased()
        if r.contains("rtc/sleepservice") || r.contains("sleepservice") { return .backgroundTask }
        if r.contains("rtc/maintenance") || r.contains("maintenance") { return .maintenance }
        if r.contains("rtc") || r.contains("alarm") { return .timer }
        if r.contains("e_rx_ip_packet") || r.contains("magic packet") { return .networkPacket }
        if r.contains("e_tko") || r.contains("tcpkeepalive") { return .keepAlive }
        if r.contains("e_pfn_net_found") { return .wifiFound }
        if r.contains("e_connection_loss") || r.contains("e_disassoc") || r.contains("e_deauth") || r.contains("e_link") { return .wifiChange }
        if r.contains("bluetooth") || r.contains("btstack") { return .bluetooth }
        if r.contains("acattach") || r.contains("acdetach") || r.contains("usb-c_plug") { return .power }
        if r.contains("usb") || r.contains("xhc") { return .usb }
        if r.contains("lid") { return .lid }
        if r.contains("wifibt") || r.contains("arpt") || r.contains("network") || r.contains("en0") || r.contains("wlan") { return .network }
        if r.contains("hid") || r.contains("useractivity") || r.contains("keyboard") || r.contains("powerbutton") { return .user }
        if r.contains("notification") { return .notification }
        return .unknown
    }

    /// Dark wakes since `since`, oldest first, and the time spent asleep per night.
    public static func parse(lines: [Substring], since: Date) -> (wakes: [Wake], sleeps: [(date: Date, seconds: TimeInterval)]) {
        let formatter = dateFormatter()
        var wakes: [Wake] = []
        var sleeps: [(date: Date, seconds: TimeInterval)] = []
        var lastRequests: [Request] = []
        // Assertions are matched to wakes afterwards; keep them with their dates.
        var assertions: [(date: Date, process: String)] = []
        var pending: [(date: Date, duration: TimeInterval?, reason: String, requests: [Request], battery: Int?)] = []

        for line in lines {
            guard let type = lineType(line), let date = formatter.date(from: String(line.prefix(25))) else { continue }
            let text = String(line.dropFirst(typeColumn))
            switch type {
            case "Wake Requests":
                lastRequests = requests(in: text, zone: zone(of: line))
            case "Assertions":
                guard date >= since.addingTimeInterval(-60), let process = capture(assertionRegex, text), process != "powerd" else { continue }
                assertions.append((date, process))
            case "Sleep":
                if date >= since, let seconds = capture(secondsRegex, text).flatMap(Double.init) { sleeps.append((date, seconds)) }
            case "DarkWake":
                guard date >= since else { continue }
                let reason = text.range(of: "due to ").map { String(text[$0.upperBound...]) }
                    .map { $0.components(separatedBy: " Using ").first ?? $0 }?
                    .trimmingCharacters(in: .whitespaces) ?? ""
                pending.append((date, capture(secondsRegex, text).flatMap(Double.init), reason, lastRequests,
                                capture(batteryRegex, text).flatMap { Int($0) }))
            default:
                continue
            }
        }

        for p in pending {
            let cause = cause(of: p.reason)
            let requester = [.backgroundTask, .maintenance, .timer].contains(cause) ? Self.requester(for: p.date, in: p.requests) : nil
            let from = p.date.addingTimeInterval(-10), to = p.date.addingTimeInterval(max(p.duration ?? 5, 1) + 1)
            var holders: [String: Int] = [:]
            for a in assertions where a.date >= from && a.date <= to { holders[a.process, default: 0] += 1 }
            wakes.append(Wake(date: p.date, duration: p.duration, rawReason: p.reason, cause: cause, requester: requester,
                              holders: holders, batteryPercent: p.battery))
        }
        return (wakes.sorted { $0.date < $1.date }, sleeps)
    }

    /// The UTC offset of a log line ("+0100"); the wake times in a "Wake Requests" line are in that zone.
    static func zone(of line: Substring) -> TimeZone? {
        let text = line.dropFirst(20).prefix(5)
        guard text.count == 5, let sign = text.first, sign == "+" || sign == "-",
              let hours = Int(text.dropFirst().prefix(2)), let minutes = Int(text.suffix(2)) else { return nil }
        return TimeZone(secondsFromGMT: (sign == "-" ? -1 : 1) * (hours * 3600 + minutes * 60))
    }

    static func requests(in text: String, zone: TimeZone?) -> [Request] {
        let dateOnly = DateFormatter()
        dateOnly.locale = Locale(identifier: "en_US_POSIX")
        dateOnly.dateFormat = "yyyy-MM-dd HH:mm:ss"
        dateOnly.timeZone = zone ?? .current
        return requestRegex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { m in
            func group(_ i: Int) -> String? { Range(m.range(at: i), in: text).map { String(text[$0]) } }
            guard let process = group(2), let kind = group(3), let at = group(4).flatMap(dateOnly.date(from:)) else { return nil }
            return Request(process: process, kind: kind, wakeAt: at, info: group(5), chosen: group(1) == "*")
        }
    }

    /// The request a scheduled wake was set for: the starred one if it is due around then, otherwise the one due closest.
    static func requester(for date: Date, in requests: [Request]) -> Request? {
        let near = requests.filter { abs($0.wakeAt.timeIntervalSince(date)) <= 90 }
        return near.first(where: \.chosen) ?? near.min { abs($0.wakeAt.timeIntervalSince(date)) < abs($1.wakeAt.timeIntervalSince(date)) }
    }

    /// Groups wakes into nights, noon to noon, newest first.
    public static func nights(_ wakes: [Wake], sleeps: [(date: Date, seconds: TimeInterval)], calendar: Calendar = .current) -> [Night] {
        func key(_ date: Date) -> Date { calendar.startOfDay(for: date.addingTimeInterval(-12 * 3600)) }
        let byNight = Dictionary(grouping: wakes) { key($0.date) }
        let asleep = Dictionary(grouping: sleeps) { key($0.date) }.mapValues { $0.reduce(0) { $0 + $1.seconds } }
        let keys = Set(byNight.keys).union(asleep.keys)
        return keys.map { Night(evening: $0, wakes: byNight[$0] ?? [], asleep: asleep[$0] ?? 0) }.sorted { $0.evening > $1.evening }
    }

    /// How often each process appeared during the wakes (requester or assertion holder), most first.
    public static func processes(in wakes: [Wake]) -> [(name: String, wakes: Int)] {
        var counts: [String: Int] = [:]
        for wake in wakes {
            var names = Set(wake.holders.keys)
            if let requester = wake.requester { names.insert(requester.label) }
            for name in names { counts[name, default: 0] += 1 }
        }
        return counts.map { ($0.key, $0.value) }.sorted { ($0.wakes, $1.name) > ($1.wakes, $0.name) }
    }

    /// Apps that were busy right after the wakes, from the history's 5-minute app windows (see HistoryStore's apps table).
    /// A window counts for a wake when it is the first one written after the wake and before the next one, because
    /// Activity+ writes the window only when it samples again.
    public static func busyAfter(_ wakes: [Wake], windows: [FanSpinUps.AppWindow], ignoring: Set<String> = [],
                                 minimumCPU: Double = 5) -> [(name: String, wakes: Int, averageCPU: Double)] {
        let sorted = wakes.sorted { $0.date < $1.date }
        let ordered = windows.sorted { $0.end < $1.end }
        var tally: [String: (wakes: Int, cpu: Double)] = [:]
        for (index, wake) in sorted.enumerated() {
            let next = index + 1 < sorted.count ? sorted[index + 1].date : wake.date.addingTimeInterval(1800)
            let limit = min(next.addingTimeInterval(120), wake.date.addingTimeInterval(1800))
            guard let window = ordered.first(where: { $0.end > wake.end && $0.end <= limit }) else { continue }
            for app in window.apps where app.cpu >= minimumCPU && !ignoring.contains(app.name) {
                let old = tally[app.name] ?? (0, 0)
                tally[app.name] = (old.wakes + 1, old.cpu + app.cpu)
            }
        }
        return tally.map { ($0.key, $0.value.wakes, $0.value.cpu / Double($0.value.wakes)) }
            .sorted { ($0.wakes, $0.averageCPU) > ($1.wakes, $1.averageCPU) }
    }

    /// What a process that keeps showing up during wakes is, for the common macOS ones.
    public static func describe(_ process: String) -> String? {
        let name = process.hasPrefix("dasd") ? "dasd" : process
        switch name {
        case "dasd": return String(localized: "macOS background task scheduler")
        case "cloudd", "bird": return String(localized: "iCloud")
        case "cloudtelemetryd": return String(localized: "iCloud diagnostics")
        case "mDNSResponder": return String(localized: "network discovery (Bonjour)")
        case "apsd": return String(localized: "push notifications")
        case "nsurlsessiond": return String(localized: "background downloads")
        case "PowerUIAgent": return String(localized: "battery charging management")
        case "backupd", "backupd-helper": return String(localized: "Time Machine")
        case "softwareupdated": return String(localized: "software updates")
        case "mds", "mds_stores", "mdworker", "mdworker_shared": return String(localized: "Spotlight")
        case "powerd": return String(localized: "power management")
        case "locationd": return String(localized: "location services")
        case "searchpartyd": return String(localized: "Find My")
        case "nfcd": return String(localized: "Apple Pay and NFC")
        default: return nil
        }
    }

    // MARK: Reading

    /// Streams `pmset -g log` (it is large) and keeps only the lines this needs.
    public static func readLog() -> [Substring]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g", "log"]
        process.qualityOfService = .utility
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        var pending = Data(), kept: [Substring] = []
        let handle = pipe.fileHandleForReading
        func take(_ data: Data) {
            guard let text = String(data: data, encoding: .utf8) else { return }
            let line = Substring(text)
            if isRelevant(line) { kept.append(line) }
        }
        while true {
            let chunk = handle.readData(ofLength: 256 * 1024)
            if chunk.isEmpty { break }
            pending.append(chunk)
            var start = pending.startIndex
            while let newline = pending[start...].firstIndex(of: 10) {
                take(pending[start..<newline])
                start = pending.index(after: newline)
            }
            pending.removeSubrange(pending.startIndex..<start)
        }
        if !pending.isEmpty { take(pending) }
        process.waitUntilExit()
        return kept
    }
}
