import Foundation

/// One process at one point in time. Rates are per second, measured since the previous sample.
public struct ProcessSample: Sendable, Identifiable, Hashable {
    public let pid: Int32
    public let ppid: Int32
    public let uid: UInt32
    public let name: String
    public let path: String?
    public let startTime: Date
    /// Percent of one core, like Activity Monitor (can exceed 100 on multi-threaded work).
    public var cpuPercent: Double = 0
    /// Physical footprint in bytes — the figure Activity Monitor calls "Memory".
    public var memory: UInt64 = 0
    public var diskReadRate: Double = 0
    public var diskWriteRate: Double = 0
    public var netInRate: Double = 0
    public var netOutRate: Double = 0
    /// Percent of GPU time used by this process since the last sample.
    public var gpuPercent: Double = 0
    /// Average power in watts since the last sample (from the kernel's per-task energy counter).
    public var powerWatts: Double = 0
    /// Total CPU seconds since the process started.
    public var cpuTime: Double = 0
    /// False when the kernel refused detailed stats (root/system processes without a helper).
    public var hasDetails: Bool = true
    /// Memory the process holds for the Neural Engine (Core ML, local models), in bytes.
    public var neuralMemory: UInt64 = 0
    /// CPU nanoseconds per second spent on performance cores (the rest ran on efficiency cores).
    public var pCoreNanosRate: Double = 0
    /// CPU nanoseconds per second in total, for weighting the P-core share across processes.
    public var cpuNanosRate: Double = 0
    /// Instructions and cycles retired per second; their ratio is the IPC.
    public var instructionRate: Double = 0
    public var cycleRate: Double = 0

    /// Share of CPU time on performance cores (0…1), nil while idle.
    public var pCoreShare: Double? { cpuNanosRate > 1_000_000 ? min(1, pCoreNanosRate / cpuNanosRate) : nil }
    /// Instructions per cycle, nil while idle.
    public var ipc: Double? { cycleRate > 1_000_000 ? instructionRate / cycleRate : nil }

    public var id: Int32 { pid }

    public init(pid: Int32, ppid: Int32, uid: UInt32, name: String, path: String?, startTime: Date) {
        self.pid = pid
        self.ppid = ppid
        self.uid = uid
        self.name = name
        self.path = path
        self.startTime = startTime
    }
}

/// Every process that belongs to one app (helpers, XPC services, child processes), summed up.
public struct AppGroup: Sendable, Identifiable, Hashable {
    public enum Kind: String, Sendable, Hashable {
        case app       // Has a .app bundle
        case tool      // Stand-alone executable run by the user (node, python, docker…)
        case system    // macOS daemons and agents
    }

    /// Stable across samples: bundle path, "tool:<name>" or "system".
    public let id: String
    public let name: String
    public let kind: Kind
    public let bundlePath: String?
    public let bundleID: String?
    /// The pid the group was resolved from (the app's main process when running).
    public let mainPID: Int32?
    public var processes: [ProcessSample]

    public var cpuPercent: Double = 0
    public var memory: UInt64 = 0
    public var diskReadRate: Double = 0
    public var diskWriteRate: Double = 0
    public var netInRate: Double = 0
    public var netOutRate: Double = 0
    public var gpuPercent: Double = 0
    public var powerWatts: Double = 0
    /// Neural Engine memory of all processes (Core ML, local models).
    public var neuralMemory: UInt64 = 0
    /// Share of the app's CPU time on performance cores, and its instructions per cycle (nil while idle).
    public var pCoreShare: Double?
    public var ipc: Double?

    public init(id: String, name: String, kind: Kind, bundlePath: String?, bundleID: String?, mainPID: Int32?, processes: [ProcessSample]) {
        self.id = id
        self.name = name
        self.kind = kind
        self.bundlePath = bundlePath
        self.bundleID = bundleID
        self.mainPID = mainPID
        self.processes = processes
        recomputeTotals()
    }

    public mutating func recomputeTotals() {
        cpuPercent = processes.reduce(0) { $0 + $1.cpuPercent }
        memory = processes.reduce(0) { $0 + $1.memory }
        diskReadRate = processes.reduce(0) { $0 + $1.diskReadRate }
        diskWriteRate = processes.reduce(0) { $0 + $1.diskWriteRate }
        netInRate = processes.reduce(0) { $0 + $1.netInRate }
        netOutRate = processes.reduce(0) { $0 + $1.netOutRate }
        gpuPercent = processes.reduce(0) { $0 + $1.gpuPercent }
        powerWatts = processes.reduce(0) { $0 + $1.powerWatts }
        neuralMemory = processes.reduce(0) { $0 + $1.neuralMemory }
        let cpuNanos = processes.reduce(0) { $0 + $1.cpuNanosRate }
        let pNanos = processes.reduce(0) { $0 + $1.pCoreNanosRate }
        let instructions = processes.reduce(0) { $0 + $1.instructionRate }
        let cycles = processes.reduce(0) { $0 + $1.cycleRate }
        pCoreShare = cpuNanos > 1_000_000 ? min(1, pNanos / cpuNanos) : nil
        ipc = cycles > 1_000_000 ? instructions / cycles : nil
    }
}

public struct CPUStats: Sendable, Hashable {
    public var user: Double = 0      // 0…100 of the whole machine
    public var system: Double = 0
    public var idle: Double = 100
    public var perCore: [Double] = []   // 0…100 each
    public var efficiencyCores: Int = 0 // The first N entries of perCore are E-cores on Apple silicon
    public var loadAverage: (Double, Double, Double) = (0, 0, 0)
    public var total: Double { user + system }

    public init() {}

    public static func == (a: CPUStats, b: CPUStats) -> Bool {
        a.user == b.user && a.system == b.system && a.perCore == b.perCore
    }
    public func hash(into h: inout Hasher) { h.combine(user); h.combine(system); h.combine(perCore) }
}

public enum MemoryPressure: Int, Sendable, Comparable {
    case normal = 1, warning = 2, critical = 4
    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    public var label: String {
        switch self {
        case .normal: "Normal"
        case .warning: "Elevated"
        case .critical: "Critical"
        }
    }
}

public struct MemoryStats: Sendable, Hashable {
    public var total: UInt64 = 0
    public var app: UInt64 = 0
    public var wired: UInt64 = 0
    public var compressed: UInt64 = 0
    public var cachedFiles: UInt64 = 0
    public var swapUsed: UInt64 = 0
    public var swapTotal: UInt64 = 0
    public var pressure: MemoryPressure = .normal
    /// Pages swapped out per second — the clearest sign that RAM is not enough.
    public var swapOutRate: Double = 0
    public var used: UInt64 { app + wired + compressed }
    public init() {}
}

public struct DiskStats: Sendable, Hashable {
    public var volumeName: String = "Macintosh HD"
    public var total: UInt64 = 0
    public var free: UInt64 = 0
    public var readRate: Double = 0
    public var writeRate: Double = 0
    public var readSinceLaunch: UInt64 = 0
    public var writtenSinceLaunch: UInt64 = 0
    public init() {}
}

public struct NetworkStats: Sendable, Hashable {
    public var inRate: Double = 0
    public var outRate: Double = 0
    public var receivedSinceLaunch: UInt64 = 0
    public var sentSinceLaunch: UInt64 = 0
    public init() {}
}

public struct GPUStats: Sendable, Hashable {
    public var name: String = "GPU"
    public var utilization: Double = 0   // 0…100
    public var memoryInUse: UInt64 = 0
    public init() {}
}

public struct BatteryStats: Sendable, Hashable {
    public var percent: Double = 0
    public var isCharging = false
    public var isPluggedIn = false
    public var isFullyCharged = false
    /// Seconds; nil while unknown or while plugged in.
    public var timeRemaining: TimeInterval?
    /// Watts flowing out of (negative) or into (positive) the battery.
    public var batteryPower: Double = 0
    /// Total system power draw in watts, when the hardware reports it.
    public var systemPower: Double?
    public var cycleCount: Int = 0
    /// Current full-charge capacity relative to design capacity, 0…100.
    public var health: Double?
    public var temperature: Double?
    public init() {}
}

public enum ThermalLevel: String, Sendable {
    case nominal = "Normal", fair = "Warm", serious = "Hot", critical = "Critical"
}

/// Everything the UI needs for one refresh.
public struct SystemSnapshot: Sendable {
    public var date = Date()
    public var interval: TimeInterval = 0
    public var cpu = CPUStats()
    public var memory = MemoryStats()
    public var disk = DiskStats()
    public var network = NetworkStats()
    public var gpu: GPUStats?
    public var battery: BatteryStats?
    public var sensors = SensorStats()
    /// CPU/GPU frequencies and GPU/ANE power (Apple silicon, IOReport).
    public var chip = ChipPower()
    /// Filled only while the sensor list is shown (see SystemSampler.wantsSensorList).
    public var sensorList: [SensorReading] = []
    /// Every physical drive with throughput and health.
    public var drives: [DriveInfo] = []
    /// Network interfaces and Wi-Fi details (refreshed every ~10 s).
    public var interfaces: [NetworkInterfaceInfo] = []
    public var wifi: WiFiInfo?
    public var gateway: String?
    public var apps: [AppGroup] = []
    public var processCount = 0
    /// Processes whose details the kernel would not give us (needs the privileged helper).
    public var restrictedProcessCount = 0
    public var uptime: TimeInterval = 0
    public var thermal: ThermalLevel = .nominal
    public init() {}
}
