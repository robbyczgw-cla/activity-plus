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

    /// What to measure. Expensive parts can be switched off, and `background` (no window or panel
    /// visible) skips everything that is only ever looked at, never recorded.
    public struct Options: Sendable, Equatable {
        public var perProcessNetwork = true      // nettop, ~90 ms wall time + a child process
        public var perProcessGPU = true          // walks every Metal client in the IORegistry
        public var sensors = true                // ~60 HID sensors + SMC
        public var sensorsInBackground = false   // a menu bar item shows a temperature or fan
        public var chip = true                   // IOReport clocks and power
        public var drives = true                 // every drive incl. NVMe health
        public var networkDetails = true         // interfaces, Wi-Fi, router
        public var background = false
        public init() {}
    }
    public var options = Options()
    /// Kept for callers of the old flag.
    public var perProcessNetwork: Bool {
        get { options.perProcessNetwork }
        set { options.perProcessNetwork = newValue }
    }
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
        let visible = !options.background
        // Temperatures move slowly and reading ~60 HID sensors costs ~60 ms: every 5th sample is plenty.
        let wantSensors = options.sensors && (visible || options.sensorsInBackground)
        if wantSensors, tick % 5 == 1 { lastSensors = sensorSampler.sample() }
        snapshot.sensors = wantSensors ? lastSensors : SensorStats()
        // The full list is the most expensive sensor read: it obeys the same Performance switch.
        let wantList = wantsSensorList && options.sensors
        if wantList, tick % 3 == 1 { lastSensorList = sensorSampler.allSensors() }
        snapshot.sensorList = wantList ? lastSensorList : []
        if snapshot.battery?.temperature == nil, let temperature = snapshot.sensors.batteryTemperature {
            snapshot.battery?.temperature = temperature
        }

        // Clocks, drives and network details are only ever looked at, never recorded: skip them in the background.
        if options.chip && visible { snapshot.chip = chipSampler.sample() }
        if options.drives && visible && tick % 5 == 1 { lastDrives = drivesSampler.sample() }
        snapshot.drives = options.drives ? lastDrives : []
        if options.networkDetails && visible && (networkDetails == nil || now.timeIntervalSince(networkDetails!.at) > 10) {
            // Only interfaces that are up and have an address (skips awdl, idle tunnels and the like).
            let interfaces = NetworkInfo.interfaces().filter { $0.isUp && $0.id != "lo0" && !($0.ipv4.isEmpty && $0.ipv6.isEmpty) }
            networkDetails = (interfaces, NetworkInfo.wifi(), NetworkInfo.primaryGateway(), now)
        }
        snapshot.interfaces = networkDetails?.interfaces ?? []
        snapshot.wifi = networkDetails?.wifi
        snapshot.gateway = networkDetails?.gateway

        let gpu = gpuSampler.sample(perProcess: options.perProcessGPU)
        snapshot.gpu = gpu.stats

        // `ps` only matters for other users' processes; in the background every 15 s is enough.
        processSampler.listInterval = visible ? 5 : 15
        var result = processSampler.sample()
        if options.perProcessNetwork, tick % (visible ? 2 : 3) == 1 { lastNetwork = processNetworkSampler.sample() }
        let network = options.perProcessNetwork ? lastNetwork : [:]
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
