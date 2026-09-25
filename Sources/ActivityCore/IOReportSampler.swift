import Foundation
import Darwin
import IOKit

private func ioReportSymbol<T>(_ handle: UnsafeMutableRawPointer?, _ name: String, as type: T.Type) -> T? {
    guard let handle, let symbol = dlsym(handle, name) else { return nil }
    return unsafeBitCast(symbol, to: type)
}

public struct ChipPower: Sendable, Hashable {
    public var cpuWatts: Double?
    public var gpuWatts: Double?
    public var aneWatts: Double?
    public var dramWatts: Double?
    public var efficiencyMHz: Double?
    public var performanceMHz: Double?
    public var gpuMHz: Double?
    public init() {}
}

/// Best-effort sampler for Apple's private IOReport counters. Every private symbol
/// is looked up dynamically, so unsupported OS releases simply produce empty values.
public final class IOReportSampler {
    private typealias CopyChannels = @convention(c) (CFString, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFDictionary>?
    private typealias MergeChannels = @convention(c) (CFMutableDictionary, CFDictionary, UnsafeRawPointer?) -> Void
    private typealias CreateSubscription = @convention(c) (UnsafeRawPointer?, CFDictionary, UnsafeMutablePointer<Unmanaged<CFDictionary>?>?, UInt64, UnsafeRawPointer?) -> Unmanaged<AnyObject>?
    private typealias CreateSamples = @convention(c) (AnyObject, CFDictionary, CFString?) -> Unmanaged<CFDictionary>?
    private typealias CreateDelta = @convention(c) (CFDictionary, CFDictionary, CFString?) -> Unmanaged<CFDictionary>?
    private typealias ChannelString = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    private typealias IntegerValue = @convention(c) (CFDictionary, Int32) -> Int64
    private typealias StateCount = @convention(c) (CFDictionary) -> Int32
    private typealias StateName = @convention(c) (CFDictionary, Int32) -> Unmanaged<CFString>?
    private typealias StateResidency = @convention(c) (CFDictionary, Int32) -> UInt64
    private typealias UnitLabel = @convention(c) (CFDictionary) -> Unmanaged<CFString>?

    private let handle: UnsafeMutableRawPointer?
    private let copyChannels: CopyChannels?
    private let mergeChannels: MergeChannels?
    private let createSubscription: CreateSubscription?
    private let createSamples: CreateSamples?
    private let createDelta: CreateDelta?
    private let getGroup: ChannelString?
    private let getSubgroup: ChannelString?
    private let getName: ChannelString?
    private let integerValue: IntegerValue?
    private let stateCount: StateCount?
    private let stateName: StateName?
    private let stateResidency: StateResidency?
    private let unitLabel: UnitLabel?
    private var channels: CFDictionary?
    private var subscription: AnyObject?
    private var previous: CFDictionary?
    private var previousAt: CFAbsoluteTime?

    public init() {
        handle = dlopen("/usr/lib/libIOReport.dylib", RTLD_LAZY | RTLD_LOCAL)
        let library = handle
        copyChannels = ioReportSymbol(library, "IOReportCopyChannelsInGroup", as: CopyChannels.self)
        mergeChannels = ioReportSymbol(library, "IOReportMergeChannels", as: MergeChannels.self)
        createSubscription = ioReportSymbol(library, "IOReportCreateSubscription", as: CreateSubscription.self)
        createSamples = ioReportSymbol(library, "IOReportCreateSamples", as: CreateSamples.self)
        createDelta = ioReportSymbol(library, "IOReportCreateSamplesDelta", as: CreateDelta.self)
        getGroup = ioReportSymbol(library, "IOReportChannelGetGroup", as: ChannelString.self)
        getSubgroup = ioReportSymbol(library, "IOReportChannelGetSubGroup", as: ChannelString.self)
        getName = ioReportSymbol(library, "IOReportChannelGetChannelName", as: ChannelString.self)
        integerValue = ioReportSymbol(library, "IOReportSimpleGetIntegerValue", as: IntegerValue.self)
        stateCount = ioReportSymbol(library, "IOReportStateGetCount", as: StateCount.self)
        stateName = ioReportSymbol(library, "IOReportStateGetNameForIndex", as: StateName.self)
        stateResidency = ioReportSymbol(library, "IOReportStateGetResidency", as: StateResidency.self)
        unitLabel = ioReportSymbol(library, "IOReportChannelGetUnitLabel", as: UnitLabel.self)
        initialize()
    }

    deinit { if let handle { dlclose(handle) } }

    private func initialize() {
        guard let copyChannels else { return }
        let groups = ["Energy Model", "CPU Stats", "GPU Stats"]
        var combined: CFMutableDictionary?
        for group in groups {
            guard let unmanaged = copyChannels(group as CFString, nil, 0, 0, 0) else { continue }
            let next = unmanaged.takeRetainedValue()
            if let combined, let mergeChannels {
                mergeChannels(combined, next, nil)
                self.channels = combined
            } else if combined == nil {
                combined = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, next)
                self.channels = combined
            }
        }
        guard let channels = self.channels, let createSubscription else { return }
        var subscribedChannels: Unmanaged<CFDictionary>?
        if let sub = createSubscription(nil, channels, &subscribedChannels, 0, nil) {
            subscription = sub.takeRetainedValue()
            if let subscribedChannels { self.channels = subscribedChannels.takeRetainedValue() }
        }
    }

    public func sample() -> ChipPower {
        var output = ChipPower()
        guard let channels, let subscription, let createSamples,
              let currentRef = createSamples(subscription, channels, nil) else { return output }
        let current = currentRef.takeRetainedValue()
        defer { previous = current; previousAt = CFAbsoluteTimeGetCurrent() }
        guard let previous, let previousAt, let createDelta,
              let deltaRef = createDelta(previous, current, nil) else { return output }
        let now = CFAbsoluteTimeGetCurrent()
        let seconds = now - previousAt
        guard seconds > 0.02 else { return output }
        let delta = deltaRef.takeRetainedValue()
        var energy: [String: Double] = [:]
        var performance: [(mhz: Double, weight: Double)] = []
        for record in channelRecords(delta) {
            let group = string(getGroup?(record))
            let subgroup = string(getSubgroup?(record)) ?? ""
            let name = string(getName?(record)) ?? ""
            switch group {
            case "Energy Model":
                let raw = Double(integerValue?(record, 0) ?? 0)
                guard raw > 0 else { continue }
                let unit = string(unitLabel?(record))?.lowercased() ?? "mj"
                let joules = raw / (unit.hasPrefix("nj") ? 1e9 : unit.hasPrefix("uj") || unit.hasPrefix("µj") ? 1e6 : 1e3)
                // Totals where the chip reports them; per-core and per-cluster channels would double count.
                if name == "CPU Energy" { energy["cpu", default: 0] += joules }
                else if name == "GPU Energy" { energy["gpu", default: 0] += joules }
                else if name.hasPrefix("ANE") { energy["ane", default: 0] += joules }
                else if name.hasPrefix("DRAM") { energy["dram", default: 0] += joules }
            case "CPU Stats" where subgroup == "CPU Complex Performance States":
                // ECPU = efficiency cluster; PCPU, PCPU1, … = performance clusters (ECPM/PCPM are power managers, skip).
                if name == "ECPU", let f = averageFrequency(record, table: frequencies.efficiency) {
                    output.efficiencyMHz = f.mhz
                } else if name.hasPrefix("PCPU"), let f = averageFrequency(record, table: frequencies.performance) {
                    performance.append(f)
                }
            case "GPU Stats" where subgroup == "GPU Performance States" && name == "GPUPH":
                output.gpuMHz = averageFrequency(record, table: frequencies.gpu)?.mhz
            default:
                break
            }
        }
        let active = performance.reduce(0) { $0 + $1.weight }
        if active > 0 { output.performanceMHz = performance.reduce(0) { $0 + $1.mhz * $1.weight } / active }
        output.cpuWatts = energy["cpu"].map { $0 / seconds }
        output.gpuWatts = energy["gpu"].map { $0 / seconds }
        output.aneWatts = energy["ane"].map { $0 / seconds }
        output.dramWatts = energy["dram"].map { $0 / seconds }
        return output
    }

    // MARK: Frequencies

    /// Frequency tables (MHz) per cluster from the power manager node in the IORegistry.
    private lazy var frequencies: (efficiency: [Double], performance: [Double], gpu: [Double]) = Self.loadFrequencyTables()

    /// Average frequency while active (idle time is excluded), weighted by residency.
    /// State names are "IDLE"/"OFF"/"DOWN" followed by the performance states in ascending order,
    /// which line up with the table entries.
    private func averageFrequency(_ channel: CFDictionary, table: [Double]) -> (mhz: Double, weight: Double)? {
        guard !table.isEmpty, let stateCount, let stateName, let stateResidency else { return nil }
        var weighted = 0.0, total = 0.0, activeIndex = 0
        for index in 0..<stateCount(channel) {
            let label = (stateName(channel, index)?.takeUnretainedValue() as String?) ?? ""
            if label.hasPrefix("IDLE") || label.hasPrefix("OFF") || label.hasPrefix("DOWN") { continue }
            defer { activeIndex += 1 }
            guard activeIndex < table.count else { continue }
            let residency = Double(stateResidency(channel, index))
            weighted += table[activeIndex] * residency
            total += residency
        }
        return total > 0 ? (weighted / total, total) : nil
    }

    static func loadFrequencyTables() -> (efficiency: [Double], performance: [Double], gpu: [Double]) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleARMIODevice"), &iterator) == KERN_SUCCESS
        else { return ([], [], []) }
        defer { IOObjectRelease(iterator) }
        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer { IOObjectRelease(service); service = IOIteratorNext(iterator) }
            var name = [CChar](repeating: 0, count: 128)
            guard IORegistryEntryGetName(service, &name) == KERN_SUCCESS, String(cString: name) == "pmgr" else { continue }
            func table(_ key: String) -> [Double] {
                guard let data = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? Data else { return [] }
                // Pairs of little-endian UInt32: (frequency, voltage).
                let values = stride(from: 0, to: data.count - 7, by: 8).map { offset in
                    data.withUnsafeBytes { Double(UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self))) }
                }
                // Hz on M1–M3; newer chips report kHz.
                return values.filter { $0 > 0 }.map { $0 > 10_000_000 ? $0 / 1_000_000 : $0 / 1_000 }
            }
            let gpu = table("voltage-states9")
            return (table("voltage-states1-sram"), table("voltage-states5-sram"), gpu)
        }
        return ([], [], [])
    }

    /// One line per channel of the last delta, for `aplus --hardware --verbose`.
    public func channelDump() -> [String] {
        guard let channels, let subscription, let createSamples, let createDelta,
              let a = createSamples(subscription, channels, nil)?.takeRetainedValue() else { return [] }
        Thread.sleep(forTimeInterval: Double(ProcessInfo.processInfo.environment["IOREPORT_SECONDS"] ?? "0.5") ?? 0.5)
        guard let b = createSamples(subscription, channels, nil)?.takeRetainedValue(),
              let delta = createDelta(a, b, nil)?.takeRetainedValue() else { return [] }
        return channelRecords(delta).map { record in
            let group = string(getGroup?(record)) ?? "?"
            let sub = string(getSubgroup?(record)) ?? ""
            let name = string(getName?(record)) ?? ""
            let unit = string(unitLabel?(record)) ?? ""
            var line = "\(group) | \(sub) | \(name) | \(unit)"
            if group == "Energy Model" { line += " | \(integerValue?(record, 0) ?? 0)" }
            if let stateCount, let stateName, let stateResidency, stateCount(record) > 0, group != "Energy Model" {
                let states = (0..<stateCount(record)).map { i in "\((stateName(record, i)?.takeUnretainedValue() as String?) ?? "?")=\(stateResidency(record, i))" }
                line += " | " + states.joined(separator: " ")
            }
            return line
        }
    }

    private func channelRecords(_ sample: CFDictionary) -> [CFDictionary] {
        guard let array = CFDictionaryGetValue(sample, Unmanaged.passUnretained("IOReportChannels" as CFString).toOpaque()) else { return [] }
        let value = Unmanaged<CFArray>.fromOpaque(array).takeUnretainedValue()
        return (0..<CFArrayGetCount(value)).compactMap { index in
            guard let ptr = CFArrayGetValueAtIndex(value, index) else { return nil }
            return unsafeBitCast(ptr, to: CFDictionary.self)
        }
    }

    private func string(_ value: Unmanaged<CFString>?) -> String? { value?.takeUnretainedValue() as String? }
}
