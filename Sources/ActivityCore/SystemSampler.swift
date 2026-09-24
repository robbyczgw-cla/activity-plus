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

    /// Per-app network uses `nettop`; turn off to save ~25 ms per sample.
    public var perProcessNetwork = true

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
        snapshot.sensors = sensorSampler.sample()
        if snapshot.battery?.temperature == nil, let temperature = snapshot.sensors.batteryTemperature {
            snapshot.battery?.temperature = temperature
        }

        let gpu = gpuSampler.sample()
        snapshot.gpu = gpu.stats

        var result = processSampler.sample()
        let network = perProcessNetwork ? processNetworkSampler.sample() : [:]
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

    public static var chipName: String { Sys.chipName }
    public static var groupingAvailable: Bool { Responsibility.isAvailable }
}
