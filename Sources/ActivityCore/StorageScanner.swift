import Darwin
import Foundation

public struct StorageLocation: Sendable, Identifiable, Hashable {
    public enum Kind: String, Sendable {
        case bundle
        case applicationSupport
        case caches
        case containers
        case groupContainers
        case logs
        case savedState
        case preferences
        case webData
        case developer
        case other
    }

    public let path: String
    public let kind: Kind
    public let bytes: UInt64
    public let isSafeToClean: Bool
    public var id: String { path }

    public init(path: String, kind: Kind, bytes: UInt64, isSafeToClean: Bool) {
        self.path = path
        self.kind = kind
        self.bytes = bytes
        self.isSafeToClean = isSafeToClean
    }
}

public struct AppDiskUsage: Sendable, Identifiable, Hashable {
    public let id: String
    public let name: String
    public let bundlePath: String?
    public let bundleID: String?
    public let lastUsed: Date?
    public var locations: [StorageLocation]

    public var totalBytes: UInt64 { locations.reduce(0) { $0 + $1.bytes } }
    public var cleanableBytes: UInt64 { locations.filter(\.isSafeToClean).reduce(0) { $0 + $1.bytes } }

    public init(id: String, name: String, bundlePath: String?, bundleID: String?, lastUsed: Date?, locations: [StorageLocation]) {
        self.id = id
        self.name = name
        self.bundlePath = bundlePath
        self.bundleID = bundleID
        self.lastUsed = lastUsed
        self.locations = locations
    }
}

/// How much space each installed app takes, including its data, plus developer caches.
public final class StorageScanner: @unchecked Sendable {
    private struct DevCache {
        let id: String
        let name: String
        let path: String
        let safe: Bool
    }

    private var lock = os_unfair_lock()
    private var cancelled = false
    private let home: URL
    private let fileManager = FileManager.default

    public init() {
        home = fileManager.homeDirectoryForCurrentUser
    }

    public func cancel() {
        os_unfair_lock_lock(&lock)
        cancelled = true
        os_unfair_lock_unlock(&lock)
    }

    public func scan(progress: @escaping @Sendable (Double, String) -> Void) -> [AppDiskUsage] {
        os_unfair_lock_lock(&lock)
        cancelled = false
        os_unfair_lock_unlock(&lock)

        let bundles = applicationBundles()
        let devCaches = Self.developerCaches(home: home)
        let steps = max(bundles.count + devCaches.count, 1)
        var results: [AppDiskUsage] = []
        results.reserveCapacity(steps)

        for (index, bundle) in bundles.enumerated() {
            if isCancelled { break }
            let info = Self.bundleInfo(at: bundle)
            progress(Double(index) / Double(steps), info.name)
            let locations = locations(for: info, bundle: bundle)
            guard !locations.isEmpty else { continue }
            results.append(AppDiskUsage(
                id: bundle.path,
                name: info.name,
                bundlePath: bundle.path,
                bundleID: info.bundleID,
                lastUsed: Self.contentAccessDate(of: bundle),
                locations: locations
            ))
        }

        if !isCancelled {
            for (offset, cache) in devCaches.enumerated() {
                if isCancelled { break }
                progress(Double(bundles.count + offset) / Double(steps), cache.name)
                guard let location = measure(
                    path: cache.path,
                    kind: .developer,
                    safe: cache.safe
                ) else { continue }
                results.append(AppDiskUsage(
                    id: cache.id,
                    name: cache.name,
                    bundlePath: nil,
                    bundleID: nil,
                    lastUsed: nil,
                    locations: [location]
                ))
            }
        }

        progress(1, "")
        results.sort { $0.totalBytes > $1.totalBytes }
        return results
    }

    /// Moves the given locations to the Trash. Never deletes permanently.
    public static func moveToTrash(_ locations: [StorageLocation]) -> (freed: UInt64, failures: [String: String]) {
        var freed: UInt64 = 0
        var failures: [String: String] = [:]
        let fileManager = FileManager.default
        for location in locations {
            let url = URL(fileURLWithPath: location.path)
            do {
                try fileManager.trashItem(at: url, resultingItemURL: nil)
                freed += location.bytes
            } catch {
                failures[location.path] = error.localizedDescription
            }
        }
        return (freed, failures)
    }

    // MARK: - Discovery

    private struct BundleInfo {
        var name: String
        var bundleID: String?
    }

    private func applicationBundles() -> [URL] {
        let roots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/Applications/Utilities", isDirectory: true),
            home.appendingPathComponent("Applications", isDirectory: true),
        ]
        var found: [URL] = []
        var seen = Set<String>()
        for root in roots {
            collectApps(in: root, depth: 0, into: &found, seen: &seen)
        }
        return found
    }

    private func collectApps(in directory: URL, depth: Int, into found: inout [URL], seen: inout Set<String>) {
        if directory.path == "/System" || directory.path.hasPrefix("/System/") { return }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let children = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return }

        for child in children {
            if isCancelled { return }
            let path = child.path
            if path == "/System" || path.hasPrefix("/System/") { continue }
            let values = try? child.resourceValues(forKeys: Set(keys))
            let isLink = values?.isSymbolicLink == true
            let isDir = values?.isDirectory == true || isLink
            if child.pathExtension == "app" {
                let resolved = isLink ? child.resolvingSymlinksInPath() : child
                let key = resolved.standardizedFileURL.path
                if resolved.pathExtension == "app", seen.insert(key).inserted {
                    found.append(resolved)
                }
                continue
            }
            if depth == 0, isDir, !isLink {
                collectApps(in: child, depth: 1, into: &found, seen: &seen)
            }
        }
    }

    private static func bundleInfo(at bundle: URL) -> BundleInfo {
        let fallback = bundle.deletingPathExtension().lastPathComponent
        let plistURL = bundle.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let info = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        else {
            return BundleInfo(name: fallback, bundleID: nil)
        }
        let bundleID = (info["CFBundleIdentifier"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let display = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String)
        let name = (display?.isEmpty == false) ? display! : fallback
        return BundleInfo(name: name, bundleID: bundleID)
    }

    private static func contentAccessDate(of url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentAccessDateKey]).contentAccessDate
    }

    private static func developerCaches(home: URL) -> [DevCache] {
        let library = home.appendingPathComponent("Library", isDirectory: true)
        func p(_ parts: String...) -> String {
            parts.reduce(home) { $0.appendingPathComponent($1) }.path
        }
        return [
            DevCache(id: "dev:xcode-derived-data", name: "Xcode DerivedData", path: library.appendingPathComponent("Developer/Xcode/DerivedData").path, safe: true),
            DevCache(id: "dev:xcode-archives", name: "Xcode Archives", path: library.appendingPathComponent("Developer/Xcode/Archives").path, safe: false),
            DevCache(id: "dev:ios-device-support", name: "iOS DeviceSupport", path: library.appendingPathComponent("Developer/Xcode/iOS DeviceSupport").path, safe: true),
            DevCache(id: "dev:core-simulator", name: "CoreSimulator Caches", path: library.appendingPathComponent("Developer/CoreSimulator/Caches").path, safe: true),
            DevCache(id: "dev:npm", name: "npm cache", path: p(".npm", "_cacache"), safe: true),
            DevCache(id: "dev:yarn", name: "Yarn cache", path: library.appendingPathComponent("Caches/Yarn").path, safe: true),
            DevCache(id: "dev:pnpm", name: "pnpm store", path: library.appendingPathComponent("pnpm/store").path, safe: true),
            DevCache(id: "dev:pip", name: "pip cache", path: library.appendingPathComponent("Caches/pip").path, safe: true),
            DevCache(id: "dev:homebrew", name: "Homebrew cache", path: library.appendingPathComponent("Caches/Homebrew").path, safe: true),
            DevCache(id: "dev:gradle", name: "Gradle caches", path: p(".gradle", "caches"), safe: true),
            DevCache(id: "dev:cargo", name: "Cargo registry", path: p(".cargo", "registry"), safe: true),
        ]
    }

    // MARK: - Matching

    private func locations(for info: BundleInfo, bundle: URL) -> [StorageLocation] {
        let library = home.appendingPathComponent("Library", isDirectory: true)
        var paths: [(String, StorageLocation.Kind)] = []
        var seen = Set<String>()

        func add(_ url: URL, kind: StorageLocation.Kind) {
            let path = url.standardizedFileURL.path
            guard seen.insert(path).inserted else { return }
            paths.append((path, kind))
        }

        add(bundle, kind: .bundle)
        let names = [info.bundleID, info.name].compactMap { $0 }.filter { !$0.isEmpty }
        let uniqueNames = Array(Set(names))
        for name in uniqueNames {
            add(library.appendingPathComponent("Application Support/\(name)", isDirectory: true), kind: .applicationSupport)
            add(library.appendingPathComponent("Caches/\(name)", isDirectory: true), kind: .caches)
            add(library.appendingPathComponent("Logs/\(name)", isDirectory: true), kind: .logs)
        }
        if let bundleID = info.bundleID, !bundleID.isEmpty {
            add(library.appendingPathComponent("Containers/\(bundleID)", isDirectory: true), kind: .containers)
            add(library.appendingPathComponent("Saved Application State/\(bundleID).savedState", isDirectory: true), kind: .savedState)
            add(library.appendingPathComponent("Preferences/\(bundleID).plist"), kind: .preferences)
            add(library.appendingPathComponent("HTTPStorages/\(bundleID)", isDirectory: true), kind: .webData)
            add(library.appendingPathComponent("WebKit/\(bundleID)", isDirectory: true), kind: .webData)
            groupContainers(matching: bundleID, library: library).forEach { add($0, kind: .groupContainers) }
        }

        var locations: [StorageLocation] = []
        for (path, kind) in paths {
            if isCancelled { break }
            let safe = kind == .caches || kind == .logs || kind == .savedState
            guard let location = measure(path: path, kind: kind, safe: safe) else { continue }
            locations.append(location)
        }
        return locations
    }

    private func groupContainers(matching bundleID: String, library: URL) -> [URL] {
        let root = library.appendingPathComponent("Group Containers", isDirectory: true)
        guard let children = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        let suffix = "." + bundleID
        return children.filter { url in
            let name = url.lastPathComponent
            guard name.hasSuffix(suffix) || name.contains(bundleID) else { return false }
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? true
            return isDir
        }
    }

    // MARK: - Size

    private func measure(path: String, kind: StorageLocation.Kind, safe: Bool) -> StorageLocation? {
        if isCancelled { return nil }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else { return nil }
        let url = URL(fileURLWithPath: path, isDirectory: isDirectory.boolValue)
        let bytes: UInt64
        if isDirectory.boolValue {
            guard let measured = directoryAllocatedSize(url) else { return nil }
            bytes = measured
        } else {
            bytes = fileAllocatedSize(url)
        }
        guard bytes > 0 else { return nil }
        return StorageLocation(path: path, kind: kind, bytes: bytes, isSafeToClean: safe)
    }

    private func fileAllocatedSize(_ url: URL) -> UInt64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isSymbolicLinkKey, .isRegularFileKey]
        guard let values = try? url.resourceValues(forKeys: keys), values.isSymbolicLink != true else { return 0 }
        if values.isRegularFile == false { return 0 }
        return allocated(from: values)
    }

    private func directoryAllocatedSize(_ root: URL) -> UInt64? {
        let keys: [URLResourceKey] = [
            .totalFileAllocatedSizeKey,
            .fileAllocatedSizeKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .isDirectoryKey,
            .volumeIdentifierKey,
        ]
        let rootVolume = (try? root.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier) as? NSObject
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, _ in true }
        ) else { return 0 }

        var total: UInt64 = 0
        var seen = 0
        let keySet = Set(keys)
        while let item = enumerator.nextObject() as? URL {
            seen += 1
            if seen % 64 == 0, isCancelled { return nil }
            guard let values = try? item.resourceValues(forKeys: keySet) else { continue }
            if values.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            if values.isDirectory == true,
               let rootVolume,
               let volume = values.volumeIdentifier as? NSObject,
               !volume.isEqual(rootVolume) {
                enumerator.skipDescendants()
                continue
            }
            if values.isRegularFile == true {
                total += allocated(from: values)
            }
        }
        if isCancelled { return nil }
        return total
    }

    private func allocated(from values: URLResourceValues) -> UInt64 {
        if let size = values.totalFileAllocatedSize { return UInt64(size) }
        if let size = values.fileAllocatedSize { return UInt64(size) }
        return 0
    }

    private var isCancelled: Bool {
        os_unfair_lock_lock(&lock)
        let value = cancelled
        os_unfair_lock_unlock(&lock)
        return value
    }
}
