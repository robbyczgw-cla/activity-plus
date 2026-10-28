import Foundation

/// Another computer on "Other Macs": an Activity+ Mac that shares its summary, or any server running
/// Prometheus node_exporter. Stored in the defaults; a Mac's token lives in the Keychain, keyed by `id`.
public struct RemoteMachine: Codable, Sendable, Identifiable, Hashable {
    public enum Kind: String, Codable, Sendable {
        case mac
        case nodeExporter
    }

    public var id: UUID
    public var kind: Kind
    public var name: String
    /// Bonjour service name of a Mac found on the network; reached through Bonjour so a new IP address does not matter.
    public var serviceName: String?
    /// Host and port for a server, or for a Mac added by address (over a VPN, where Bonjour does not reach).
    public var host: String?
    public var port: UInt16?
    /// node_exporter's metrics path, usually /metrics.
    public var path: String?
    public var addedAt: Date

    public init(id: UUID = UUID(), kind: Kind, name: String, serviceName: String? = nil, host: String? = nil,
                port: UInt16? = nil, path: String? = nil, addedAt: Date = Date()) {
        self.id = id
        self.kind = kind
        self.name = name
        self.serviceName = serviceName
        self.host = host
        self.port = port
        self.path = path
        self.addedAt = addedAt
    }

    public static let bonjourType = "_activityplus._tcp"
    /// The port "Let other Macs see this Mac" listens on, for Macs added by address.
    public static let sharePort: UInt16 = 47390
    public static let nodeExporterPort: UInt16 = 9100

    /// "http://host:9100/metrics" for servers, "host:port" for a Mac, the service name for a Bonjour Mac.
    public var address: String {
        switch kind {
        case .nodeExporter:
            let shownHost = (host ?? "").contains(":") ? "[\(host ?? "")]" : (host ?? "")
            return "http://\(shownHost):\(port ?? Self.nodeExporterPort)\(path ?? "/metrics")"
        case .mac:
            if let host { return "\(host):\(port ?? Self.sharePort)" }
            return serviceName ?? name
        }
    }

    public struct Address: Sendable, Equatable {
        public var host: String
        public var port: UInt16
        public var path: String
    }

    public enum AddressError: LocalizedError, Equatable {
        case empty
        case https
        case invalid

        public var errorDescription: String? {
            switch self {
            case .empty: String(localized: "Enter an address.")
            case .https: String(localized: "Only http:// is supported. node_exporter serves plain HTTP unless it was set up with TLS.")
            case .invalid: String(localized: "This is not an address Activity+ understands.")
            }
        }
    }

    /// Accepts what people type: "server", "server:9100", "http://server:9100/metrics", "10.0.0.5", "[fe80::1]:9100".
    public static func parseAddress(_ text: String, defaultPort: UInt16 = nodeExporterPort, defaultPath: String = "/metrics") throws -> Address {
        var rest = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rest.isEmpty else { throw AddressError.empty }
        if rest.lowercased().hasPrefix("https://") { throw AddressError.https }
        if rest.lowercased().hasPrefix("http://") { rest = String(rest.dropFirst(7)) }
        guard !rest.contains("://") else { throw AddressError.invalid }
        var path = defaultPath
        if let slash = rest.firstIndex(of: "/") {
            let candidate = String(rest[slash...])
            if candidate != "/" { path = candidate }
            rest = String(rest[..<slash])
        }
        var host = rest
        var port = defaultPort
        if rest.hasPrefix("[") {
            guard let close = rest.firstIndex(of: "]") else { throw AddressError.invalid }
            host = String(rest[rest.index(after: rest.startIndex)..<close])
            let after = rest[rest.index(after: close)...]
            if after.hasPrefix(":") {
                guard let value = UInt16(after.dropFirst()), value > 0 else { throw AddressError.invalid }
                port = value
            } else if !after.isEmpty {
                throw AddressError.invalid
            }
        } else if rest.filter({ $0 == ":" }).count == 1, let colon = rest.firstIndex(of: ":") {
            host = String(rest[..<colon])
            guard let value = UInt16(rest[rest.index(after: colon)...]), value > 0 else { throw AddressError.invalid }
            port = value
        }
        // A bare IPv6 address without brackets has several colons and no port.
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_:%"))
        guard !host.isEmpty, host.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { throw AddressError.invalid }
        return Address(host: host, port: port, path: path)
    }
}

/// What a card shows, from either source. Everything is optional: node_exporter has no app list,
/// a Mac has no load average per core, and rates need a second reading.
public struct RemoteStatus: Sendable, Equatable {
    public var cpu: Double?
    public var cores: Int?
    public var load1: Double?
    public var memoryUsed: UInt64?
    public var memoryTotal: UInt64?
    public var memoryPressure: String?
    public var diskFree: UInt64?
    public var diskTotal: UInt64?
    public var networkIn: Double?
    public var networkOut: Double?
    public var temperature: Double?
    public var uptime: TimeInterval?
    public var gpu: Double?
    public var battery: RemoteSummary.Battery?
    public var thermal: String?
    public var topCPU: [RemoteSummary.App] = []
    public var topMemory: [RemoteSummary.App] = []
    /// "MacBook Pro", or the OS of a server ("Ubuntu 24.04 LTS").
    public var model: String?
    public var appVersion: String?
    public var reportedName: String?

    public init() {}

    public var memoryFraction: Double? {
        guard let used = memoryUsed, let total = memoryTotal, total > 0 else { return nil }
        return Double(used) / Double(total)
    }

    public var diskUsedFraction: Double? {
        guard let free = diskFree, let total = diskTotal, total > 0 else { return nil }
        return Double(total - min(free, total)) / Double(total)
    }

    public init(summary: RemoteSummary) {
        cpu = summary.cpu
        cores = summary.cores > 0 ? summary.cores : nil
        load1 = summary.load1
        memoryUsed = summary.memory.used
        memoryTotal = summary.memory.total
        memoryPressure = summary.memory.pressure
        diskFree = summary.disk.free
        diskTotal = summary.disk.total
        networkIn = summary.network.inRate
        networkOut = summary.network.outRate
        temperature = summary.temperatures.cpu ?? summary.temperatures.gpu
        uptime = summary.uptime
        gpu = summary.gpu
        battery = summary.battery
        thermal = summary.thermal
        topCPU = summary.topCPU
        topMemory = summary.topMemory
        model = summary.model
        appVersion = summary.appVersion
        reportedName = summary.name
    }

    public init(reading: NodeExporterReading, rates: NodeExporterRates?) {
        cpu = rates?.cpuPercent
        cores = reading.cpuCount > 0 ? reading.cpuCount : nil
        load1 = reading.load1
        if let total = reading.memoryTotal {
            memoryTotal = total
            memoryUsed = reading.memoryAvailable.map { total - min($0, total) }
        }
        diskFree = reading.diskAvailable
        diskTotal = reading.diskSize
        networkIn = rates?.receiveRate
        networkOut = rates?.transmitRate
        temperature = reading.temperature
        uptime = reading.uptime
        model = reading.osName
        reportedName = reading.hostName
    }
}
