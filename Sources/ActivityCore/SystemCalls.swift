import Darwin
import Foundation

/// Small, typed wrappers around sysctl and mach so the samplers stay readable.
enum Sys {
    /// Nanoseconds per mach tick. 1 on Intel, 125/3 on Apple silicon.
    static let nanosPerTick: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom)
    }()

    static let pageSize = UInt64(vm_kernel_page_size)

    static func sysctlInt(_ name: String) -> Int? {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        // Some keys are 32-bit; sysctl writes only `size` bytes.
        if size == 4 { return Int(Int32(truncatingIfNeeded: value)) }
        return Int(value)
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var chars = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &chars, &size, nil, 0) == 0 else { return nil }
        return String(cString: chars)
    }

    static var bootTime: Date {
        var tv = timeval()
        var size = MemoryLayout<timeval>.size
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        guard Darwin.sysctl(&mib, 2, &tv, &size, nil, 0) == 0 else { return Date() }
        return Date(timeIntervalSince1970: TimeInterval(tv.tv_sec) + TimeInterval(tv.tv_usec) / 1_000_000)
    }

    static var physicalMemory: UInt64 { UInt64(sysctlInt("hw.memsize") ?? 0) }

    static var chipName: String {
        sysctlString("machdep.cpu.brand_string") ?? "Mac"
    }
}
