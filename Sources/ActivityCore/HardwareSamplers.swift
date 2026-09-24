import Darwin
import Foundation
import IOKit
import IOKit.ps

// MARK: - CPU

final class CPUSampler {
    private var previousTotal: [UInt32]?
    private var previousCores: [[UInt32]] = []
    private let efficiencyCores: Int = {
        guard (Sys.sysctlInt("hw.nperflevels") ?? 1) > 1 else { return 0 }
        return Sys.sysctlInt("hw.perflevel1.logicalcpu") ?? 0
    }()

    func sample() -> CPUStats {
        var stats = CPUStats()
        stats.efficiencyCores = efficiencyCores

        if let ticks = Self.totalTicks() {
            if let prev = previousTotal {
                let user = Double(ticks[0] &- prev[0]) + Double(ticks[3] &- prev[3])  // user + nice
                let system = Double(ticks[1] &- prev[1])
                let idle = Double(ticks[2] &- prev[2])
                let total = user + system + idle
                if total > 0 {
                    stats.user = user / total * 100
                    stats.system = system / total * 100
                    stats.idle = idle / total * 100
                }
            }
            previousTotal = ticks
        }

        let cores = Self.coreTicks()
        if cores.count == previousCores.count {
            stats.perCore = zip(cores, previousCores).map { now, prev in
                let busy = Double(now[0] &- prev[0]) + Double(now[1] &- prev[1]) + Double(now[3] &- prev[3])
                let total = busy + Double(now[2] &- prev[2])
                return total > 0 ? busy / total * 100 : 0
            }
        } else {
            stats.perCore = Array(repeating: 0, count: cores.count)
        }
        previousCores = cores

        var loads = [Double](repeating: 0, count: 3)
        if getloadavg(&loads, 3) == 3 { stats.loadAverage = (loads[0], loads[1], loads[2]) }
        return stats
    }

    /// [user, system, idle, nice] ticks for the whole machine.
    private static func totalTicks() -> [UInt32]? {
        var load = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &load) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let t = load.cpu_ticks
        return [t.0, t.1, t.2, t.3]
    }

    private static func coreTicks() -> [[UInt32]] {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount) == KERN_SUCCESS,
              let info
        else { return [] }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                          vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride))
        }
        let stride = Int(CPU_STATE_MAX)
        return (0..<Int(cpuCount)).map { cpu in
            (0..<stride).map { UInt32(bitPattern: info[cpu * stride + $0]) }
        }
    }
}

// MARK: - Memory

final class MemorySampler {
    private var previousSwapouts: UInt64?
    private var previousTime: UInt64 = 0

    func sample() -> MemoryStats {
        var stats = MemoryStats()
        stats.total = Sys.physicalMemory

        var vm = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        if result == KERN_SUCCESS {
            let page = Sys.pageSize
            // Same definitions Activity Monitor uses.
            stats.app = UInt64(vm.internal_page_count &- vm.purgeable_count) * page
            stats.wired = UInt64(vm.wire_count) * page
            stats.compressed = UInt64(vm.compressor_page_count) * page
            stats.cachedFiles = UInt64(vm.external_page_count + vm.purgeable_count) * page

            let now = DispatchTime.now().uptimeNanoseconds
            if let prev = previousSwapouts, previousTime > 0, vm.swapouts >= prev {
                let elapsed = Double(now - previousTime) / 1_000_000_000
                stats.swapOutRate = Double(vm.swapouts - prev) * Double(page) / max(elapsed, 0.001)
            }
            previousSwapouts = vm.swapouts
            previousTime = now
        }

        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 {
            stats.swapUsed = swap.xsu_used
            stats.swapTotal = swap.xsu_total
        }
        stats.pressure = MemoryPressure(rawValue: Sys.sysctlInt("kern.memorystatus_vm_pressure_level") ?? 1) ?? .normal
        return stats
    }
}

// MARK: - Disk

final class DiskSampler {
    private var baseline: (read: UInt64, write: UInt64)?
    private var previous: (read: UInt64, write: UInt64)?
    private var previousTime: UInt64 = 0
    private var cachedVolume: (name: String, total: UInt64, free: UInt64)?
    private var volumeCheckedAt: UInt64 = 0

    func sample() -> DiskStats {
        var stats = DiskStats()
        let now = DispatchTime.now().uptimeNanoseconds

        // Free space barely changes; asking every 10 s is plenty.
        if cachedVolume == nil || now - volumeCheckedAt > 10_000_000_000 {
            cachedVolume = Self.rootVolume()
            volumeCheckedAt = now
        }
        if let volume = cachedVolume {
            stats.volumeName = volume.name
            stats.total = volume.total
            stats.free = volume.free
        }

        let totals = Self.blockStorageTotals()
        if baseline == nil { baseline = totals }
        if let prev = previous, previousTime > 0 {
            let elapsed = Double(now - previousTime) / 1_000_000_000
            stats.readRate = Double(totals.read &- prev.read) / elapsed
            stats.writeRate = Double(totals.write &- prev.write) / elapsed
        }
        stats.readSinceLaunch = totals.read &- (baseline?.read ?? totals.read)
        stats.writtenSinceLaunch = totals.write &- (baseline?.write ?? totals.write)
        previous = totals
        previousTime = now
        return stats
    }

    private static func rootVolume() -> (name: String, total: UInt64, free: UInt64)? {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey, .volumeLocalizedNameKey]
        guard let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys) else { return nil }
        return (
            values.volumeLocalizedName ?? "Macintosh HD",
            UInt64(values.volumeTotalCapacity ?? 0),
            UInt64(values.volumeAvailableCapacityForImportantUsage ?? 0)
        )
    }

    private static func blockStorageTotals() -> (read: UInt64, write: UInt64) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS
        else { return (0, 0) }
        defer { IOObjectRelease(iterator) }

        var read: UInt64 = 0
        var write: UInt64 = 0
        var service = IOIteratorNext(iterator)
        while service != 0 {
            if let stats = IOKitProperty(service, "Statistics") as? [String: Any] {
                read += (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
                write += (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        return (read, write)
    }
}

// MARK: - Network

final class NetworkSampler {
    private var baseline: (UInt64, UInt64)?
    private var previous: (UInt64, UInt64)?
    private var previousTime: UInt64 = 0

    func sample() -> NetworkStats {
        var stats = NetworkStats()
        let now = DispatchTime.now().uptimeNanoseconds
        let totals = Self.interfaceTotals()
        if baseline == nil { baseline = totals }
        if let prev = previous, previousTime > 0 {
            let elapsed = Double(now - previousTime) / 1_000_000_000
            stats.inRate = Double(totals.0 &- prev.0) / elapsed
            stats.outRate = Double(totals.1 &- prev.1) / elapsed
        }
        stats.receivedSinceLaunch = totals.0 &- (baseline?.0 ?? totals.0)
        stats.sentSinceLaunch = totals.1 &- (baseline?.1 ?? totals.1)
        previous = totals
        previousTime = now
        return stats
    }

    /// 64-bit byte counters for physical interfaces. `getifaddrs` only has 32-bit ones that wrap at 4 GB.
    /// VPN tunnels (utun) are skipped: their traffic already crosses en0, counting both would double it.
    private static func interfaceTotals() -> (UInt64, UInt64) {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, 6, nil, &length, nil, 0) == 0, length > 0 else { return (0, 0) }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, 6, &buffer, &length, nil, 0) == 0 else { return (0, 0) }

        var received: UInt64 = 0
        var sent: UInt64 = 0
        buffer.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                if Int32(header.ifm_type) == RTM_IFINFO2 {
                    let info = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    var nameBuffer = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                    if if_indextoname(UInt32(info.ifm_index), &nameBuffer) != nil {
                        let name = String(cString: nameBuffer)
                        if name.hasPrefix("en") || name.hasPrefix("pdp_ip") {
                            received += info.ifm_data.ifi_ibytes
                            sent += info.ifm_data.ifi_obytes
                        }
                    }
                }
                guard header.ifm_msglen > 0 else { break }
                offset += Int(header.ifm_msglen)
            }
        }
        return (received, sent)
    }
}

/// Per-process network traffic. The kernel only exposes this through `nettop`
/// (NetworkStatistics.framework is private), which takes ~25 ms per call.
final class ProcessNetworkSampler {
    private var previous: [pid_t: (UInt64, UInt64)] = [:]
    private var previousTime: UInt64 = 0

    func sample() -> [pid_t: (inRate: Double, outRate: Double)] {
        let now = DispatchTime.now().uptimeNanoseconds
        guard let output = Self.runNettop() else { return [:] }
        let current = Self.parse(output)
        defer { previous = current; previousTime = now }
        guard previousTime > 0 else { return [:] }

        let elapsed = Double(now - previousTime) / 1_000_000_000
        var rates: [pid_t: (Double, Double)] = [:]
        for (pid, totals) in current {
            guard let prev = previous[pid], totals.0 >= prev.0, totals.1 >= prev.1 else { continue }
            let rate = (Double(totals.0 - prev.0) / elapsed, Double(totals.1 - prev.1) / elapsed)
            if rate.0 > 0 || rate.1 > 0 { rates[pid] = rate }
        }
        return rates
    }

    /// Lines look like `Google Chrome H.1234,5120,880,` — the name may contain dots, the pid is after the last one.
    static func parse(_ output: String) -> [pid_t: (UInt64, UInt64)] {
        var result: [pid_t: (UInt64, UInt64)] = [:]
        for line in output.split(separator: "\n").dropFirst() {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count >= 3,
                  let dot = fields[0].lastIndex(of: "."),
                  let pid = pid_t(fields[0][fields[0].index(after: dot)...]),
                  let bytesIn = UInt64(fields[1]),
                  let bytesOut = UInt64(fields[2])
            else { continue }
            result[pid] = (bytesIn, bytesOut)
        }
        return result
    }

    private static func runNettop() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        process.arguments = ["-P", "-L", "1", "-x", "-n", "-J", "bytes_in,bytes_out"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - GPU

final class GPUSampler {
    private var previousAppTime: [pid_t: UInt64] = [:]
    private var previousTime: UInt64 = 0

    struct Result {
        var stats: GPUStats?
        var perProcess: [pid_t: Double]
    }

    func sample() -> Result {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS
        else { return Result(stats: nil, perProcess: [:]) }
        defer { IOObjectRelease(iterator) }

        var stats: GPUStats?
        var appTime: [pid_t: UInt64] = [:]
        var accelerator = IOIteratorNext(iterator)
        while accelerator != 0 {
            if let perf = IOKitProperty(accelerator, "PerformanceStatistics") as? [String: Any] {
                var gpu = stats ?? GPUStats()
                gpu.name = (IOKitProperty(accelerator, "model") as? String) ?? Sys.chipName
                gpu.utilization = max(gpu.utilization, (perf["Device Utilization %"] as? NSNumber)?.doubleValue ?? 0)
                gpu.memoryInUse += (perf["In use system memory"] as? NSNumber)?.uint64Value ?? 0
                stats = gpu
            }
            Self.collectAppUsage(under: accelerator, into: &appTime)
            IOObjectRelease(accelerator)
            accelerator = IOIteratorNext(iterator)
        }

        let now = DispatchTime.now().uptimeNanoseconds
        var perProcess: [pid_t: Double] = [:]
        if previousTime > 0 {
            let elapsed = Double(now - previousTime)
            for (pid, time) in appTime {
                guard let prev = previousAppTime[pid], time > prev else { continue }
                perProcess[pid] = min(100, Double(time - prev) / elapsed * 100)
            }
        }
        previousAppTime = appTime
        previousTime = now
        return Result(stats: stats, perProcess: perProcess)
    }

    /// Each Metal client gets a user-client object under the accelerator that records
    /// `IOUserClientCreator = "pid 417, WindowServer"` and its accumulated GPU nanoseconds.
    private static func collectAppUsage(under accelerator: io_object_t, into totals: inout [pid_t: UInt64]) {
        var children: io_iterator_t = 0
        guard IORegistryEntryCreateIterator(accelerator, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &children) == KERN_SUCCESS
        else { return }
        defer { IOObjectRelease(children) }

        var child = IOIteratorNext(children)
        while child != 0 {
            if let creator = IOKitProperty(child, "IOUserClientCreator") as? String,
               let usage = IOKitProperty(child, "AppUsage") as? [[String: Any]],
               let pid = Self.pid(fromCreator: creator)
            {
                let time = usage.reduce(UInt64(0)) { $0 + ((($1["accumulatedGPUTime"]) as? NSNumber)?.uint64Value ?? 0) }
                totals[pid, default: 0] += time
            }
            IOObjectRelease(child)
            child = IOIteratorNext(children)
        }
    }

    static func pid(fromCreator creator: String) -> pid_t? {
        // "pid 417, WindowServer"
        guard creator.hasPrefix("pid ") else { return nil }
        let digits = creator.dropFirst(4).prefix { $0.isNumber }
        return pid_t(digits)
    }
}

// MARK: - Battery

final class BatterySampler {
    private lazy var service: io_service_t = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))

    deinit { if service != 0 { IOObjectRelease(service) } }

    func sample() -> BatteryStats? {
        guard service != 0 else { return nil }
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = properties?.takeRetainedValue() as? [String: Any],
              (dict["BatteryInstalled"] as? Bool) ?? true
        else { return nil }

        let details = dict["BatteryData"] as? [String: Any] ?? [:]
        func number(_ key: String) -> NSNumber? { (dict[key] as? NSNumber) ?? (details[key] as? NSNumber) }

        var stats = BatteryStats()
        let current = number("CurrentCapacity")?.doubleValue ?? 0
        let max = number("MaxCapacity")?.doubleValue ?? 100
        stats.percent = max > 0 ? min(100, current / max * 100) : current
        stats.isCharging = (dict["IsCharging"] as? Bool) ?? false
        stats.isPluggedIn = (dict["ExternalConnected"] as? Bool) ?? false
        stats.isFullyCharged = (dict["FullyCharged"] as? Bool) ?? (details["FullyCharged"] as? NSNumber)?.boolValue ?? false
        stats.cycleCount = number("CycleCount")?.intValue ?? 0

        // Amperage is a signed 16-bit value that IOKit sometimes hands over as a huge unsigned number.
        let amperage = Double(Int64(truncatingIfNeeded: number("Amperage")?.int64Value ?? 0))
        let voltage = number("Voltage")?.doubleValue ?? 0
        stats.batteryPower = amperage * voltage / 1_000_000

        if let telemetry = dict["PowerTelemetryData"] as? [String: Any],
           let load = (telemetry["SystemLoad"] as? NSNumber)?.doubleValue, load > 0
        {
            stats.systemPower = load / 1000
        } else if amperage < 0 {
            stats.systemPower = -stats.batteryPower
        }

        let design = number("DesignCapacity")?.doubleValue ?? 0
        let full = number("AppleRawMaxCapacity")?.doubleValue ?? number("NominalChargeCapacity")?.doubleValue
        if let full, design > 0 { stats.health = min(100, full / design * 100) }

        if let temperature = number("Temperature")?.doubleValue ?? number("VirtualTemperature")?.doubleValue, temperature > 0 {
            stats.temperature = temperature / 100
        }

        let estimate = IOPSGetTimeRemainingEstimate()
        if estimate > 0, !stats.isPluggedIn { stats.timeRemaining = estimate }
        return stats
    }
}

// MARK: - Helpers

func IOKitProperty(_ entry: io_registry_entry_t, _ key: String) -> Any? {
    IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
}
