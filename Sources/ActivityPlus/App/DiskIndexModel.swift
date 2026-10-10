import ActivityCore
import AppKit
import Foundation
import Observation

/// Owns the size map for the Explore, Biggest and Duplicates tabs: of the home folder (default), another
/// mounted volume, or the whole startup disk. Each root has its own cache file and its own scan history.
/// ACTIVITYPLUS_DISK_ROOT=/some/folder maps that folder instead of the home folder (tests and snapshots must never
/// walk the real home folder from the dev copy: it is ad-hoc signed, so Desktop/Documents/Downloads would raise privacy prompts).
@MainActor @Observable
final class DiskIndexModel {
    enum State: Equatable {
        case idle
        case scanning(fraction: Double, item: String)
        case ready
        case failed(String)
    }

    /// What gets mapped.
    enum ScanRoot: Hashable, Codable {
        case home
        /// Mount point of another volume ("/Volumes/Backup").
        case volume(String)
        /// "/" without crossing into other volumes.
        case startupDisk
    }

    /// A mounted volume other than the startup disk.
    struct Volume: Identifiable, Hashable {
        let path: String
        let name: String
        let isRemovable: Bool
        let isInternal: Bool
        let uuid: String?
        var id: String { path }
    }

    private(set) var state: State = .idle
    private(set) var index: DiskIndex?
    /// Bumped whenever `index` changes (scan finished, items trashed, root switched), so views can refresh.
    private(set) var generation = 0
    private(set) var selection: ScanRoot = .home
    private(set) var volumes: [Volume] = []
    /// Summaries of the finished scans of the current root, oldest first (for "What grew").
    private(set) var growth: [DiskGrowth.Summary] = []

    @ObservationIgnored private var loadStarted = false
    @ObservationIgnored private var cancelFlag: CancelFlag?
    @ObservationIgnored private var mountObservers: [NSObjectProtocol] = []

    /// Folder that gets mapped right now.
    private(set) var root: URL
    private(set) var cacheURL: URL
    private(set) var growthURL: URL
    /// ACTIVITYPLUS_DISK_ROOT, which takes the place of the home folder.
    let customHome: URL?

    private static let selectionKey = "diskIndexRoot"
    private static let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("at.hifiteam.activityplus", isDirectory: true)
    static let homePath = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path

    /// The map is not of the user's home folder (Clean up then walks the folders itself).
    var isCustomRoot: Bool { customHome != nil || selection != .home }

    init() {
        if let custom = ProcessInfo.processInfo.environment["ACTIVITYPLUS_DISK_ROOT"], !custom.isEmpty {
            customHome = URL(fileURLWithPath: custom, isDirectory: true).standardizedFileURL
        } else {
            customHome = nil
        }
        let mounted = Self.mountedVolumes()
        var initial = ScanRoot.home
        // A test or snapshot run with its own folder never picks up the user's choice of a real volume.
        if customHome == nil, let data = UserDefaults.standard.data(forKey: Self.selectionKey),
           let saved = try? JSONDecoder().decode(ScanRoot.self, from: data) {
            if case .volume(let path) = saved, !mounted.contains(where: { $0.path == path }) {
                initial = .home
            } else {
                initial = saved
            }
        }
        let paths = Self.paths(for: initial, customHome: customHome, volumes: mounted)
        root = paths.root
        cacheURL = paths.cache
        growthURL = paths.growth
        volumes = mounted
        selection = initial
        if customHome != nil && SnapshotRunner.isActive {
            // Snapshot runs open the Storage page only after the warm-up; start right away so the map is there.
            Task { @MainActor in self.loadCachedIfNeeded() }
        }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            mountObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshVolumes() }
            })
        }
    }

    // MARK: Roots

    /// Display name of the current root.
    var rootTitle: String { title(for: selection) }

    func title(for choice: ScanRoot) -> String {
        switch choice {
        case .home: customHome?.lastPathComponent ?? String(localized: "Home folder")
        case .volume(let path): volumes.first { $0.path == path }?.name ?? (path as NSString).lastPathComponent
        case .startupDisk: String(localized: "Whole startup disk")
        }
    }

    func symbol(for choice: ScanRoot) -> String {
        switch choice {
        case .home: customHome == nil ? "house" : "folder"
        case .volume(let path): volumes.first { $0.path == path }?.isRemovable == true ? "externaldrive" : "internaldrive"
        case .startupDisk: "internaldrive.fill"
        }
    }

    func refreshVolumes() {
        volumes = Self.mountedVolumes()
        if case .volume(let path) = selection, !volumes.contains(where: { $0.path == path }) {
            select(.home)   // the drive went away
        }
    }

    /// Switches the map to another root: stops a running scan, opens that root's cached map if there is one.
    func select(_ choice: ScanRoot) {
        guard choice != selection else { return }
        cancelFlag?.set()
        cancelFlag = nil
        selection = choice
        if customHome == nil, let data = try? JSONEncoder().encode(choice) {
            UserDefaults.standard.set(data, forKey: Self.selectionKey)
        }
        let paths = Self.paths(for: choice, customHome: customHome, volumes: volumes)
        root = paths.root
        cacheURL = paths.cache
        growthURL = paths.growth
        index = nil
        growth = []
        state = .idle
        loadStarted = false
        generation += 1
        loadCachedIfNeeded()
    }

    private static func paths(for choice: ScanRoot, customHome: URL?, volumes: [Volume]) -> (root: URL, cache: URL, growth: URL) {
        let root: URL
        let key: String?   // nil = the home folder's original file names
        switch choice {
        case .home:
            root = customHome ?? URL(fileURLWithPath: homePath, isDirectory: true)
            // A custom root gets its own file so a test run never replaces the home folder's map.
            key = customHome.map { stableHash($0.path) }
        case .volume(let path):
            root = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
            // Two drives can both be called "Untitled": the volume's UUID tells them apart.
            key = stableHash(path + "|" + (volumes.first { $0.path == path }?.uuid ?? ""))
        case .startupDisk:
            root = URL(fileURLWithPath: "/", isDirectory: true)
            key = stableHash("/")
        }
        let suffix = key.map { "-\($0)" } ?? ""
        return (root, caches.appendingPathComponent("diskindex\(suffix).bin"), caches.appendingPathComponent("growth\(suffix).json"))
    }

    /// Local, browsable volumes other than the startup disk and its hidden system volumes.
    static func mountedVolumes() -> [Volume] {
        let keys: [URLResourceKey] = [.volumeLocalizedNameKey, .volumeIsRemovableKey, .volumeIsInternalKey, .volumeIsLocalKey,
                                      .volumeIsBrowsableKey, .volumeUUIDStringKey, .volumeIsRootFileSystemKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url -> Volume? in
            let path = url.standardizedFileURL.path
            guard path != "/", !path.hasPrefix("/System/Volumes/"), let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.volumeIsRootFileSystem != true, values.volumeIsBrowsable != false, values.volumeIsLocal != false else { return nil }
            return Volume(path: path, name: values.volumeLocalizedName ?? url.lastPathComponent,
                          isRemovable: values.volumeIsRemovable ?? false, isInternal: values.volumeIsInternal ?? false,
                          uuid: values.volumeUUIDString)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: Loading and scanning

    /// Opens the cached map off the main thread (once). With ACTIVITYPLUS_DISK_ROOT and no cache, scans right away.
    func loadCachedIfNeeded() {
        guard !loadStarted, index == nil else { return }
        loadStarted = true
        let url = cacheURL
        let growthURL = growthURL
        let rootPath = root.path
        let choice = selection
        Task.detached(priority: .userInitiated) {
            let cached = DiskIndex.load(from: url).flatMap { $0.root.standardizedFileURL.path == rootPath ? $0 : nil }
            var history = DiskGrowth.History.load(from: growthURL)
            // A map from before scan summaries existed: it becomes the first summary, so the next scan can compare.
            if let cached, !history.contains(date: cached.builtAt) {
                history.add(DiskGrowth.summarize(cached))
                try? history.save(to: growthURL)
            }
            let summaries = history.summaries
            await MainActor.run {
                guard self.selection == choice else { return }
                self.growth = summaries
                if let cached, self.index == nil {
                    self.index = cached
                    if case .scanning = self.state {} else { self.state = .ready }
                    self.generation += 1
                } else if cached == nil, self.customHome != nil, self.selection == .home, self.index == nil {
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
        let growthURL = growthURL
        let expected = index?.nodeCount
        let options = selection == .startupDisk ? DiskIndex.ScanOptions.startupDisk : DiskIndex.ScanOptions()
        Task.detached(priority: .utility) {
            let built = DiskIndex.build(root: root, expectedEntries: expected, options: options, isCancelled: { flag.isSet }) { fraction, item in
                Task { @MainActor in
                    guard !flag.isSet, self.cancelFlag === flag, case .scanning = self.state else { return }
                    self.state = .scanning(fraction: fraction, item: item)
                }
            }
            let cancelled = flag.isSet
            let summaries: [DiskGrowth.Summary]? = cancelled ? nil : {
                try? built.save(to: cacheURL)
                var history = DiskGrowth.History.load(from: growthURL)
                history.add(DiskGrowth.summarize(built))
                try? history.save(to: growthURL)
                return history.summaries
            }()
            await MainActor.run {
                // Another root was picked meanwhile: this result belongs to that one's cache only.
                guard self.cancelFlag === flag else { return }
                self.cancelFlag = nil
                if cancelled {
                    // A partial map would show wrong sizes; keep the previous one, if any.
                    self.state = self.index == nil ? .idle : .ready
                    return
                }
                self.index = built
                if let summaries { self.growth = summaries }
                self.state = .ready
                self.generation += 1
            }
        }
    }

    func cancel() {
        cancelFlag?.set()
    }

    // MARK: Trash

    /// Moves to the Trash (FileManager.trashItem), updates the map. Callers confirm first.
    /// Never deletes permanently. Refuses what `refusal(for:)` refuses.
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
    /// - Home folder: anything inside it except the folders macOS and apps rely on (the standard folders,
    ///   Library and its first level, keys and the Trash itself).
    /// - Whole startup disk: only inside the home folder, with the same rules; outside it only items on another
    ///   volume (never its top folder). System folders, apps' shared folders and other users' files are refused.
    /// - Another volume: anything inside it, never the volume itself or its hidden system folders.
    /// - Everywhere: nothing inside an app bundle.
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
        switch selection {
        case .home:
            if customHome != nil { return nil }
            return Self.homeRefusal(path)
        case .volume(let volume):
            return Self.volumeRefusal(path, volume: volume)
        case .startupDisk:
            if path.hasPrefix(Self.homePath + "/") { return Self.homeRefusal(path) }
            if let volume = Self.otherVolume(containing: path) { return Self.volumeRefusal(path, volume: volume) }
            return String(localized: "Outside your home folder. Activity+ moves only your own files to the Trash.")
        }
    }

    private static func homeRefusal(_ path: String) -> String? {
        let home = homePath + "/"
        guard path.hasPrefix(home), path.count > home.count else { return String(localized: "Outside the scanned folder.") }
        let relative = String(path.dropFirst(home.count)).split(separator: "/").map(String.init)
        let standard: Set<String> = ["Library", "Desktop", "Documents", "Downloads", "Movies", "Music", "Pictures", "Public", "Applications"]
        if relative.count == 1, standard.contains(relative[0]) { return String(localized: "A folder macOS needs.") }
        // Keys and the Trash itself: losing them by accident costs far more than the space they take.
        if let first = relative.first, [".ssh", ".gnupg", ".Trash"].contains(first) { return String(localized: "Holds keys or the Trash itself.") }
        if relative.count == 2, relative[0] == "Library" { return String(localized: "A folder macOS needs.") }
        return nil
    }

    private static func volumeRefusal(_ path: String, volume: String) -> String? {
        let prefix = volume.hasSuffix("/") ? volume : volume + "/"
        guard path.hasPrefix(prefix), path.count > prefix.count else { return String(localized: "The drive itself cannot be moved to the Trash.") }
        let first = String(path.dropFirst(prefix.count)).split(separator: "/").first.map(String.init) ?? ""
        let system: Set<String> = [".Spotlight-V100", ".fseventsd", ".Trashes", ".DocumentRevisions-V100", ".TemporaryItems",
                                   ".MobileBackups", "Backups.backupdb", ".PKInstallSandboxManager"]
        if system.contains(first) { return String(localized: "A folder macOS keeps on the drive.") }
        return nil
    }

    /// "/Volumes/Name" when `path` lies on a mounted volume other than the startup disk.
    private static func otherVolume(containing path: String) -> String? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count >= 3, parts[0] == "Volumes" else { return nil }
        let volume = "/Volumes/" + parts[1]
        var volumeInfo = stat()
        var rootInfo = stat()
        // lstat: "Macintosh HD" in /Volumes is a link to "/", not a volume.
        guard lstat(volume, &volumeInfo) == 0, volumeInfo.st_mode & S_IFMT == S_IFDIR,
              stat("/", &rootInfo) == 0, volumeInfo.st_dev != rootInfo.st_dev else { return nil }
        return volume
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
