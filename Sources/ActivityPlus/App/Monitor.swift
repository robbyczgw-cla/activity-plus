import ActivityCore
import Foundation
import Observation

/// A fixed-size series for sparklines and charts.
struct Series: Sendable {
    private(set) var values: [Double] = []
    let capacity: Int

    init(capacity: Int = 300) { self.capacity = capacity }

    mutating func append(_ value: Double) {
        values.append(value)
        if values.count > capacity { values.removeFirst(values.count - capacity) }
    }

    var last: Double { values.last ?? 0 }
    var peak: Double { values.max() ?? 0 }
    var average: Double { values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count) }
}

/// Recent history kept in memory (the last ~10 minutes at the default interval).
struct LiveHistory: Sendable {
    var cpu = Series()
    var cpuUser = Series()
    var cpuSystem = Series()
    var memory = Series()           // bytes used
    var gpu = Series()
    var diskRead = Series()
    var diskWrite = Series()
    var netIn = Series()
    var netOut = Series()
    var battery = Series()
    var power = Series()
    var cpuTemperature = Series()
    /// Per-app CPU and memory, keyed by AppGroup.id.
    var appCPU: [String: Series] = [:]
    var appMemory: [String: Series] = [:]
}

/// The single source of live data for every window and the menu bar.
@MainActor @Observable
final class Monitor {
    static let shared = Monitor()

    private(set) var snapshot = SystemSnapshot()
    private(set) var history = LiveHistory()
    private(set) var sampleCount = 0
    let launchDate = Date()

    var interval: TimeInterval {
        didSet {
            UserDefaults.standard.set(interval, forKey: "sampleInterval")
            schedule()
        }
    }

    /// Set by the main window and the menu bar panel. With neither visible, sampling slows to 5 s:
    /// history and alerts work in minute buckets and lose nothing.
    var windowVisible = false { didSet { if windowVisible != oldValue { schedule() } } }
    var panelVisible = false { didSet { if panelVisible != oldValue { schedule() } } }
    /// The full sensor list is only read while the Temperatures page is open.
    var sensorListWanted = false {
        didSet {
            let sampler = sampler, wanted = sensorListWanted
            queue.async { sampler.wantsSensorList = wanted }
        }
    }
    private var effectiveInterval: TimeInterval {
        windowVisible || panelVisible ? interval : max(interval, 5)
    }

    /// Everything that wants each fresh snapshot (history store, alerts…) registers here.
    @ObservationIgnored var observers: [(SystemSnapshot) -> Void] = []

    @ObservationIgnored private let sampler = SystemSampler()
    @ObservationIgnored private let queue = DispatchQueue(label: "at.hifiteam.activityplus.sampler", qos: .utility)
    @ObservationIgnored private var timer: DispatchSourceTimer?

    private init() {
        let stored = UserDefaults.standard.double(forKey: "sampleInterval")
        interval = stored > 0 ? stored : 2
    }

    private var started = false

    /// Wires in the privileged helper (see HelperClient); runs on the sampling queue.
    func setPrivilegedUsage(_ provider: @escaping @Sendable ([Int32]) -> [Int32: PrivilegedUsage]) {
        let sampler = sampler
        queue.async { sampler.privilegedUsage = provider }
    }

    func start() {
        guard !started else { return }
        started = true
        schedule()
    }

    private func schedule() {
        guard started else { return }
        timer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + (self.timer == nil ? 0 : 0.2), repeating: effectiveInterval, leeway: .milliseconds(300))
        let sampler = sampler
        timer.setEventHandler { [weak self] in
            let snapshot = sampler.sample()
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.apply(snapshot) }
            }
        }
        timer.resume()
        self.timer = timer
    }

    private func apply(_ snapshot: SystemSnapshot) {
        sampleCount += 1
        // The first sample has no deltas (all rates 0); keep it for totals but not for charts.
        self.snapshot = snapshot
        guard snapshot.interval > 0 else { return }

        history.cpu.append(snapshot.cpu.total)
        history.cpuUser.append(snapshot.cpu.user)
        history.cpuSystem.append(snapshot.cpu.system)
        history.memory.append(Double(snapshot.memory.used))
        history.gpu.append(snapshot.gpu?.utilization ?? 0)
        history.diskRead.append(snapshot.disk.readRate)
        history.diskWrite.append(snapshot.disk.writeRate)
        history.netIn.append(snapshot.network.inRate)
        history.netOut.append(snapshot.network.outRate)
        if let battery = snapshot.battery {
            history.battery.append(battery.percent)
            history.power.append(battery.systemPower ?? max(0, -battery.batteryPower))
        }

        if let temperature = snapshot.sensors.cpuTemperature { history.cpuTemperature.append(temperature) }

        let live = Set(snapshot.apps.map(\.id))
        for app in snapshot.apps {
            history.appCPU[app.id, default: Series(capacity: 150)].append(app.cpuPercent)
            history.appMemory[app.id, default: Series(capacity: 150)].append(Double(app.memory))
        }
        history.appCPU = history.appCPU.filter { live.contains($0.key) }
        history.appMemory = history.appMemory.filter { live.contains($0.key) }

        observers.forEach { $0(snapshot) }
    }

    /// True while the Mac is clearly struggling; the menu bar icon turns into a warning.
    var isUnderStrain: Bool {
        snapshot.memory.pressure == .critical
            || snapshot.thermal == .serious || snapshot.thermal == .critical
            || history.cpu.values.suffix(5).allSatisfy { $0 > 90 } && history.cpu.values.count >= 5
    }
}
