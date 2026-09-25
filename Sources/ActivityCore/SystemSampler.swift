import Foundation

/// Combines all samplers into one `SystemSnapshot`.
///
/// Not thread-safe by design: every sampler keeps the previous counters to compute rates,
/// so call `sample()` from one serial queue (the UI's `Monitor` does this).
public final class SystemSampler: @unchecked Sendable {
    private let processSampler = ProcessSampler()
    private let grouper = AppGrouper()
    private let cpuSampler = CPUSampler()
    private let memorySampler = MemorySampler()
    private let diskSampler = DiskSampler()
    private let networkSampler = NetworkSampler()
    private let processNetworkSampler = ProcessNetworkSampler()
    private let gpuSampler = GPUSampler()
    private let batterySampler = BatterySampler()
    private let sensorSampler = SensorSampler()
    private let chipSampler = IOReportSampler()
    private let drivesSampler = DrivesSampler()
    private var lastDrives: [DriveInfo] = []
    private var networkDetails: (interfaces: [NetworkInterfaceInfo], wifi: WiFiInfo?, gateway: String?, at: Date)?
    private var lastSample: Date?

    /// Per-app network uses `nettop` (~90 ms wall time); it runs every `networkEvery` samples.
    public var perProcessNetwork = true
    private var tick = 0
    private var lastNetwork: [pid_t: (inRate: Double, outRate: Double)] = [:]
    private var lastSensors = SensorStats()

    /// The full sensor list costs ~60 ms; only read it while someone is looking at it.
    public var wantsSensorList = false
    private var lastSensorList: [SensorReading] = []

    public init() {}

    /// Supplied by the app when the privileged helper is installed (called on the sampling queue).
    public var privilegedUsage: (([Int32]) -> [Int32: PrivilegedUsage])? {
        get { processSampler.privilegedUsage }
        set { processSampler.privilegedUsage = newValue }
    }

    /// Every sensor the Mac reports (temperatures, voltages, currents, power, fans).
    public func sensorList() -> [SensorReading] { sensorSampler.allSensors() }

    public func sample() -> SystemSnapshot {
        var snapshot = SystemSnapshot()
        let now = Date()
        snapshot.interval = lastSample.map { now.timeIntervalSince($0) } ?? 0
        lastSample = now

        snapshot.cpu = cpuSampler.sample()
        snapshot.memory = memorySampler.sample()
        snapshot.disk = diskSampler.sample()
        snapshot.network = networkSampler.sample()
        snapshot.battery = batterySampler.sample()
        tick += 1
        // Temperatures move slowly and reading ~60 HID sensors costs ~60 ms: every 5th sample is plenty.
        if tick % 5 == 1 { lastSensors = sensorSampler.sample() }
        snapshot.sensors = lastSensors
        if wantsSensorList, tick % 3 == 1 { lastSensorList = sensorSampler.allSensors() }
        snapshot.sensorList = wantsSensorList ? lastSensorList : []
        if snapshot.battery?.temperature == nil, let temperature = snapshot.sensors.batteryTemperature {
            snapshot.battery?.temperature = temperature
        }

        snapshot.chip = chipSampler.sample()
        if tick % 2 == 1 { lastDrives = drivesSampler.sample() }
        snapshot.drives = lastDrives
        if networkDetails == nil || now.timeIntervalSince(networkDetails!.at) > 10 {
            // Only interfaces that are up and have an address (skips awdl, idle tunnels and the like).
            let interfaces = NetworkInfo.interfaces().filter { $0.isUp && $0.id != "lo0" && !($0.ipv4.isEmpty && $0.ipv6.isEmpty) }
            networkDetails = (interfaces, NetworkInfo.wifi(), NetworkInfo.primaryGateway(), now)
        }
        snapshot.interfaces = networkDetails?.interfaces ?? []
        snapshot.wifi = networkDetails?.wifi
        snapshot.gateway = networkDetails?.gateway

        let gpu = gpuSampler.sample()
        snapshot.gpu = gpu.stats

        var result = processSampler.sample()
        if perProcessNetwork, tick % 2 == 1 { lastNetwork = processNetworkSampler.sample() }
        let network = perProcessNetwork ? lastNetwork : [:]
        for index in result.processes.indices {
            let pid = result.processes[index].pid
            if let rate = network[pid] {
                result.processes[index].netInRate = rate.inRate
                result.processes[index].netOutRate = rate.outRate
            }
            if let share = gpu.perProcess[pid] {
                result.processes[index].gpuPercent = share
            }
        }

        snapshot.apps = grouper.group(result.processes)
        snapshot.processCount = result.processes.count
        snapshot.restrictedProcessCount = result.restricted
        snapshot.uptime = now.timeIntervalSince(Sys.bootTime)
        snapshot.thermal = switch ProcessInfo.processInfo.thermalState {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: .nominal
        }
        return snapshot
    }

    /// Milliseconds per sampler, averaged over `rounds` (for `aplus --bench`).
    public func benchmark(rounds: Int = 5) -> [(String, Double)] {
        func time(_ body: () -> Void) -> Double {
            let start = DispatchTime.now().uptimeNanoseconds
            body()
            return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        }
        var totals: [String: Double] = [:]
        var processes: [ProcessSample] = []
        for _ in 0..<rounds {
            totals["cpu", default: 0] += time { _ = cpuSampler.sample() }
            totals["memory", default: 0] += time { _ = memorySampler.sample() }
            totals["disk", default: 0] += time { _ = diskSampler.sample() }
            totals["network", default: 0] += time { _ = networkSampler.sample() }
            totals["battery", default: 0] += time { _ = batterySampler.sample() }
            totals["sensors", default: 0] += time { _ = sensorSampler.sample() }
            totals["gpu", default: 0] += time { _ = gpuSampler.sample() }
            totals["ps list", default: 0] += time { _ = ProcessSampler.listProcesses() }
            totals["processes (total)", default: 0] += time { processes = processSampler.sample().processes }
            totals["nettop", default: 0] += time { _ = processNetworkSampler.sample() }
            totals["grouping", default: 0] += time { _ = grouper.group(processes) }
        }
        return totals.map { ($0.key, $0.value / Double(rounds)) }.sorted { $0.1 > $1.1 }
    }

    public static var chipName: String { Sys.chipName }
    public static var groupingAvailable: Bool { Responsibility.isAvailable }
}
