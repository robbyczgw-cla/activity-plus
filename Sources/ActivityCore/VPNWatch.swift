import Foundation

/// Notices when a VPN that was connected drops and stays down. Reads only the local list of VPN
/// services (`scutil --nc list`, the same as System Settings → VPN); nothing is sent anywhere.
public struct VPNWatch: Sendable {
    public struct Service: Sendable, Hashable {
        public let id: String
        public let name: String
        public let connected: Bool
    }

    /// When each VPN was last seen connected, and when it was first seen down after that.
    private var wasConnected: Set<String> = []
    private var downSince: [String: Date] = [:]
    private var reported: Set<String> = []
    /// A drop counts only after this long, so a reconnect or a quick switch stays quiet.
    public var grace: TimeInterval = 60

    public init() {}

    /// Feed the current list; returns the VPNs that just crossed the grace period while down.
    public mutating func update(_ services: [Service], now: Date = Date()) -> [Service] {
        var dropped: [Service] = []
        for service in services {
            if service.connected {
                wasConnected.insert(service.id)
                downSince[service.id] = nil
                reported.remove(service.id)
            } else if wasConnected.contains(service.id) {
                let since = downSince[service.id] ?? now
                downSince[service.id] = since
                if now.timeIntervalSince(since) >= grace, !reported.contains(service.id) {
                    reported.insert(service.id)
                    dropped.append(service)
                }
            }
        }
        return dropped
    }

    /// `* (Connected)  A1B2C3D4-… VPN (com.example.vpn) "Home VPN"  [VPN:…]`
    public static func parse(_ text: String) -> [Service] {
        text.components(separatedBy: "\n").compactMap { line in
            guard let open = line.firstIndex(of: "("), let close = line[open...].firstIndex(of: ")") else { return nil }
            let status = line[line.index(after: open)..<close]
            let rest = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
            guard let id = rest.split(separator: " ").first, id.count >= 32,
                  let firstQuote = rest.firstIndex(of: "\""),
                  let lastQuote = rest[rest.index(after: firstQuote)...].firstIndex(of: "\"")
            else { return nil }
            let name = String(rest[rest.index(after: firstQuote)..<lastQuote])
            return Service(id: String(id), name: name, connected: status == "Connected")
        }
    }

    public static func read() -> [Service] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/scutil")
        process.arguments = ["--nc", "list"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return parse(String(data: data, encoding: .utf8) ?? "")
    }
}
