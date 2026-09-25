import Foundation
import IOKit

/// One physical drive (APFS volumes that share a store are one row) at one sample.
public struct DriveInfo: Sendable, Identifiable, Hashable {
    public let id: String
    public let name: String
    public let mountPoints: [String]
    public let isInternal: Bool
    public let isRemovable: Bool
    public let model: String?
    public let total: UInt64
    public let free: UInt64
    public let readRate: Double
    public let writeRate: Double
    public let smartStatus: String?
    public let nvmeHealth: NVMeHealth?

    public init(id: String, name: String, mountPoints: [String], isInternal: Bool, isRemovable: Bool, model: String?, total: UInt64, free: UInt64, readRate: Double, writeRate: Double, smartStatus: String?, nvmeHealth: NVMeHealth?) {
        self.id = id
        self.name = name
        self.mountPoints = mountPoints
        self.isInternal = isInternal
        self.isRemovable = isRemovable
        self.model = model
        self.total = total
        self.free = free
        self.readRate = readRate
        self.writeRate = writeRate
        self.smartStatus = smartStatus
        self.nvmeHealth = nvmeHealth
    }
}

/// NVMe SMART log attributes, when the registry or the unprivileged user client exposes them.
public struct NVMeHealth: Sendable, Hashable {
    public let percentageUsed: Int?
    public let temperatureC: Double?
    public let powerOnHours: Int?
    public let dataWrittenTB: Double?

    public init(percentageUsed: Int?, temperatureC: Double?, powerOnHours: Int?, dataWrittenTB: Double?) {
        self.percentageUsed = percentageUsed
        self.temperatureC = temperatureC
        self.powerOnHours = powerOnHours
        self.dataWrittenTB = dataWrittenTB
    }
}

/// Per-drive capacity, mount points and throughput. Volume metadata is refreshed at most every 10 seconds;
/// byte counters are read on every call.
public final class DrivesSampler {
    public init() {}

    private var cached: [DriveMeta] = []
    private var refreshedAt = Date.distantPast
    private var previous: [String: (read: UInt64, write: UInt64, time: UInt64)] = [:]

    public func sample() -> [DriveInfo] {
        let now = DispatchTime.now().uptimeNanoseconds
        if cached.isEmpty || Date().timeIntervalSince(refreshedAt) >= 10 {
            cached = Self.inventory()
            refreshedAt = Date()
        }
        let counters = Self.byteCounters()
        var infos: [DriveInfo] = []
        infos.reserveCapacity(cached.count)
        for meta in cached {
            var readRate = 0.0
            var writeRate = 0.0
            if let totals = counters[meta.counterKey], let prev = previous[meta.counterKey], prev.time > 0, now > prev.time {
                let elapsed = Double(now - prev.time) / 1_000_000_000
                if totals.read >= prev.read, totals.write >= prev.write, elapsed > 0 {
                    readRate = Double(totals.read - prev.read) / elapsed
                    writeRate = Double(totals.write - prev.write) / elapsed
                }
            }
            if let totals = counters[meta.counterKey] {
                previous[meta.counterKey] = (totals.read, totals.write, now)
            }
            infos.append(DriveInfo(
                id: meta.id, name: meta.name, mountPoints: meta.mountPoints,
                isInternal: meta.isInternal, isRemovable: meta.isRemovable, model: meta.model,
                total: meta.total, free: meta.free, readRate: readRate, writeRate: writeRate,
                smartStatus: meta.smartStatus, nvmeHealth: meta.nvmeHealth
            ))
        }
        return infos
    }

    // MARK: Inventory

    private struct DriveMeta {
        var id: String
        var name: String
        var mountPoints: [String]
        var isInternal: Bool
        var isRemovable: Bool
        var model: String?
        var total: UInt64
        var free: UInt64
        var smartStatus: String?
        var nvmeHealth: NVMeHealth?
        var counterKey: String
    }

    private struct Media {
        var entry: io_registry_entry_t
        var bsd: String
        var whole: Bool
        var size: UInt64
        var removable: Bool
        var className: String
        var content: String
    }

    private struct Mount {
        var dev: String
        var path: String
    }

    /// Volumes the user does not see as their own drive (Stats skips these too).
    private static let hiddenNames: Set<String> = [
        "Preboot", "Recovery", "VM", "Update", "xART", "XART", "Hardware", "iSCPreboot",
        "iBootSystemContainer", "xarts"
    ]

    private static func inventory() -> [DriveMeta] {
        let medias = allMedia()
        defer { medias.forEach { IOObjectRelease($0.entry) } }

        var byBSD: [String: Media] = [:]
        for media in medias { byBSD[media.bsd] = media }

        // Synthesized APFS container (disk3) → the physical whole disk that stores it (disk0).
        var physicalOf: [String: String] = [:]
        for media in medias where media.whole && isAPFSContainer(media) {
            if let physical = physicalStore(of: media.entry, medias: byBSD) {
                physicalOf[media.bsd] = physical
            }
        }

        let mounts = mountedVolumes()
        var mountsByDrive: [String: [Mount]] = [:]
        for mount in mounts {
            let whole = wholeBSD(mount.dev)
            let drive = physicalOf[whole] ?? whole
            mountsByDrive[drive, default: []].append(mount)
        }

        var drives: [DriveMeta] = []
        var seen = Set<String>()

        for media in medias where media.whole && !isAPFSContainer(media) {
            let image = isDiskImage(media.entry)
            let userMounts = (mountsByDrive[media.bsd] ?? []).filter { isUserVisible($0) }
            if image && userMounts.isEmpty { continue }
            if !image && !media.removable && userMounts.isEmpty && media.size < 8 * 1024 * 1024 * 1024 {
                // Tiny internal stores that only host iBoot / recovery containers.
                continue
            }
            seen.insert(media.bsd)
            drives.append(makeDrive(media, userMounts: userMounts, image: image))
        }

        // A disk image that is only an APFS container still needs a row when it is mounted for the user.
        for (container, physical) in physicalOf where !seen.contains(physical) {
            guard let media = byBSD[physical] ?? byBSD[container] else { continue }
            let image = isDiskImage(media.entry) || isDiskImage(byBSD[container]?.entry ?? media.entry)
            let userMounts = (mountsByDrive[physical] ?? []).filter { isUserVisible($0) }
            guard image, !userMounts.isEmpty else { continue }
            seen.insert(physical)
            drives.append(makeDrive(media, userMounts: userMounts, image: true))
        }

        drives.sort { lhs, rhs in
            if lhs.isInternal != rhs.isInternal { return lhs.isInternal }
            return lhs.id < rhs.id
        }
        return drives
    }

    private static func makeDrive(_ media: Media, userMounts: [Mount], image: Bool) -> DriveMeta {
        let ordered = userMounts.sorted { rank($0.path) < rank($1.path) }
        let names = volumeNames(ordered)
        let location = interconnect(media.entry)
        let removable = image || media.removable || location == "External" || location == "File"
        let internalDrive = !image && location != "External" && location != "File" && (location == "Internal" || !removable)
        let (total, free) = capacity(of: ordered, fallback: media.size)
        let health = healthInfo(startingAt: media.entry)
        let label = names.isEmpty ? (health.model ?? media.bsd) : names.joined(separator: ", ")
        return DriveMeta(
            id: media.bsd, name: label, mountPoints: ordered.map(\.path),
            isInternal: internalDrive, isRemovable: removable, model: health.model,
            total: total, free: free, smartStatus: health.smart, nvmeHealth: health.nvme,
            counterKey: media.bsd
        )
    }

    private static func rank(_ path: String) -> String {
        if path == "/" { return "0" }
        if path == "/System/Volumes/Data" { return "1" }
        return "2" + path
    }

    private static func isUserVisible(_ mount: Mount) -> Bool {
        let path = mount.path
        if path == "/" || path == "/System/Volumes/Data" { return true }
        if path.hasPrefix("/Volumes/") { return true }
        return false
    }

    private static func volumeNames(_ mounts: [Mount]) -> [String] {
        var names: [String] = []
        for mount in mounts {
            let url = URL(fileURLWithPath: mount.path)
            let values = try? url.resourceValues(forKeys: [.volumeLocalizedNameKey, .volumeNameKey])
            let raw = values?.volumeLocalizedName ?? values?.volumeName ?? url.lastPathComponent
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty || hiddenNames.contains(name) { continue }
            if !names.contains(name) { names.append(name) }
        }
        return names
    }

    /// Root volume uses purgeable-aware free space. Every other volume uses plain available capacity.
    /// APFS volumes of one container report the same total; summing them would count the store twice.
    private static func capacity(of mounts: [Mount], fallback: UInt64) -> (UInt64, UInt64) {
        struct Cap { var total: UInt64; var available: UInt64; var important: UInt64?; var path: String }
        var caps: [Cap] = []
        for mount in mounts {
            let url = URL(fileURLWithPath: mount.path)
            let keys: Set<URLResourceKey> = [
                .volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey
            ]
            guard let values = try? url.resourceValues(forKeys: keys) else { continue }
            caps.append(Cap(
                total: UInt64(values.volumeTotalCapacity ?? 0),
                available: UInt64(values.volumeAvailableCapacity ?? 0),
                important: values.volumeAvailableCapacityForImportantUsage.map { UInt64($0) },
                path: mount.path
            ))
        }
        guard let largest = caps.max(by: { $0.total < $1.total }), largest.total > 0 else {
            return (fallback, 0)
        }
        if let root = caps.first(where: { $0.path == "/" }) {
            let total = max(root.total, largest.total)
            return (total, root.important ?? root.available)
        }
        let shared = caps.allSatisfy { $0.total == largest.total }
        if shared { return (largest.total, largest.available) }
        return (caps.reduce(0) { $0 + $1.total }, caps.reduce(0) { $0 + $1.available })
    }

    private static func isAPFSContainer(_ media: Media) -> Bool {
        media.className.contains("AppleAPFS")
            || media.content == "EF57347C-0000-11AA-AA11-00306543ECAC"
    }

    private static func physicalStore(of entry: io_registry_entry_t, medias: [String: Media]) -> String? {
        var found: String?
        walkParents(of: entry) { parent in
            guard let bsd = IOKitProperty(parent, "BSD Name") as? String else { return false }
            let whole = wholeBSD(bsd)
            if let media = medias[whole], media.whole, !isAPFSContainer(media) {
                found = whole
                return true
            }
            if let media = medias[bsd], !isAPFSContainer(media), let owner = medias[wholeBSD(bsd)], owner.whole, !isAPFSContainer(owner) {
                found = owner.bsd
                return true
            }
            return false
        }
        return found
    }

    private static func isDiskImage(_ entry: io_registry_entry_t) -> Bool {
        var image = false
        if interconnect(entry) == "File" { return true }
        walkParents(of: entry) { parent in
            let name = copyClass(parent)
            if name.contains("IOHDIX") || name.contains("DiskImage") {
                image = true
                return true
            }
            if let product = IOKitProperty(parent, "Product Name") as? String, product.contains("Disk Image") {
                image = true
                return true
            }
            return false
        }
        return image
    }

    private static func interconnect(_ entry: io_registry_entry_t) -> String {
        var location = ""
        let visit: (io_registry_entry_t) -> Bool = { node in
            if let direct = IOKitProperty(node, "Physical Interconnect Location") as? String {
                location = direct
                return true
            }
            if let proto = IOKitProperty(node, "Protocol Characteristics") as? [String: Any],
               let loc = proto["Physical Interconnect Location"] as? String {
                location = loc
                return true
            }
            return false
        }
        if visit(entry) { return location }
        walkParents(of: entry, body: visit)
        return location
    }

    private struct Health {
        var model: String?
        var smart: String?
        var nvme: NVMeHealth?
    }

    private static func healthInfo(startingAt entry: io_registry_entry_t) -> Health {
        var health = Health()
        let consider: (io_registry_entry_t) -> Void = { node in
            if health.model == nil {
                if let model = trimmed(IOKitProperty(node, "Model Number") as? String) { health.model = model }
                else if let chars = IOKitProperty(node, "Device Characteristics") as? [String: Any],
                        let product = trimmed(chars["Product Name"] as? String) {
                    health.model = product
                }
            }
            if health.smart == nil {
                health.smart = smartString(IOKitProperty(node, "SMART Status"))
            }
            if health.nvme == nil {
                health.nvme = nvmeFromProperties(node)
            }
        }
        consider(entry)
        walkParents(of: entry) { parent in
            consider(parent)
            return false
        }
        if health.nvme == nil {
            let probed = nvmeUserClient(near: entry)
            health.nvme = probed.health
            if health.smart == nil { health.smart = probed.status }
        }
        return health
    }

    private static func smartString(_ value: Any?) -> String? {
        if let text = value as? String { return canonicalSMART(text) }
        if let dict = value as? [String: Any] {
            return smartString(dict["SMART Status"] ?? dict["Status"])
        }
        return nil
    }

    private static func canonicalSMART(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if trimmed.localizedCaseInsensitiveContains("fail") { return "Failing" }
        if trimmed.localizedCaseInsensitiveContains("verif") || trimmed == "OK" { return "Verified" }
        return trimmed
    }

    /// Registry copies of the SMART log. Absent on Apple silicon ANS controllers.
    private static func nvmeFromProperties(_ node: io_registry_entry_t) -> NVMeHealth? {
        guard copyClass(node).contains("NVMe") || IOKitProperty(node, "NVMe SMART Capable") != nil else { return nil }
        let used = number(IOKitProperty(node, "Percentage Used"))
            ?? number(nested(node, "NVMe SMART", "Percentage Used"))
        let temp = number(IOKitProperty(node, "Temperature"))
            ?? number(nested(node, "NVMe SMART", "Temperature"))
        let hours = number(IOKitProperty(node, "Power On Hours"))
            ?? number(nested(node, "NVMe SMART", "Power On Hours"))
        let written = number(IOKitProperty(node, "Data Units Written"))
            ?? number(nested(node, "NVMe SMART", "Data Units Written"))
        return makeNVMe(used: used, kelvin: temp, hours: hours, dataUnits: written)
    }

    private static func nested(_ node: io_registry_entry_t, _ dict: String, _ key: String) -> Any? {
        (IOKitProperty(node, dict) as? [String: Any])?[key]
    }

    private static func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }

    private static func makeNVMe(used: Double?, kelvin: Double?, hours: Double?, dataUnits: Double?) -> NVMeHealth? {
        let percentage = used.map { Int($0) }
        let celsius: Double? = {
            guard let kelvin, kelvin > 0 else { return nil }
            if kelvin > 200 { return kelvin - 273.15 }
            return kelvin
        }()
        let power = hours.map { Int($0) }
        // NVMe data units are 512_000 bytes each.
        let tb = dataUnits.map { $0 * 512_000 / 1e12 }
        if percentage == nil && celsius == nil && power == nil && tb == nil { return nil }
        return NVMeHealth(percentageUsed: percentage, temperatureC: celsius, powerOnHours: power, dataWrittenTB: tb)
    }

    // MARK: Counters

    private static func byteCounters() -> [String: (read: UInt64, write: UInt64)] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS else {
            return [:]
        }
        defer { IOObjectRelease(iterator) }
        var totals: [String: (read: UInt64, write: UInt64)] = [:]
        var service = IOIteratorNext(iterator)
        while service != 0 {
            if let stats = IOKitProperty(service, "Statistics") as? [String: Any], let bsd = driverBSD(service) {
                let read = (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
                let write = (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
                let soFar = totals[bsd] ?? (0, 0)
                totals[bsd] = (soFar.read &+ read, soFar.write &+ write)
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        return totals
    }

    /// The driver's child media carries the BSD name of the whole disk.
    private static func driverBSD(_ driver: io_registry_entry_t) -> String? {
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(driver, kIOServicePlane, &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var child = IOIteratorNext(iterator)
        while child != 0 {
            if let name = IOKitProperty(child, "BSD Name") as? String {
                IOObjectRelease(child)
                return wholeBSD(name)
            }
            IOObjectRelease(child)
            child = IOIteratorNext(iterator)
        }
        return nil
    }

    // MARK: Registry

    private static func allMedia() -> [Media] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOMedia"), &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }
        var list: [Media] = []
        var service = IOIteratorNext(iterator)
        while service != 0 {
            if let bsd = IOKitProperty(service, "BSD Name") as? String {
                let whole = (IOKitProperty(service, "Whole") as? Bool) ?? ((IOKitProperty(service, "Whole") as? NSNumber)?.boolValue ?? false)
                let size = (IOKitProperty(service, "Size") as? NSNumber)?.uint64Value ?? 0
                let removable = (IOKitProperty(service, "Removable") as? Bool) ?? ((IOKitProperty(service, "Removable") as? NSNumber)?.boolValue ?? false)
                list.append(Media(
                    entry: service, bsd: bsd, whole: whole, size: size, removable: removable,
                    className: copyClass(service),
                    content: (IOKitProperty(service, "Content") as? String) ?? ""
                ))
            } else {
                IOObjectRelease(service)
            }
            service = IOIteratorNext(iterator)
        }
        return list
    }

    private static func mountedVolumes() -> [Mount] {
        var buffer: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&buffer, MNT_NOWAIT)
        guard count > 0, let buffer else { return [] }
        var mounts: [Mount] = []
        for index in 0..<Int(count) {
            let info = buffer[index]
            let from = withUnsafeBytes(of: info.f_mntfromname) { raw -> String in
                guard let base = raw.baseAddress else { return "" }
                return String(cString: base.assumingMemoryBound(to: CChar.self))
            }
            guard from.hasPrefix("/dev/disk") else { continue }
            let on = withUnsafeBytes(of: info.f_mntonname) { raw -> String in
                guard let base = raw.baseAddress else { return "" }
                return String(cString: base.assumingMemoryBound(to: CChar.self))
            }
            mounts.append(Mount(dev: String(from.dropFirst(5)), path: on))
        }
        return mounts
    }

    /// "disk12s1" and "disk3s3s1" both belong to the whole disk ("disk12", "disk3").
    private static func wholeBSD(_ name: String) -> String {
        guard name.hasPrefix("disk") else { return name }
        let digits = name.dropFirst(4).prefix { $0.isNumber }
        return "disk" + digits
    }

    private static func walkParents(of entry: io_registry_entry_t, body: (io_registry_entry_t) -> Bool) {
        var current = entry
        var owned = false
        while true {
            var parent: io_registry_entry_t = 0
            if IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) != KERN_SUCCESS { break }
            if owned { IOObjectRelease(current) }
            owned = true
            current = parent
            if body(current) { break }
        }
        if owned { IOObjectRelease(current) }
    }

    private static func copyClass(_ entry: io_registry_entry_t) -> String {
        guard let raw = IOObjectCopyClass(entry)?.takeRetainedValue() else { return "" }
        return raw as String
    }

    private static func trimmed(_ text: String?) -> String? {
        guard let text else { return nil }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    // MARK: NVMe SMART user client (no root)

    private static func nvmeUserClient(near entry: io_registry_entry_t) -> (health: NVMeHealth?, status: String?) {
        var service: io_registry_entry_t = 0
        if hasNVMePlugin(entry) {
            service = entry
            IOObjectRetain(service)
        } else {
            walkParents(of: entry) { parent in
                if hasNVMePlugin(parent) {
                    service = parent
                    IOObjectRetain(service)
                    return true
                }
                return false
            }
        }
        if service == 0 { return (nil, nil) }
        defer { IOObjectRelease(service) }
        return readNVMeSMART(service)
    }

    /// The block device publishes IONVMeSMARTUserClient. Its SMARTReadData is external method 0:
    /// one input scalar, the address of a 4 KB buffer the kernel fills. The COM plugin vtable is
    /// arm64e-signed and cannot be called from Swift, so the user client is opened directly.
    private static func hasNVMePlugin(_ entry: io_registry_entry_t) -> Bool {
        let name = copyClass(entry)
        return name.contains("NVMe") && name.contains("Block")
    }

    private static func readNVMeSMART(_ service: io_service_t) -> (NVMeHealth?, String?) {
        var connection: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS else { return (nil, nil) }
        defer { IOServiceClose(connection) }

        let buffer = UnsafeMutableRawPointer.allocate(byteCount: 4096, alignment: 16)
        defer { buffer.deallocate() }
        buffer.initializeMemory(as: UInt8.self, repeating: 0, count: 4096)
        var address = UInt64(UInt(bitPattern: buffer))
        guard IOConnectCallScalarMethod(connection, 0, &address, 1, nil, nil) == KERN_SUCCESS else { return (nil, nil) }

        let bytes = Array(UnsafeBufferPointer(start: buffer.assumingMemoryBound(to: UInt8.self), count: 512))
        let temperature = UInt16(bytes[1]) | (UInt16(bytes[2]) << 8)
        guard temperature > 1 || bytes[5] != 0 || loadUInt64(bytes, 128) != 0 else { return (nil, nil) }
        let health = NVMeHealth(
            percentageUsed: Int(bytes[5]),
            temperatureC: temperature > 0 ? Double(temperature) - 273.15 : nil,
            powerOnHours: Int(loadUInt64(bytes, 128)),
            dataWrittenTB: Double(loadUInt64(bytes, 48)) * 512_000 / 1e12
        )
        return (health, bytes[0] == 0 ? "Verified" : "Failing")
    }

    private static func loadUInt64(_ bytes: [UInt8], _ offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for index in 0..<8 {
            value |= UInt64(bytes[offset + index]) << (8 * index)
        }
        return value
    }
}
