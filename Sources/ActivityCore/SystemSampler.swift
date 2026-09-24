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
    private var lastSample: Date?

    /// Per-app network uses `nettop` (~90 ms wall time); it runs every `networkEvery` samples.
    public var perProcessNetwork = true
    private var tick = 0
    private var lastNetwork: [pid_t: (inRate: Double, outRate: Double)] = [:]
    private var lastSensors = SensorStats()

    public init() {}

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
        if snapshot.battery?.temperature == nil, let temperature = snapshot.sensors.batteryTemperature {
            snapshot.battery?.temperature = temperature
        }

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
