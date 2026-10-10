import Foundation

/// Where an entry sits in the Clean up list.
public enum CleanupSection: String, Sendable, CaseIterable, Comparable {
    case caches, developer, logs, largeOld, appCaches

    public var title: String {
        switch self {
        case .caches: String(localized: "Caches")
        case .developer: String(localized: "Developer data")
        case .logs: String(localized: "Logs")
        case .largeOld: String(localized: "Large and old files")
        case .appCaches: String(localized: "App caches")
        }
    }

    public var systemImage: String {
        switch self {
        case .caches: "internaldrive"
        case .developer: "hammer"
        case .logs: "doc.text"
        case .largeOld: "doc.badge.clock"
        case .appCaches: "app.dashed"
        }
    }

    private var order: Int { Self.allCases.firstIndex(of: self) ?? 0 }
    public static func < (lhs: CleanupSection, rhs: CleanupSection) -> Bool { lhs.order < rhs.order }
}

/// One line of the Clean up list: a `ReclaimableItem` plus the section it is shown in.
public struct CleanupEntry: Sendable, Identifiable, Hashable {
    public let item: ReclaimableItem
    public let section: CleanupSection
    /// Name of the app that owns the data, for "<App> is open".
    public let ownerName: String?

    public var id: String { item.id }

    public init(item: ReclaimableItem, section: CleanupSection, ownerName: String? = nil) {
        self.item = item
        self.section = section
        self.ownerName = ownerName
    }
}

/// What happened when the ticked entries were moved to the Trash.
public struct CleanupTrashOutcome: Sendable {
    public struct Failure: Sendable, Hashable {
        public let title: String
        public let reason: String
    }

    public var freed: UInt64 = 0
    /// Entries whose every URL went to the Trash.
    public var movedIDs: Set<String> = []
    /// Every path that actually went to the Trash (including parts of entries that only partly succeeded).
    public var movedPaths: Set<String> = []
    public var failures: [Failure] = []
    /// Titles of entries left alone because their app is open.
    public var skippedRunning: [String] = []

    public init() {}
}

/// Pure logic behind the Clean up tab: building, merging and ticking the list, and the guarded move to the Trash.
public enum CleanupPlan {
    // MARK: - Building entries

    /// Section for a System Data group, from its id and title.
    /// Section for a `SystemDataBreakdown` group, by its stable id (titles are translated, so never match on them).
    public static func section(forGroupID id: String, title: String) -> CleanupSection {
        switch id {
        case "developer": .developer
        case "logs": .logs
        case "backups": .largeOld
        default: .caches
        }
    }

    /// Items from `SystemDataBreakdown.measure()`. Never offers what macOS manages.
    public static func entries(from groups: [SystemDataBreakdown.Group]) -> [CleanupEntry] {
        var result: [CleanupEntry] = []
        for group in groups {
            let section = section(forGroupID: group.id, title: group.title)
            for item in group.items where item.safety != .managedByMacOS && item.bytes > 0 && !item.urls.isEmpty {
                guard !item.urls.contains(where: isInsideContainers) else { continue }
                let scoped = ReclaimableItem(
                    id: "sys:" + item.id, title: item.title, location: item.location, urls: item.urls,
                    bytes: item.bytes, safety: item.safety, reason: item.reason, bundleID: item.bundleID
                )
                result.append(CleanupEntry(item: scoped, section: section))
            }
        }
        return result
    }

    /// Cache, log and saved-state folders of installed apps, plus the safe developer caches from the app scan.
    /// Folders under `minimumBytes` are left out: clearing them would not be worth a line in the list.
    public static func entries(fromApps apps: [AppDiskUsage], minimumBytes: UInt64 = 1_000_000, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [CleanupEntry] {
        var result: [CleanupEntry] = []
        for app in apps {
            for location in app.locations where location.isSafeToClean && location.bytes > 0 && location.bytes >= minimumBytes {
                let url = URL(fileURLWithPath: location.path)
                guard !isInsideContainers(url) else { continue }
                let reason: String
                let section: CleanupSection
                switch location.kind {
                case .caches:
                    reason = String(localized: "Cache the app rebuilds when it needs it.")
                    section = .appCaches
                case .logs:
                    reason = String(localized: "Log files; the app writes new ones.")
                    section = .appCaches
                case .savedState:
                    reason = String(localized: "Open windows the app restores on launch; it starts fresh without them.")
                    section = .appCaches
                case .developer:
                    reason = String(localized: "Downloaded or built data the tool fetches or rebuilds on the next run.")
                    section = .developer
                default:
                    continue
                }
                let isDeveloper = location.kind == .developer
                let item = ReclaimableItem(
                    id: "app:" + location.path,
                    title: isDeveloper ? app.name : app.name + " · " + kindLabel(location.kind),
                    location: abbreviate(location.path, home: home),
                    urls: [url],
                    bytes: location.bytes,
                    safety: .safeToClear,
                    reason: reason,
                    bundleID: isDeveloper ? nil : app.bundleID
                )
                result.append(CleanupEntry(item: item, section: section, ownerName: isDeveloper ? nil : app.name))
            }
        }
        return result
    }

    private static func kindLabel(_ kind: StorageLocation.Kind) -> String {
        switch kind {
        case .caches: String(localized: "Cache")
        case .logs: String(localized: "Logs")
        case .savedState: String(localized: "Saved state")
        default: ""
        }
    }

    /// Large and old files from `LargeFilesScanner`, all "look first". Mounted disk images are left out: they can be ejected, not trashed.
    public static func entries(from candidates: [CleanupCandidate], home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [CleanupEntry] {
        var result: [CleanupEntry] = []
        for candidate in candidates where candidate.bytes > 0 && candidate.kind != .oldDiskImageMount {
            let reason: String
            switch candidate.kind {
            case .installer: reason = String(localized: "Installer you most likely used already; download it again if you need it.")
            case .oldDownload: reason = String(localized: "Download you have not opened for 90 days.")
            case .largeFile: reason = String(localized: "Very large file; check that you still need it.")
            case .xcodeArchive: reason = String(localized: "Xcode archive of an old build; you only need it to submit that build again or to read its crash reports.")
            case .iosBackup: reason = String(localized: "Backup of an iPhone or iPad; keep it if it is the only copy.")
            case .oldDiskImageMount: continue
            }
            let item = ReclaimableItem(
                id: "file:" + candidate.url.path,
                title: candidate.url.lastPathComponent,
                location: abbreviate(candidate.url.deletingLastPathComponent().path, home: home),
                urls: [candidate.url],
                bytes: candidate.bytes,
                safety: .lookFirst,
                reason: reason
            )
            result.append(CleanupEntry(item: item, section: .largeOld))
        }
        return result
    }

    /// `/Applications/Install macOS *.app`: several GB each, downloadable again.
    public static func macOSInstallers(applications: URL = URL(fileURLWithPath: "/Applications", isDirectory: true)) -> [CleanupEntry] {
        guard let children = try? FileManager.default.contentsOfDirectory(at: applications, includingPropertiesForKeys: nil) else { return [] }
        var result: [CleanupEntry] = []
        for url in children where url.pathExtension == "app" && url.lastPathComponent.hasPrefix("Install macOS") {
            let bytes = allocatedSize(of: url)
            guard bytes > 0 else { continue }
            let item = ReclaimableItem(
                id: "file:" + url.path,
                title: url.lastPathComponent,
                location: applications.path,
                urls: [url],
                bytes: bytes,
                safety: .lookFirst,
                reason: String(localized: "macOS installer you downloaded; the App Store or Software Update gets it again.")
            )
            result.append(CleanupEntry(item: item, section: .largeOld))
        }
        return result
    }

    // MARK: - Merging

    /// Drops duplicates: the same path twice keeps the first entry; an entry whose paths all lie inside paths of
    /// another entry is dropped, so the outer one stays. Sorted by size within each section.
    public static func merge(_ entries: [CleanupEntry]) -> [CleanupEntry] {
        var owners: [String: [Int]] = [:]
        let paths: [[String]] = entries.map { entry in entry.item.urls.map(normalized) }
        for (index, list) in paths.enumerated() {
            for path in list { owners[path, default: []].append(index) }
        }

        func covered(_ index: Int) -> Bool {
            guard !paths[index].isEmpty else { return true }
            return paths[index].allSatisfy { path in
                if let same = owners[path], same.contains(where: { $0 < index }) { return true }
                var ancestor = path
                while let slash = ancestor.lastIndex(of: "/"), slash != ancestor.startIndex {
                    ancestor = String(ancestor[..<slash])
                    if let outer = owners[ancestor], outer.contains(where: { $0 != index }) { return true }
                }
                return false
            }
        }

        // A dropped duplicate may know the owning app (the app scan does, System Data often doesn't): keep that
        // knowledge, or a cache of a running app would be offered for the Trash.
        func owner(for index: Int) -> (bundleID: String, name: String?)? {
            for (other, list) in paths.enumerated() where other != index {
                guard let id = entries[other].item.bundleID, !id.isEmpty else { continue }
                let inside = list.contains { path in paths[index].contains { path == $0 || path.hasPrefix($0 + "/") } }
                if inside { return (id, entries[other].ownerName) }
            }
            return nil
        }

        let kept = entries.indices.filter { !covered($0) }.map { index -> CleanupEntry in
            let entry = entries[index]
            guard entry.item.bundleID?.isEmpty ?? true, let found = owner(for: index) else { return entry }
            let item = entry.item
            return CleanupEntry(item: ReclaimableItem(id: item.id, title: item.title, location: item.location, urls: item.urls,
                                                      bytes: item.bytes, safety: item.safety, reason: item.reason, bundleID: found.bundleID),
                                section: entry.section, ownerName: entry.ownerName ?? found.name)
        }
        return kept.sorted { lhs, rhs in
            if lhs.section != rhs.section { return lhs.section < rhs.section }
            if lhs.item.bytes != rhs.item.bytes { return lhs.item.bytes > rhs.item.bytes }
            return lhs.id < rhs.id
        }
    }

    // MARK: - Ticks and running apps

    /// True when the app that owns the entry is running. A helper whose id extends the owner's counts too.
    public static func isBlocked(_ entry: CleanupEntry, running: Set<String>) -> Bool {
        guard let bundleID = entry.item.bundleID, !bundleID.isEmpty else { return false }
        if running.contains(bundleID) { return true }
        return running.contains { $0.hasPrefix(bundleID + ".") }
    }

    /// Safe items that are not blocked start ticked; "look first" never.
    public static func defaultSelection(_ entries: [CleanupEntry], running: Set<String>) -> Set<String> {
        Set(entries.filter { $0.item.safety == .safeToClear && !isBlocked($0, running: running) }.map(\.id))
    }

    public static func totalBytes(_ entries: [CleanupEntry], ids: Set<String>) -> UInt64 {
        entries.filter { ids.contains($0.id) }.reduce(0) { $0 + $1.item.bytes }
    }

    // MARK: - Guarded move to the Trash

    private static let protectedHomeFolders: Set<String> = [
        "Applications", "Desktop", "Documents", "Downloads", "Library", "Movies", "Music", "Pictures", "Public",
    ]

    /// Only items below the user's home folder may go to the Trash, plus `/Applications/Install macOS*.app`.
    /// Not the home folder or its standard folders, not `~/Library` itself, nothing in `~/Library/Containers`.
    public static func isTrashAllowed(_ url: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        let name = url.lastPathComponent
        guard !name.isEmpty, name != "/", name != ".", name != ".." else { return false }
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath()

        if parent.path == "/Applications", name.hasPrefix("Install macOS"), url.pathExtension == "app" { return true }

        let root = home.resolvingSymlinksInPath().path
        let candidate = parent.appendingPathComponent(name).path
        guard candidate.hasPrefix(root + "/") else { return false }
        let relative = String(candidate.dropFirst(root.count + 1))
        let parts = relative.split(separator: "/").map(String.init)
        guard !parts.isEmpty, !parts.contains("..") else { return false }
        if parts.count == 1, protectedHomeFolders.contains(parts[0]) { return false }
        if parts[0] == "Library", parts.count >= 2, parts[1] == "Containers" { return false }
        return true
    }

    /// Moves the entries to the Trash. Never deletes permanently. `runningBundleIDs` is asked again right before each
    /// entry, so an app that was launched since the list was built is left alone. `mover` is the Trash call.
    public static func trash(
        _ entries: [CleanupEntry],
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        runningBundleIDs: () -> Set<String>,
        mover: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    ) -> CleanupTrashOutcome {
        var outcome = CleanupTrashOutcome()
        for entry in entries {
            if isBlocked(entry, running: runningBundleIDs()) {
                outcome.skippedRunning.append(entry.ownerName ?? entry.item.title)
                continue
            }
            var movedAll = true
            var firstError: String?
            for url in entry.item.urls {
                guard isTrashAllowed(url, home: home) else {
                    movedAll = false
                    firstError = firstError ?? String(localized: "Outside your home folder or protected.")
                    continue
                }
                guard (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil else { continue } // already gone
                do {
                    try mover(url)
                    outcome.movedPaths.insert(url.standardizedFileURL.path)
                } catch {
                    movedAll = false
                    firstError = firstError ?? error.localizedDescription
                }
            }
            if movedAll {
                outcome.movedIDs.insert(entry.id)
                outcome.freed += entry.item.bytes
            } else {
                outcome.failures.append(.init(title: entry.item.title, reason: firstError ?? ""))
            }
        }
        return outcome
    }

    // MARK: - Helpers

    static func normalized(_ url: URL) -> String {
        var path = url.standardizedFileURL.path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    static func isInsideContainers(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return path.contains("/Library/Containers/") || path.hasSuffix("/Library/Containers")
    }

    static func abbreviate(_ path: String, home: URL) -> String {
        let root = home.path
        if path == root { return "~" }
        if path.hasPrefix(root + "/") { return "~" + path.dropFirst(root.count) }
        return path
    }

    /// Allocated bytes of a file or folder, staying on one volume and skipping symlinks.
    public static func allocatedSize(of url: URL) -> UInt64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
        func size(_ item: URL) -> UInt64 {
            guard let values = try? item.resourceValues(forKeys: Set(keys)), values.isSymbolicLink != true else { return 0 }
            return UInt64(max(0, values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0))
        }
        var total = size(url)
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }) else { return total }
        while let item = enumerator.nextObject() as? URL { total += size(item) }
        return total
    }
}
