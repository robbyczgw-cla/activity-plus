import ActivityCore
import Foundation
import Observation

/// Owns the home folder's size map for the Explore and Biggest tabs.
/// ACTIVITYPLUS_DISK_ROOT=/some/folder maps that folder instead (tests and snapshots must never walk the real
/// home folder from the dev copy: it is ad-hoc signed, so Desktop/Documents/Downloads would raise privacy prompts).
@MainActor @Observable
final class DiskIndexModel {
    enum State: Equatable {
        case idle
        case scanning(fraction: Double, item: String)
        case ready
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var index: DiskIndex?
    /// Bumped whenever `index` changes (scan finished, items trashed), so views can refresh.
    private(set) var generation = 0

    @ObservationIgnored private var loadStarted = false
    @ObservationIgnored private var cancelFlag: CancelFlag?

    /// Folder that gets mapped: the home folder, or ACTIVITYPLUS_DISK_ROOT.
    let root: URL
    let isCustomRoot: Bool
    let cacheURL: URL

    init() {
        if let custom = ProcessInfo.processInfo.environment["ACTIVITYPLUS_DISK_ROOT"], !custom.isEmpty {
            root = URL(fileURLWithPath: custom, isDirectory: true).standardizedFileURL
            isCustomRoot = true
        } else {
            root = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
            isCustomRoot = false
        }
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("at.hifiteam.activityplus", isDirectory: true)
        // A custom root gets its own file so a test run never replaces the home folder's map.
        cacheURL = caches.appendingPathComponent(isCustomRoot ? "diskindex-\(Self.stableHash(root.path)).bin" : "diskindex.bin")
        if isCustomRoot && SnapshotRunner.isActive {
            // Snapshot runs open the Storage page only after the warm-up; start right away so the map is there.
            Task { @MainActor in self.loadCachedIfNeeded() }
        }
    }

    /// Opens the cached map off the main thread (once). With ACTIVITYPLUS_DISK_ROOT and no cache, scans right away.
    func loadCachedIfNeeded() {
        guard !loadStarted, index == nil else { return }
        loadStarted = true
        let url = cacheURL
        let rootPath = root.path
        Task.detached(priority: .userInitiated) {
            let cached = DiskIndex.load(from: url).flatMap { $0.root.standardizedFileURL.path == rootPath ? $0 : nil }
            await MainActor.run {
                if let cached, self.index == nil {
                    self.index = cached
                    if case .scanning = self.state {} else { self.state = .ready }
                    self.generation += 1
                } else if cached == nil, self.isCustomRoot, self.index == nil {
                    self.scan()
                }
            }
        }
    }

    func scan() {
        if case .scanning = state { return }
        loadStarted = true
        let flag = CancelFlag()
        cancelFlag = flag
        state = .scanning(fraction: 0, item: "")
        let root = root
        let cacheURL = cacheURL
        let expected = index?.nodeCount
        Task.detached(priority: .utility) {
            let built = DiskIndex.build(root: root, expectedEntries: expected, isCancelled: { flag.isSet }) { fraction, item in
                Task { @MainActor in
                    guard !flag.isSet, case .scanning = self.state else { return }
                    self.state = .scanning(fraction: fraction, item: item)
                }
            }
            let cancelled = flag.isSet
            if !cancelled { try? built.save(to: cacheURL) }
            await MainActor.run {
                if self.cancelFlag === flag { self.cancelFlag = nil }
                if cancelled {
                    // A partial map would show wrong sizes; keep the previous one, if any.
                    self.state = self.index == nil ? .idle : .ready
                    return
                }
                self.index = built
                self.state = .ready
                self.generation += 1
            }
        }
    }

    func cancel() {
        cancelFlag?.set()
    }

    /// Moves to the Trash (FileManager.trashItem), updates the map. Callers confirm first.
    /// Never deletes permanently. Refuses anything outside the mapped folder, inside an app bundle,
    /// or one of the folders macOS and apps rely on (the Library folder and its first level, the standard home folders).
    func trash(_ urls: [URL]) -> (freed: UInt64, failures: [String: String]) {
        var freed: UInt64 = 0
        var failures: [String: String] = [:]
        var moved: [URL] = []
        for url in urls {
            let path = url.standardizedFileURL.path
            if let reason = refusal(for: url) {
                failures[path] = reason
                continue
            }
            let bytes = index?.id(of: url).flatMap { index?.node($0)?.bytes } ?? 0
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                freed += bytes
                moved.append(url)
            } catch {
                failures[path] = error.localizedDescription
            }
        }
        if !moved.isEmpty, let index {
            index.forget(moved)
            generation += 1
            let cacheURL = cacheURL
            Task.detached(priority: .utility) { try? index.save(to: cacheURL) }
        }
        return (freed, failures)
    }

    /// Why `url` may not be moved to the Trash from here, or nil when it may.
    func refusal(for url: URL) -> String? {
        let path = url.standardizedFileURL.path
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard path.hasPrefix(rootPath), path.count > rootPath.count else {
            return String(localized: "Outside the scanned folder.")
        }
        let components = url.standardizedFileURL.pathComponents
        if components.dropLast().contains(where: { $0.lowercased().hasSuffix(".app") }) {
            return String(localized: "Inside an app. Remove the whole app instead.")
        }
        let relative = String(path.dropFirst(rootPath.count)).split(separator: "/").map(String.init)
        if !isCustomRoot {
            let standard: Set<String> = ["Library", "Desktop", "Documents", "Downloads", "Movies", "Music", "Pictures", "Public", "Applications"]
            if relative.count == 1, standard.contains(relative[0]) { return String(localized: "A folder macOS needs.") }
            // Keys and the Trash itself: losing them by accident costs far more than the space they take.
            if let first = relative.first, [".ssh", ".gnupg", ".Trash"].contains(first) { return String(localized: "Holds keys or the Trash itself.") }
            if relative.count == 2, relative[0] == "Library" { return String(localized: "A folder macOS needs.") }
        }
        return nil
    }

    /// FNV-1a; `hashValue` changes on every launch.
    private static func stableHash(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
        return String(hash, radix: 16)
    }
}

/// Thread-safe stop flag for a background scan.
private final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}
