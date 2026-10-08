import Foundation
import IOKit

/// Finds USB drives that could run at USB 3 speed but are connected at USB 2 speed or slower,
/// almost always because of the cable, a hub or the port. Read from the IORegistry, nothing changes.
public enum USBLinkCheck {
    public struct SlowLink: Sendable, Hashable, Identifiable {
        public let name: String
        /// What the device supports (bcdUSB, e.g. "USB 3.2").
        public let supports: String
        /// What it is connected at now (e.g. "USB 2 · 480 Mbit/s").
        public let connected: String
        public var id: String { name + connected }
    }

    /// IOKit "Device Speed": 0 low, 1 full, 2 high (USB 2), 3 super (5 Gbit/s), 4 super+ (10), 5 super+ 2×2 (20).
    public static func isSlow(bcdUSB: Int, deviceSpeed: Int) -> Bool {
        bcdUSB >= 0x0300 && deviceSpeed <= 2
    }

    static func describe(speed: Int) -> String {
        switch speed {
        case 0: String(localized: "USB 1 · 1.5 Mbit/s")
        case 1: String(localized: "USB 1 · 12 Mbit/s")
        case 2: String(localized: "USB 2 · 480 Mbit/s")
        case 3: String(localized: "USB 3 · 5 Gbit/s")
        case 4: String(localized: "USB 3 · 10 Gbit/s")
        default: "USB 3 · 20 Gbit/s"
        }
    }

    static func describe(bcdUSB: Int) -> String {
        let major = (bcdUSB >> 8) & 0xFF, minor = (bcdUSB >> 4) & 0xF
        return "USB \(major).\(minor)"
    }

    public static func slowStorage() -> [SlowLink] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var result: [SlowLink] = []
        var device = IOIteratorNext(iterator)
        while device != 0 {
            defer { IOObjectRelease(device); device = IOIteratorNext(iterator) }
            guard let bcd = (IOKitProperty(device, "bcdUSB") as? NSNumber)?.intValue,
                  let speed = (IOKitProperty(device, "Device Speed") as? NSNumber)?.intValue,
                  isSlow(bcdUSB: bcd, deviceSpeed: speed), hasStorage(below: device)
            else { continue }
            let name = (IOKitProperty(device, "USB Product Name") as? String)
                ?? (IOKitProperty(device, "kUSBProductString") as? String) ?? "USB drive"
            result.append(SlowLink(name: name, supports: describe(bcdUSB: bcd), connected: describe(speed: speed)))
        }
        return result
    }

    /// True when a disk hangs off this device (mass storage, UAS or an SD card reader with a card).
    private static func hasStorage(below device: io_object_t) -> Bool {
        var children: io_iterator_t = 0
        guard IORegistryEntryCreateIterator(device, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &children) == KERN_SUCCESS
        else { return false }
        defer { IOObjectRelease(children) }
        var child = IOIteratorNext(children)
        while child != 0 {
            let isDisk = IOObjectConformsTo(child, "IOBlockStorageDevice") != 0
            IOObjectRelease(child)
            if isDisk { return true }
            child = IOIteratorNext(children)
        }
        return false
    }
}
