import Darwin
import Foundation
import IOKit

/// Two sources: Apple-silicon die temperatures come from the private HID event
/// system (usage page 0xFF00 / usage 5). Fan RPM, and Intel CPU/GPU temperatures
/// when HID has no reading, come from the AppleSMC user client.

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

    deinit {
        if smc != 0 {
            IOServiceClose(smc)
            smc = 0
        }
        releaseServices()
        if let hidClient {
            Unmanaged<CFTypeRef>.fromOpaque(hidClient).release()
        }
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
            let name = readSMC(String(format: "F%dID", index)).flatMap(Self.fanName) ?? "Fan \(index)"
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
