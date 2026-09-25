import Darwin
import Foundation
import IOKit

/// Two sources: Apple-silicon die temperatures come from the private HID event
/// system (usage page 0xFF00 / usage 5). Fan RPM, and Intel CPU/GPU temperatures
/// when HID has no reading, come from the AppleSMC user client.

public struct SensorReading: Sendable, Identifiable, Hashable {
    public enum Kind: String, Sendable, Hashable, CaseIterable {
        case temperature, voltage, current, power, fan
    }

    public let id: String
    public let name: String
    public let group: String
    public let kind: Kind
    public let value: Double

    public init(id: String, name: String, group: String, kind: Kind, value: Double) {
        self.id = id
        self.name = name
        self.group = group
        self.kind = kind
        self.value = value
    }
}

public struct SensorStats: Sendable, Hashable {
    public var cpuTemperature: Double?
    public var gpuTemperature: Double?
    public var batteryTemperature: Double?
    public var fans: [Fan]

    public struct Fan: Sendable, Hashable {
        public var name: String
        public var rpm: Double
        public var minRPM: Double?
        public var maxRPM: Double?
    }

    public init() {
        cpuTemperature = nil
        gpuTemperature = nil
        batteryTemperature = nil
        fans = []
    }
}

final class SensorSampler {
    private var hid: HIDAPI?
    private var hidClient: UnsafeMutableRawPointer?
    private var hidServices: UnsafeMutableRawPointer?
    private var servicesFetchedAt: UInt64 = 0
    private var triedAlternateClient = false

    private var smc: io_connect_t = 0
    private var smcOpenAttempted = false
    private var voltageHID = HIDCache()
    private var currentHID = HIDCache()
    private var temperatureHID = HIDCache()
    private var watchedKeys: [WatchedKey]?
    private var liveKeys: [WatchedKey]?
    private var idleSMC: [SensorReading] = []
    private var idleHID: [SensorReading] = []
    private var cachedSensors: [SensorReading]?
    private var sensorIndex: [String: Int] = [:]
    private var refreshQueue: [Refresh] = []
    private var refreshCursor = 0

    private struct Refresh {
        var id: String
        var source: Source
    }

    private enum Source {
        case smc(key: String, size: UInt32, type: String)
        case hid(slot: HIDSlot, index: Int, eventType: Int64)
    }

    private struct HIDCache {
        var client: UnsafeMutableRawPointer?
        var services: UnsafeMutableRawPointer?
        var fetchedAt: UInt64 = 0
    }

    private struct WatchedKey {
        var key: String
        var type: String
        var size: UInt32
        var kind: SensorReading.Kind
    }

    private let appleSilicon: Bool = {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 else { return false }
        return value != 0
    }()

    func sample() -> SensorStats {
        var stats = SensorStats()
        let readings = hidReadings()
        stats.cpuTemperature = Self.average(readings.cpu)
        stats.gpuTemperature = Self.average(readings.gpu)
        stats.batteryTemperature = Self.average(readings.battery)
        if !appleSilicon {
            if stats.cpuTemperature == nil {
                stats.cpuTemperature = Self.average([smcTemperature("TC0P"), smcTemperature("TC0D")].compactMap { $0 })
            }
            if stats.gpuTemperature == nil {
                stats.gpuTemperature = smcTemperature("TG0P")
            }
        }
        stats.fans = smcFans()
        return stats
    }

    /// Full sensor list. The first call enumerates SMC and HID. Later calls refresh a
    /// round-robin slice so the call stays under 80 ms, and reuse the last value for the rest.
    /// Exact zeros are kept from the first read; they are not polled again.
    func allSensors() -> [SensorReading] {
        if cachedSensors == nil {
            var readings: [SensorReading] = []
            readings.append(contentsOf: hidSensorReadings(page: 0xff00, usage: 5, eventType: 15, kind: .temperature, slot: .temperature))
            readings.append(contentsOf: hidSensorReadings(page: 0xff08, usage: 3, eventType: 25, kind: .voltage, slot: .voltage))
            readings.append(contentsOf: hidSensorReadings(page: 0xff08, usage: 2, eventType: 25, kind: .current, slot: .current))
            readings.append(contentsOf: idleHID)
            readings.append(contentsOf: smcSensorReadings())
            for (index, fan) in smcFans().enumerated() {
                let id = String(format: "F%dAc", index)
                readings.append(SensorReading(id: id, name: fan.name, group: "Other", kind: .fan, value: fan.rpm))
                refreshQueue.append(Refresh(id: id, source: .smc(key: id, size: 4, type: "flt ")))
            }
            cachedSensors = readings
            sensorIndex = Dictionary(uniqueKeysWithValues: readings.enumerated().map { ($1.id, $0) })
            return readings
        }
        guard !refreshQueue.isEmpty else { return cachedSensors ?? [] }
        let started = DispatchTime.now().uptimeNanoseconds
        var steps = 0
        while steps < refreshQueue.count, Double(DispatchTime.now().uptimeNanoseconds &- started) / 1_000_000 < 60 {
            let item = refreshQueue[refreshCursor]
            refreshCursor = (refreshCursor + 1) % refreshQueue.count
            steps += 1
            guard let value = readSource(item.source), let index = sensorIndex[item.id], cachedSensors != nil else { continue }
            let old = cachedSensors![index]
            guard Self.plausible(value, kind: old.kind) else { continue }
            cachedSensors![index] = SensorReading(id: old.id, name: old.name, group: old.group, kind: old.kind, value: value)
        }
        return cachedSensors ?? []
    }

    private func readSource(_ source: Source) -> Double? {
        switch source {
        case .smc(let key, let size, let type):
            guard let bytes = readSMCBytes(key: key, size: size) else { return nil }
            if key.hasPrefix("F") {
                return Self.fanRPM((type, bytes)) ?? Self.fanRPM(("fpe2", bytes)) ?? Self.fanRPM(("flt ", bytes))
            }
            return Self.decodeSMC(type: type, data: bytes)
        case .hid(let slot, let index, let eventType):
            return hidValue(slot: slot, index: index, eventType: eventType)
        }
    }

    deinit {
        if smc != 0 {
            IOServiceClose(smc)
            smc = 0
        }
        releaseServices()
        if let hidClient {
            Unmanaged<CFTypeRef>.fromOpaque(hidClient).release()
        }
        releaseHID(&voltageHID)
        releaseHID(&currentHID)
        releaseHID(&temperatureHID)
    }

    // MARK: HID

    private struct HIDAPI {
        let create: Create
        let setMatching: SetMatching
        let copyServices: CopyServices
        let copyProperty: CopyProperty
        let copyEvent: CopyEvent
        let getFloat: GetFloat

        typealias Create = @convention(c) (CFAllocator?, Int32) -> UnsafeMutableRawPointer?
        typealias SetMatching = @convention(c) (UnsafeMutableRawPointer, CFDictionary) -> Void
        typealias CopyServices = @convention(c) (UnsafeMutableRawPointer) -> UnsafeMutableRawPointer?
        typealias CopyProperty = @convention(c) (UnsafeMutableRawPointer, CFString) -> Unmanaged<CFTypeRef>?
        typealias CopyEvent = @convention(c) (UnsafeMutableRawPointer, Int64, Int32, Int64) -> UnsafeMutableRawPointer?
        typealias GetFloat = @convention(c) (UnsafeMutableRawPointer, Int32) -> Double
    }

    private func loadHID() -> HIDAPI? {
        if let hid { return hid }
        guard
            let create: HIDAPI.Create = bind("IOHIDEventSystemClientCreate"),
            let setMatching: HIDAPI.SetMatching = bind("IOHIDEventSystemClientSetMatching"),
            let copyServices: HIDAPI.CopyServices = bind("IOHIDEventSystemClientCopyServices"),
            let copyProperty: HIDAPI.CopyProperty = bind("IOHIDServiceClientCopyProperty"),
            let copyEvent: HIDAPI.CopyEvent = bind("IOHIDServiceClientCopyEvent"),
            let getFloat: HIDAPI.GetFloat = bind("IOHIDEventGetFloatValue")
        else { return nil }
        let api = HIDAPI(
            create: create,
            setMatching: setMatching,
            copyServices: copyServices,
            copyProperty: copyProperty,
            copyEvent: copyEvent,
            getFloat: getFloat
        )
        hid = api
        return api
    }

    private func bind<T>(_ name: String) -> T? {
        if let symbol = dlsym(Self.rtldDefault, name) ?? dlsym(Self.iokitHandle, name) {
            return unsafeBitCast(symbol, to: T.self)
        }
        return nil
    }

    private static let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
    private static let iokitHandle: UnsafeMutableRawPointer? = dlopen(
        "/System/Library/Frameworks/IOKit.framework/IOKit",
        RTLD_LAZY
    )

    private func hidReadings() -> (cpu: [Double], gpu: [Double], battery: [Double]) {
        guard let api = loadHID() else { return ([], [], []) }
        if hidClient == nil {
            hidClient = api.create(kCFAllocatorDefault, 0)
            guard let hidClient else { return ([], [], []) }
            let matching = [
                "PrimaryUsagePage": 0xff00,
                "PrimaryUsage": 5,
            ] as CFDictionary
            api.setMatching(hidClient, matching)
        }
        guard let hidClient else { return ([], [], []) }

        let now = DispatchTime.now().uptimeNanoseconds
        if hidServices == nil || now &- servicesFetchedAt > 60_000_000_000 {
            releaseServices()
            hidServices = api.copyServices(hidClient)
            servicesFetchedAt = now
        }
        guard let hidServices else { return ([], [], []) }
        let services = Unmanaged<CFArray>.fromOpaque(hidServices).takeUnretainedValue()
        guard CFArrayGetCount(services) > 0 else {
            if !triedAlternateClient {
                triedAlternateClient = true
                Unmanaged<CFTypeRef>.fromOpaque(hidClient).release()
                self.hidClient = api.create(kCFAllocatorDefault, 1)
                releaseServices()
                servicesFetchedAt = 0
                if self.hidClient != nil {
                    let matching = [
                        "PrimaryUsagePage": 0xff00,
                        "PrimaryUsage": 5,
                    ] as CFDictionary
                    api.setMatching(self.hidClient!, matching)
                    return hidReadings()
                }
            }
            return ([], [], [])
        }

        var cpu: [Double] = []
        var gpu: [Double] = []
        var battery: [Double] = []
        let count = CFArrayGetCount(services)
        let product = "Product" as CFString
        let field = Int32(15 << 16)
        for index in 0..<count {
            guard let raw = CFArrayGetValueAtIndex(services, index) else { continue }
            let service = UnsafeMutableRawPointer(mutating: raw)
            guard let nameRef = api.copyProperty(service, product)?.takeRetainedValue() else { continue }
            guard CFGetTypeID(nameRef) == CFStringGetTypeID() else { continue }
            let name = nameRef as! CFString as String
            guard let event = api.copyEvent(service, 15, 0, 0) else { continue }
            let value = api.getFloat(event, field)
            Unmanaged<CFTypeRef>.fromOpaque(event).release()
            guard value > 0, value <= 130 else { continue }
            if name.hasPrefix("PMU tdie") || name.hasPrefix("pACC") || name.hasPrefix("eACC") {
                cpu.append(value)
            } else if name.contains("GPU") || name.contains("PMU tdev") {
                gpu.append(value)
            } else if name.contains("gas gauge battery") || name.contains("Battery") {
                battery.append(value)
            }
        }
        return (cpu, gpu, battery)
    }

    private func releaseServices() {
        if let hidServices {
            Unmanaged<CFArray>.fromOpaque(hidServices).release()
            self.hidServices = nil
        }
    }

    private enum HIDSlot { case temperature, voltage, current }

    private func hidSensorReadings(
        page: Int,
        usage: Int,
        eventType: Int64,
        kind: SensorReading.Kind,
        slot: HIDSlot
    ) -> [SensorReading] {
        guard let api = loadHID() else { return [] }
        let services = hidServiceArray(page: page, usage: usage, slot: slot, api: api)
        guard let services else { return [] }
        let count = CFArrayGetCount(services)
        let productKey = "Product" as CFString
        let field = Int32(eventType << 16)
        var readings: [SensorReading] = []
        var seen: [String: Int] = [:]
        for index in 0..<count {
            guard let raw = CFArrayGetValueAtIndex(services, index) else { continue }
            let service = UnsafeMutableRawPointer(mutating: raw)
            guard let nameRef = api.copyProperty(service, productKey)?.takeRetainedValue(),
                  CFGetTypeID(nameRef) == CFStringGetTypeID()
            else { continue }
            let product = nameRef as! CFString as String
            guard let event = api.copyEvent(service, eventType, 0, 0) else { continue }
            let value = api.getFloat(event, field)
            Unmanaged<CFTypeRef>.fromOpaque(event).release()
            guard value.isFinite, Self.plausible(value, kind: kind) else { continue }
            let ordinal = seen[product, default: 0]
            seen[product] = ordinal + 1
            let id = ordinal == 0 ? "hid:\(product)" : "hid:\(product)#\(ordinal + 1)"
            let label = Self.hidLabel(product, kind: kind)
            if kind != .temperature && value == 0 {
                idleHID.append(SensorReading(id: id, name: label.name, group: label.group, kind: kind, value: 0))
                continue
            }
            readings.append(SensorReading(id: id, name: label.name, group: label.group, kind: kind, value: value))
            refreshQueue.append(Refresh(id: id, source: .hid(slot: slot, index: index, eventType: eventType)))
        }
        return readings
    }

    private func hidValue(slot: HIDSlot, index: Int, eventType: Int64) -> Double? {
        guard let api = loadHID() else { return nil }
        let page = slot == .temperature ? 0xff00 : 0xff08
        let usage = slot == .voltage ? 3 : (slot == .current ? 2 : 5)
        guard let services = hidServiceArray(page: page, usage: usage, slot: slot, api: api),
              index < CFArrayGetCount(services),
              let raw = CFArrayGetValueAtIndex(services, index)
        else { return nil }
        let service = UnsafeMutableRawPointer(mutating: raw)
        guard let event = api.copyEvent(service, eventType, 0, 0) else { return nil }
        let value = api.getFloat(event, Int32(eventType << 16))
        Unmanaged<CFTypeRef>.fromOpaque(event).release()
        return value.isFinite ? value : nil
    }

    private func hidServiceArray(page: Int, usage: Int, slot: HIDSlot, api: HIDAPI) -> CFArray? {
        switch slot {
        case .temperature:
            return extraServices(page: page, usage: usage, cache: &temperatureHID, api: api)
        case .voltage:
            return extraServices(page: page, usage: usage, cache: &voltageHID, api: api)
        case .current:
            return extraServices(page: page, usage: usage, cache: &currentHID, api: api)
        }
    }

    private func extraServices(page: Int, usage: Int, cache: inout HIDCache, api: HIDAPI) -> CFArray? {
        if cache.client == nil {
            cache.client = api.create(kCFAllocatorDefault, 0)
            guard let client = cache.client else { return nil }
            api.setMatching(client, ["PrimaryUsagePage": page, "PrimaryUsage": usage] as CFDictionary)
        }
        guard let client = cache.client else { return nil }
        if cache.services == nil {
            cache.services = api.copyServices(client)
            cache.fetchedAt = DispatchTime.now().uptimeNanoseconds
        }
        guard let services = cache.services else { return nil }
        return Unmanaged<CFArray>.fromOpaque(services).takeUnretainedValue()
    }

    private func releaseHID(_ cache: inout HIDCache) {
        if let services = cache.services {
            Unmanaged<CFArray>.fromOpaque(services).release()
            cache.services = nil
        }
        if let client = cache.client {
            Unmanaged<CFTypeRef>.fromOpaque(client).release()
            cache.client = nil
        }
    }

    private static func average(_ values: [Double]) -> Double? {
        let valid = values.filter { $0 > 0 && $0 <= 130 }
        guard !valid.isEmpty else { return nil }
        return valid.reduce(0, +) / Double(valid.count)
    }

    // MARK: AppleSMC

    /// Classic 80-byte SMCKeyData_t. Layout matches the kernel user-client.
    private struct SMCKeyData {
        var key: UInt32 = 0
        var vers = Version()
        var pLimit = PLimit()
        var keyInfo = KeyInfo()
        var result: UInt8 = 0
        var status: UInt8 = 0
        var data8: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: (
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
        ) = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)

        struct Version {
            var major: UInt8 = 0
            var minor: UInt8 = 0
            var build: UInt8 = 0
            var reserved: UInt8 = 0
            var release: UInt16 = 0
        }

        struct PLimit {
            var version: UInt16 = 0
            var length: UInt16 = 0
            var cpuPLimit: UInt32 = 0
            var gpuPLimit: UInt32 = 0
            var memPLimit: UInt32 = 0
        }

        struct KeyInfo {
            var dataSize: UInt32 = 0
            var dataType: UInt32 = 0
            var dataAttributes: UInt8 = 0
            // C sizeof includes tail padding to the struct's 4-byte alignment. Swift does not,
            // so the three bytes are explicit or the kernel sees a 76-byte record.
            var padding: (UInt8, UInt8, UInt8) = (0, 0, 0)
        }
    }

    private func openSMC() -> Bool {
        if smc != 0 { return true }
        if smcOpenAttempted { return false }
        smcOpenAttempted = true
        guard MemoryLayout<SMCKeyData>.size == 80 else { return false }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        var connection: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS else { return false }
        smc = connection
        return true
    }

    private func smcCall(_ input: inout SMCKeyData, _ output: inout SMCKeyData) -> Bool {
        let inputSize = MemoryLayout<SMCKeyData>.size
        var outputSize = MemoryLayout<SMCKeyData>.size
        let result = withUnsafePointer(to: &input) { inputPointer in
            withUnsafeMutablePointer(to: &output) { outputPointer in
                IOConnectCallStructMethod(smc, 2, inputPointer, inputSize, outputPointer, &outputSize)
            }
        }
        return result == KERN_SUCCESS
    }

    /// Selector 2, data8 9 then 5: key info, then the bytes.
    private func readSMC(_ key: String) -> (type: String, data: [UInt8])? {
        guard openSMC(), key.utf8.count == 4 else { return nil }
        var input = SMCKeyData()
        input.key = Self.fourCC(key)
        input.data8 = 9
        var info = SMCKeyData()
        guard smcCall(&input, &info), info.result == 0 else { return nil }
        let size = Int(info.keyInfo.dataSize)
        guard size > 0, size <= 32 else { return nil }

        input = SMCKeyData()
        input.key = Self.fourCC(key)
        input.data8 = 5
        input.keyInfo.dataSize = info.keyInfo.dataSize
        var output = SMCKeyData()
        guard smcCall(&input, &output), output.result == 0 else { return nil }
        let bytes = withUnsafeBytes(of: output.bytes) { Array($0.prefix(size)) }
        return (Self.fourCCString(info.keyInfo.dataType), bytes)
    }

    private func smcTemperature(_ key: String) -> Double? {
        guard let reading = readSMC(key) else { return nil }
        guard reading.type == "sp78", reading.data.count >= 2 else { return nil }
        let raw = Int16(bitPattern: (UInt16(reading.data[0]) << 8) | UInt16(reading.data[1]))
        let value = Double(raw) / 256
        guard value > 0, value <= 130 else { return nil }
        return value
    }

    private func smcFans() -> [SensorStats.Fan] {
        guard let countReading = readSMC("FNum"), let count = Self.unsignedByte(countReading) else { return [] }
        var fans: [SensorStats.Fan] = []
        for index in 0..<count {
            guard let actual = readSMC(String(format: "F%dAc", index)), let rpm = Self.fanRPM(actual) else { continue }
            let minRPM = readSMC(String(format: "F%dMn", index)).flatMap(Self.fanRPM)
            let maxRPM = readSMC(String(format: "F%dMx", index)).flatMap(Self.fanRPM)
            let name = readSMC(String(format: "F%dID", index)).flatMap(Self.fanName) ?? "Fan \(index + 1)"
            fans.append(SensorStats.Fan(name: name, rpm: rpm, minRPM: minRPM, maxRPM: maxRPM))
        }
        return fans
    }

    private static func unsignedByte(_ reading: (type: String, data: [UInt8])) -> Int? {
        guard let byte = reading.data.first else { return nil }
        return Int(byte)
    }

    private static func fanRPM(_ reading: (type: String, data: [UInt8])) -> Double? {
        switch reading.type {
        case "flt ":
            guard reading.data.count >= 4 else { return nil }
            let value = reading.data.withUnsafeBytes { $0.load(as: Float.self) }
            guard value.isFinite, value >= 0 else { return nil }
            return Double(value)
        case "fpe2":
            guard reading.data.count >= 2 else { return nil }
            let raw = (UInt16(reading.data[0]) << 8) | UInt16(reading.data[1])
            return Double(raw) / 4
        default:
            return nil
        }
    }

    private static func fanName(_ reading: (type: String, data: [UInt8])) -> String? {
        let text = reading.data.prefix { $0 >= 32 && $0 < 127 }
        guard !text.isEmpty, let name = String(bytes: text, encoding: .utf8), !name.isEmpty else { return nil }
        return name
    }

    private static func fourCC(_ key: String) -> UInt32 {
        var code: UInt32 = 0
        for byte in key.utf8 {
            code = (code << 8) | UInt32(byte)
        }
        return code
    }

    private func loadWatchedKeys() -> [WatchedKey] {
        if let watchedKeys { return watchedKeys }
        var list: [WatchedKey] = []
        guard openSMC(), let countReading = readSMC("#KEY"), let total = Self.unsigned32(countReading) else {
            watchedKeys = []
            return []
        }
        let limit = min(total, 8192)
        for index in 0..<limit {
            guard let key = smcKeyAtIndex(index), let first = key.first, "PVIT".contains(first) else { continue }
            guard let info = smcKeyInfo(key), Self.smcTypes.contains(info.type) else { continue }
            let kind: SensorReading.Kind
            switch first {
            case "T": kind = .temperature
            case "V": kind = .voltage
            case "I": kind = .current
            case "P": kind = .power
            default: continue
            }
            list.append(WatchedKey(key: key, type: info.type, size: info.size, kind: kind))
        }
        watchedKeys = list
        return list
    }

    private func smcSensorReadings() -> [SensorReading] {
        let keys = liveKeys ?? loadWatchedKeys()
        var live: [WatchedKey] = []
        var readings: [SensorReading] = []
        let partitioning = liveKeys == nil
        for watched in keys {
            guard let bytes = readSMCBytes(key: watched.key, size: watched.size),
                  let value = Self.decodeSMC(type: watched.type, data: bytes),
                  Self.plausible(value, kind: watched.kind)
            else { continue }
            let label = Self.smcLabel(watched.key, kind: watched.kind)
            let reading = SensorReading(id: watched.key, name: label.name, group: label.group, kind: watched.kind, value: value)
            let idle = watched.kind != .temperature && value == 0
            if partitioning && idle {
                idleSMC.append(reading)
            } else {
                if partitioning {
                    live.append(watched)
                    refreshQueue.append(Refresh(id: watched.key, source: .smc(key: watched.key, size: watched.size, type: watched.type)))
                }
                readings.append(reading)
            }
        }
        if partitioning { liveKeys = live }
        readings.append(contentsOf: idleSMC)
        return readings
    }

    private func smcKeyAtIndex(_ index: Int) -> String? {
        guard openSMC() else { return nil }
        var input = SMCKeyData()
        input.data8 = 8
        input.data32 = UInt32(index)
        var output = SMCKeyData()
        guard smcCall(&input, &output), output.result == 0 else { return nil }
        let key = Self.fourCCString(output.key)
        guard key.utf8.count == 4, key.utf8.allSatisfy({ $0 >= 32 && $0 < 127 }) else { return nil }
        return key
    }

    private func smcKeyInfo(_ key: String) -> (type: String, size: UInt32)? {
        guard openSMC(), key.utf8.count == 4 else { return nil }
        var input = SMCKeyData()
        input.key = Self.fourCC(key)
        input.data8 = 9
        var info = SMCKeyData()
        guard smcCall(&input, &info), info.result == 0 else { return nil }
        let size = info.keyInfo.dataSize
        guard size > 0, size <= 32 else { return nil }
        return (Self.fourCCString(info.keyInfo.dataType), size)
    }

    private func readSMCBytes(key: String, size: UInt32) -> [UInt8]? {
        guard openSMC(), key.utf8.count == 4, size > 0, size <= 32 else { return nil }
        var input = SMCKeyData()
        input.key = Self.fourCC(key)
        input.data8 = 5
        input.keyInfo.dataSize = size
        var output = SMCKeyData()
        guard smcCall(&input, &output), output.result == 0 else { return nil }
        let count = Int(size)
        return withUnsafeBytes(of: output.bytes) { Array($0.prefix(count)) }
    }

    private static let smcTypes: Set<String> = ["flt ", "sp78", "ui8 ", "ui16", "ui32"]

    private static func unsigned32(_ reading: (type: String, data: [UInt8])) -> Int? {
        guard reading.type == "ui32", reading.data.count >= 4 else { return nil }
        let value = reading.data.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        return Int(value)
    }

    private static func decodeSMC(type: String, data: [UInt8]) -> Double? {
        switch type {
        case "flt ":
            guard data.count >= 4 else { return nil }
            let value = data.withUnsafeBytes { $0.load(as: Float.self) }
            guard value.isFinite else { return nil }
            return Double(value)
        case "sp78":
            guard data.count >= 2 else { return nil }
            let raw = Int16(bitPattern: (UInt16(data[0]) << 8) | UInt16(data[1]))
            return Double(raw) / 256
        case "ui8 ":
            guard let byte = data.first else { return nil }
            return Double(byte)
        case "ui16":
            guard data.count >= 2 else { return nil }
            return Double((UInt16(data[0]) << 8) | UInt16(data[1]))
        case "ui32":
            guard data.count >= 4 else { return nil }
            let value = data.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            return Double(value)
        default:
            return nil
        }
    }

    private static func plausible(_ value: Double, kind: SensorReading.Kind) -> Bool {
        switch kind {
        case .temperature: return value >= 1 && value <= 130
        case .voltage: return value >= 0 && value <= 30
        case .current: return value >= 0 && value <= 20
        case .power: return value >= 0 && value <= 300
        case .fan: return value >= 0 && value <= 20000
        }
    }

    private static func smcLabel(_ key: String, kind: SensorReading.Kind) -> (name: String, group: String) {
        if let known = smcNames[key] { return known }
        return (key, smcGroup(key, kind: kind))
    }

    private static func smcGroup(_ key: String, kind: SensorReading.Kind) -> String {
        if key.hasPrefix("TB") || key == "PPBR" || key == "IPBR" || key == "IBAC" { return "Battery" }
        if key.hasPrefix("Tg") || key.hasPrefix("TG") { return "GPU" }
        if key.hasPrefix("Tm") || key.hasPrefix("TM") || key.hasPrefix("PMV") || key.hasPrefix("VM") { return "Memory" }
        if key == "VD0R" || key == "ID0R" || key == "PDTR" || key == "VP0R" || key.hasPrefix("Vb") { return "Power supply" }
        if key.hasPrefix("TH") || key.hasPrefix("TH0") { return "SSD" }
        if key.hasPrefix("Tp") || key.hasPrefix("Te") || key.hasPrefix("TC") || key.hasPrefix("Tf") { return "CPU" }
        if key.hasPrefix("VC") || key.hasPrefix("PC") || key.hasPrefix("IC") { return "CPU" }
        if key.hasPrefix("VG") || key.hasPrefix("PG") || key.hasPrefix("IG") { return "GPU" }
        if kind == .fan { return "Other" }
        return "Other"
    }

    /// Well-known AppleSMC keys. Unknown keys keep the raw four-character name.
    private static let smcNames: [String: (name: String, group: String)] = [
        "TC0D": ("CPU diode", "CPU"),
        "TC0E": ("CPU diode virtual", "CPU"),
        "TC0F": ("CPU diode filtered", "CPU"),
        "TC0H": ("CPU heatsink", "CPU"),
        "TC0P": ("CPU proximity", "CPU"),
        "TCAD": ("CPU package", "CPU"),
        "TG0D": ("GPU diode", "GPU"),
        "TG0H": ("GPU heatsink", "GPU"),
        "TG0P": ("GPU proximity", "GPU"),
        "TGDD": ("GPU AMD Radeon", "GPU"),
        "TB0T": ("Battery", "Battery"),
        "TB1T": ("Battery 1", "Battery"),
        "TB2T": ("Battery 2", "Battery"),
        "TH0x": ("NAND", "SSD"),
        "TW0P": ("Airport", "Other"),
        "TL0P": ("Display", "Other"),
        "TaLP": ("Airflow left", "Other"),
        "TaRF": ("Airflow right", "Other"),
        "Ts0P": ("Palm rest", "Other"),
        "VD0R": ("DC In", "Power supply"),
        "VP0R": ("12V rail", "Power supply"),
        "Vp0C": ("12V vcc", "Power supply"),
        "VM0R": ("Memory", "Memory"),
        "VCAC": ("CPU IA", "CPU"),
        "VCSC": ("CPU system agent", "CPU"),
        "VG0C": ("GPU", "GPU"),
        "ID0R": ("DC In", "Power supply"),
        "IBAC": ("Battery", "Battery"),
        "IC0R": ("CPU high side", "CPU"),
        "IG0R": ("GPU high side", "GPU"),
        "PDTR": ("DC In", "Power supply"),
        "PPBR": ("Battery", "Battery"),
        "PSTR": ("System total", "Other"),
        "PCPT": ("CPU package total", "CPU"),
        "PCTR": ("CPU total", "CPU"),
        "PC0C": ("CPU core", "CPU"),
        "PG0C": ("GPU", "GPU"),
        "PG0R": ("GPU 1", "GPU"),
        "PMTR": ("Memory total", "Memory"),
        "PMVR": ("Memory", "Memory"),
        "PDBR": ("Display backlight", "Other"),
    ]

    private static func hidLabel(_ product: String, kind: SensorReading.Kind) -> (name: String, group: String) {
        if let number = trailingNumber(product, prefix: "pACC MTR Temp Sensor") {
            return ("CPU performance core \(number)", "CPU")
        }
        if let number = trailingNumber(product, prefix: "eACC MTR Temp Sensor") {
            return ("CPU efficiency core \(number)", "CPU")
        }
        if let number = trailingNumber(product, prefix: "GPU MTR Temp Sensor") {
            return ("GPU core \(number)", "GPU")
        }
        if let number = trailingNumber(product, prefix: "SOC MTR Temp Sensor") {
            return ("SOC core \(number)", "Other")
        }
        if let number = trailingNumber(product, prefix: "ANE MTR Temp Sensor") {
            return ("Neural engine \(number)", "Other")
        }
        if let number = trailingNumber(product, prefix: "ISP MTR Temp Sensor") {
            return ("Image signal processor \(number)", "Other")
        }
        if let number = trailingNumber(product, prefix: "PMGR SOC Die Temp Sensor") {
            return ("Power manager die \(number)", "Other")
        }
        if let number = trailingNumber(product, prefix: "PMU tdie") {
            return ("CPU die \(number)", "CPU")
        }
        if let number = trailingNumber(product, prefix: "PMU tdev") {
            return ("PMU device \(number)", "Other")
        }
        if product == "gas gauge battery" || product == "Battery" {
            return ("Battery", "Battery")
        }
        if product.hasPrefix("NAND CH"), let number = leadingInt(product.dropFirst("NAND CH".count)) {
            return ("Disk \(number)", "SSD")
        }
        if product == "als-temp" { return ("Ambient light", "Other") }
        if product == "PMU tcal" { return ("PMU calibration", "Other") }
        if let number = trailingNumber(product, prefix: "PMU vbuck") ?? trailingNumber(product, prefix: "PMU ibuck") {
            let noun = kind == .current ? "current" : "voltage"
            return ("PMU buck \(number) \(noun)", "Power supply")
        }
        if let number = trailingNumber(product, prefix: "PMU vldo") ?? trailingNumber(product, prefix: "PMU ildo") {
            let noun = kind == .current ? "current" : "voltage"
            return ("PMU LDO \(number) \(noun)", "Power supply")
        }
        if product.hasPrefix("PMU TP") { return (product, "CPU") }
        if product.hasPrefix("PMU") { return (product, kind == .temperature ? "Other" : "Power supply") }
        return (product, "Other")
    }

    private static func trailingNumber(_ product: String, prefix: String) -> Int? {
        guard product.hasPrefix(prefix) else { return nil }
        return leadingInt(product.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces))
    }

    private static func leadingInt<S: StringProtocol>(_ text: S) -> Int? {
        let digits = text.prefix { $0.isNumber }
        guard !digits.isEmpty else { return nil }
        return Int(digits)
    }

    private static func fourCCString(_ code: UInt32) -> String {
        let bytes = [
            UInt8((code >> 24) & 0xff),
            UInt8((code >> 16) & 0xff),
            UInt8((code >> 8) & 0xff),
            UInt8(code & 0xff),
        ]
        return String(bytes: bytes, encoding: .ascii) ?? ""
    }
}
