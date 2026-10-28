import Foundation

/// The read-only summary one Activity+ shares with Macs it paired with (Settings → Sharing).
/// It is everything a card on "Other Macs" shows, and nothing that could change the shared Mac.
public struct RemoteSummary: Codable, Sendable, Equatable {
    /// Bumped when a field changes meaning; new optional fields keep the version.
    public static let schema = 1

    public struct Memory: Codable, Sendable, Equatable {
        public var used: UInt64
        public var total: UInt64
        /// "normal", "warning" or "critical".
        public var pressure: String
    }

    public struct Disk: Codable, Sendable, Equatable {
        public var free: UInt64
        public var total: UInt64
        public var readRate: Double
        public var writeRate: Double
    }

    public struct Network: Codable, Sendable, Equatable {
        public var inRate: Double
        public var outRate: Double
    }

    public struct Temperatures: Codable, Sendable, Equatable {
        public var cpu: Double?
        public var gpu: Double?
    }

    public struct Battery: Codable, Sendable, Equatable {
        public var percent: Double
        public var charging: Bool
        public var pluggedIn: Bool
    }

    public struct App: Codable, Sendable, Equatable, Hashable {
        public var name: String
        public var cpu: Double
        public var memory: UInt64
        public init(name: String, cpu: Double, memory: UInt64) {
            self.name = name
            self.cpu = cpu
            self.memory = memory
        }
    }

    public var schema: Int
    public var name: String
    public var model: String
    public var appVersion: String
    public var date: Date
    public var uptime: TimeInterval
    /// 0…100 of the whole machine.
    public var cpu: Double
    public var cores: Int
    public var load1: Double
    public var memory: Memory
    public var gpu: Double?
    public var disk: Disk
    public var network: Network
    public var temperatures: Temperatures
    public var battery: Battery?
    /// "nominal", "fair", "serious" or "critical", like ProcessInfo.ThermalState.
    public var thermal: String
    public var topCPU: [App]
    public var topMemory: [App]

    public static let topCount = 5

    public init(snapshot: SystemSnapshot, name: String, model: String, appVersion: String) {
        schema = Self.schema
        self.name = name
        self.model = model
        self.appVersion = appVersion
        date = snapshot.date
        uptime = snapshot.uptime
        cpu = snapshot.cpu.total
        cores = snapshot.cpu.perCore.count
        load1 = snapshot.cpu.loadAverage.0
        let pressure: String = switch snapshot.memory.pressure {
        case .normal: "normal"
        case .warning: "warning"
        case .critical: "critical"
        }
        memory = Memory(used: snapshot.memory.used, total: snapshot.memory.total, pressure: pressure)
        gpu = snapshot.gpu?.utilization
        disk = Disk(free: snapshot.disk.free, total: snapshot.disk.total, readRate: snapshot.disk.readRate, writeRate: snapshot.disk.writeRate)
        network = Network(inRate: snapshot.network.inRate, outRate: snapshot.network.outRate)
        temperatures = Temperatures(cpu: snapshot.sensors.cpuTemperature, gpu: snapshot.sensors.gpuTemperature)
        battery = snapshot.battery.map { Battery(percent: $0.percent, charging: $0.isCharging, pluggedIn: $0.isPluggedIn) }
        thermal = switch snapshot.thermal {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        }
        // Rounded: the viewer shows whole percent and does not need the exact figures.
        func app(_ group: AppGroup) -> App { App(name: group.name, cpu: (group.cpuPercent * 10).rounded() / 10, memory: group.memory) }
        topCPU = snapshot.apps.sorted { $0.cpuPercent > $1.cpuPercent }.prefix(Self.topCount).map(app)
        topMemory = snapshot.apps.sorted { $0.memory > $1.memory }.prefix(Self.topCount).map(app)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> RemoteSummary {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let summary = try decoder.decode(RemoteSummary.self, from: data)
        guard summary.schema <= Self.schema else { throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Newer summary format \(summary.schema)")) }
        return summary
    }
}
