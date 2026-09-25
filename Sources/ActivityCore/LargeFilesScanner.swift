import Foundation

/// A file or folder the user may want to remove. This type never deletes anything.
public struct CleanupCandidate: Sendable, Identifiable, Hashable {
    public enum Kind: String, Sendable, CaseIterable {
        /// `.dmg`, `.pkg`, `.mpkg`, `.iso`, `.xip` in Downloads, Desktop or Documents.
        case installer
        /// At least `minimumLargeFileBytes` anywhere under the scanned folders.
        case largeFile
        /// In `~/Downloads`, not opened for 90+ days, at least 20 MB.
        case oldDownload
        /// `~/Library/Developer/Xcode/Archives/*.xcarchive`.
        case xcodeArchive
        /// `~/Library/Application Support/MobileSync/Backup/*`.
        case iosBackup
        /// A mounted disk image whose volume is at least 90 days old.
        case oldDiskImageMount
    }

    public let url: URL
    public let kind: Kind
    /// Allocated size. Directories are measured recursively.
    public let bytes: UInt64
    /// `URLResourceKey.contentAccessDateKey`.
    public let lastOpened: Date?
    public let modified: Date?
    public var id: String { url.path }

    public init(url: URL, kind: Kind, bytes: UInt64, lastOpened: Date?, modified: Date?) {
        self.url = url
        self.kind = kind
        self.bytes = bytes
        self.lastOpened = lastOpened
        self.modified = modified
    }
}

/// Read-only search for large and stale files. Never deletes or moves anything.
public final class LargeFilesScanner: @unchecked Sendable {
    private static let installerExtensions: Set<String> = ["dmg", "pkg", "mpkg", "iso", "xip"]
    private static let diskImageExtensions: Set<String> = ["dmg", "iso", "sparseimage", "sparsebundle", "cdr"]
    private static let skippedDirectoryNames: Set<String> = ["node_modules", ".git", ".build", "deriveddata"]
    private static let oldInterval: TimeInterval = 90 * 24 * 60 * 60
    private static let oldDownloadMinimum: UInt64 = 20_000_000

    private let roots: [URL]
    private let lock = NSLock()
    private var cancelled = false
    private let fileManager = FileManager.default

    /// `~/Downloads`, `~/Desktop`, `~/Documents`, `~/Movies`, and the home folder itself.
    public static var defaultRoots: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent("Downloads", isDirectory: true),
            home.appendingPathComponent("Desktop", isDirectory: true),
            home.appendingPathComponent("Documents", isDirectory: true),
            home.appendingPathComponent("Movies", isDirectory: true),
            home,
        ]
    }

    public init(roots: [URL] = LargeFilesScanner.defaultRoots) {
        self.roots = roots
    }

    public func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    /// Candidates sorted by allocated size, largest first. Each path appears once.
    /// Installer wins over an old download, which wins over a generic large file.
    public func scan(
        minimumLargeFileBytes: UInt64 = 500_000_000,
        progress: @escaping @Sendable (Double, String) -> Void
    ) -> [CleanupCandidate] {
        lock.lock()
        cancelled = false
        lock.unlock()

        let home = fileManager.homeDirectoryForCurrentUser.standardizedFileURL
        let library = home.appendingPathComponent("Library", isDirectory: true)
        let roots = uniqueExistingRoots(home: home)
        let phases = max(roots.count + 3, 1)
        var found: [String: CleanupCandidate] = [:]
        var phase = 0

        for root in roots {
            if isCancelled { break }
            let label = displayName(root, home: home)
            progress(Double(phase) / Double(phases), label)
            scanTree(
                root,
                home: home,
                library: library,
                coveredRoots: Set(roots.map(\.path)),
                minimum: minimumLargeFileBytes,
                phase: phase,
                phases: phases,
                into: &found,
                progress: progress
            )
            phase += 1
            progress(Double(phase) / Double(phases), label)
        }

        if !isCancelled {
            progress(Double(phase) / Double(phases), "Xcode Archives")
            scanXcodeArchives(home: home, into: &found)
            phase += 1
        }
        if !isCancelled {
            progress(Double(phase) / Double(phases), "iOS Backups")
            scanIOSBackups(home: home, into: &found)
            phase += 1
        }
        if !isCancelled {
            progress(Double(phase) / Double(phases), "Disk Images")
            scanDiskImageMounts(into: &found)
        }

        progress(1, "")
        return found.values.sorted { lhs, rhs in
            if lhs.bytes != rhs.bytes { return lhs.bytes > rhs.bytes }
            return lhs.url.path < rhs.url.path
        }
    }

    // MARK: - Walk

    private struct OpenFolder {
        let url: URL
        let level: Int
        var bytes: UInt64
        let lastOpened: Date?
        let modified: Date?
        let isPackage: Bool
    }

    private func scanTree(
        _ root: URL,
        home: URL,
        library: URL,
        coveredRoots: Set<String>,
        minimum: UInt64,
        phase: Int,
        phases: Int,
        into found: inout [String: CleanupCandidate],
        progress: @escaping @Sendable (Double, String) -> Void
    ) {
        let rootVolume = volumeIdentifier(of: root)
        let downloads = home.appendingPathComponent("Downloads", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory) else { return }
        if !isDirectory.boolValue {
            considerFile(root, home: home, downloads: downloads, minimum: minimum, into: &found)
            return
        }

        let topLevel = (try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ))?.count ?? 1
        var seenTop = 0
        var seen = 0
        let downloadsPath = downloads.path
        let scanningDownloads = root.path == downloadsPath

        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: Self.resourceKeys,
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in true }
        ) else { return }

        // Packages and stale download folders are sized while the walk visits them once.
        var packages: [OpenFolder] = []
        var download: OpenFolder?

        func addToOpenFolders(_ bytes: UInt64) {
            if bytes == 0 { return }
            if download != nil { download!.bytes += bytes }
            for index in packages.indices { packages[index].bytes += bytes }
        }

        func closeFolders(atLevel level: Int) {
            if let folder = download, level <= folder.level {
                if folder.bytes >= Self.oldDownloadMinimum {
                    insert(CleanupCandidate(
                        url: folder.url,
                        kind: .oldDownload,
                        bytes: folder.bytes,
                        lastOpened: folder.lastOpened,
                        modified: folder.modified
                    ), into: &found)
                }
                download = nil
            }
            while let folder = packages.last, level <= folder.level {
                packages.removeLast()
                guard folder.bytes > 0 else { continue }
                guard let kind = classify(
                    url: folder.url,
                    bytes: folder.bytes,
                    lastOpened: folder.lastOpened,
                    modified: folder.modified,
                    home: home,
                    downloads: downloads,
                    minimum: minimum
                ) else { continue }
                insert(CleanupCandidate(
                    url: folder.url,
                    kind: kind,
                    bytes: folder.bytes,
                    lastOpened: folder.lastOpened,
                    modified: folder.modified
                ), into: &found)
            }
        }

        while let item = enumerator.nextObject() as? URL {
            seen += 1
            if seen & 127 == 0, isCancelled { return }
            let level = enumerator.level
            closeFolders(atLevel: level)
            guard let values = try? item.resourceValues(forKeys: Self.resourceKeySet) else { continue }

            if level == 1 {
                seenTop += 1
                if seenTop == 1 || seenTop % 3 == 0 {
                    let fraction = min(0.98, Double(seenTop) / Double(max(topLevel, 1)))
                    progress((Double(phase) + fraction) / Double(phases), item.lastPathComponent)
                }
            }

            if values.isSymbolicLink == true || values.isAliasFile == true {
                enumerator.skipDescendants()
                continue
            }
            if values.isHidden == true || item.lastPathComponent.hasPrefix(".") {
                enumerator.skipDescendants()
                continue
            }
            if isCloudPlaceholder(values) {
                enumerator.skipDescendants()
                continue
            }
            if values.isDirectory == true, !sameVolume(values, rootVolume: rootVolume) {
                enumerator.skipDescendants()
                continue
            }
            if Self.skippedDirectoryNames.contains(item.lastPathComponent.lowercased()) {
                enumerator.skipDescendants()
                continue
            }
            if item.path == library.path || (item.path != root.path && coveredRoots.contains(item.path)) {
                enumerator.skipDescendants()
                continue
            }

            let own = allocated(values)
            let isPackage = values.isPackage == true || item.pathExtension.lowercased() == "app"
            if values.isDirectory == true, isPackage {
                addToOpenFolders(own)
                packages.append(OpenFolder(
                    url: item,
                    level: level,
                    bytes: own,
                    lastOpened: values.contentAccessDate,
                    modified: values.contentModificationDate,
                    isPackage: true
                ))
                continue
            }

            if values.isDirectory == true {
                addToOpenFolders(own)
                if scanningDownloads,
                   level == 1,
                   download == nil,
                   isStale(values.contentAccessDate, values.contentModificationDate) {
                    download = OpenFolder(
                        url: item,
                        level: level,
                        bytes: own,
                        lastOpened: values.contentAccessDate,
                        modified: values.contentModificationDate,
                        isPackage: false
                    )
                }
                continue
            }

            guard values.isRegularFile == true else { continue }
            addToOpenFolders(own)
            if !packages.isEmpty { continue }
            considerFile(
                item,
                values: values,
                bytes: own,
                home: home,
                downloads: downloads,
                minimum: minimum,
                into: &found
            )
        }
        if !isCancelled {
            closeFolders(atLevel: 0)
        }
    }

    private func considerFile(
        _ url: URL,
        home: URL,
        downloads: URL,
        minimum: UInt64,
        into found: inout [String: CleanupCandidate]
    ) {
        guard let values = try? url.resourceValues(forKeys: Self.resourceKeySet) else { return }
        guard values.isSymbolicLink != true, values.isRegularFile == true else { return }
        guard !isCloudPlaceholder(values) else { return }
        considerFile(
            url,
            values: values,
            bytes: allocated(values),
            home: home,
            downloads: downloads,
            minimum: minimum,
            into: &found
        )
    }

    private func considerFile(
        _ url: URL,
        values: URLResourceValues,
        bytes: UInt64,
        home: URL,
        downloads: URL,
        minimum: UInt64,
        into found: inout [String: CleanupCandidate]
    ) {
        guard bytes > 0 else { return }
        guard let kind = classify(
            url: url,
            bytes: bytes,
            lastOpened: values.contentAccessDate,
            modified: values.contentModificationDate,
            home: home,
            downloads: downloads,
            minimum: minimum
        ) else { return }
        insert(CleanupCandidate(
            url: url,
            kind: kind,
            bytes: bytes,
            lastOpened: values.contentAccessDate,
            modified: values.contentModificationDate
        ), into: &found)
    }

    /// Installer beats old download beats large file. Archives keep their own kind.
    private func classify(
        url: URL,
        bytes: UInt64,
        lastOpened: Date?,
        modified: Date?,
        home: URL,
        downloads: URL,
        minimum: UInt64
    ) -> CleanupCandidate.Kind? {
        if url.pathExtension.lowercased() == "xcarchive" { return .xcodeArchive }
        if isInstallerLocation(url, home: home),
           Self.installerExtensions.contains(url.pathExtension.lowercased()) {
            return .installer
        }
        if isInside(url, downloads), bytes >= Self.oldDownloadMinimum, isStale(lastOpened, modified) {
            return .oldDownload
        }
        if bytes >= minimum { return .largeFile }
        return nil
    }

    // MARK: - Known locations

    private func scanXcodeArchives(home: URL, into found: inout [String: CleanupCandidate]) {
        let archives = home
            .appendingPathComponent("Library/Developer/Xcode/Archives", isDirectory: true)
        guard let children = try? fileManager.contentsOfDirectory(
            at: archives,
            includingPropertiesForKeys: Self.resourceKeys,
            options: [.skipsHiddenFiles]
        ) else { return }
        let rootVolume = volumeIdentifier(of: archives)
        for child in children {
            if isCancelled { return }
            let url = child.standardizedFileURL
            guard url.pathExtension.lowercased() == "xcarchive" else { continue }
            guard let values = try? url.resourceValues(forKeys: Self.resourceKeySet) else { continue }
            guard values.isSymbolicLink != true, !isCloudPlaceholder(values) else { continue }
            guard let bytes = recursiveAllocatedSize(of: url, rootVolume: rootVolume), bytes > 0 else { continue }
            insert(CleanupCandidate(
                url: url,
                kind: .xcodeArchive,
                bytes: bytes,
                lastOpened: values.contentAccessDate,
                modified: values.contentModificationDate
            ), into: &found)
        }
    }

    private func scanIOSBackups(home: URL, into found: inout [String: CleanupCandidate]) {
        let backups = home
            .appendingPathComponent("Library/Application Support/MobileSync/Backup", isDirectory: true)
        // TCC can refuse this directory. Skip it; do not surface an error.
        guard let children = try? fileManager.contentsOfDirectory(
            at: backups,
            includingPropertiesForKeys: Self.resourceKeys,
            options: [.skipsHiddenFiles]
        ) else { return }
        let rootVolume = volumeIdentifier(of: backups)
        for child in children {
            if isCancelled { return }
            let url = child.standardizedFileURL
            guard let values = try? url.resourceValues(forKeys: Self.resourceKeySet) else { continue }
            guard values.isSymbolicLink != true, values.isDirectory == true else { continue }
            guard !isCloudPlaceholder(values) else { continue }
            guard let bytes = recursiveAllocatedSize(of: url, rootVolume: rootVolume), bytes > 0 else { continue }
            insert(CleanupCandidate(
                url: url,
                kind: .iosBackup,
                bytes: bytes,
                lastOpened: values.contentAccessDate,
                modified: values.contentModificationDate
            ), into: &found)
        }
    }

    private func scanDiskImageMounts(into found: inout [String: CleanupCandidate]) {
        let volumes = URL(fileURLWithPath: "/Volumes", isDirectory: true)
        guard let children = try? fileManager.contentsOfDirectory(
            at: volumes,
            includingPropertiesForKeys: Self.volumeKeys,
            options: [.skipsHiddenFiles]
        ) else { return }
        let cutoff = Date().addingTimeInterval(-Self.oldInterval)
        for child in children {
            if isCancelled { return }
            let url = child.standardizedFileURL
            guard let values = try? url.resourceValues(forKeys: Self.volumeKeySet) else { continue }
            guard values.volumeIsRootFileSystem != true else { continue }
            guard isDiskImage(url, values: values) else { continue }
            let opened = values.contentAccessDate
            let modified = values.contentModificationDate ?? values.volumeCreationDate
            let age = values.volumeCreationDate ?? modified ?? opened
            guard let age, age <= cutoff else { continue }
            let total = UInt64(max(0, values.volumeTotalCapacity ?? 0))
            let available = UInt64(max(0, values.volumeAvailableCapacity ?? 0))
            let bytes = total > available ? total - available : 0
            guard bytes > 0 else { continue }
            insert(CleanupCandidate(
                url: url,
                kind: .oldDiskImageMount,
                bytes: bytes,
                lastOpened: opened,
                modified: modified
            ), into: &found)
        }
    }

    // MARK: - Size

    private func recursiveAllocatedSize(of root: URL, rootVolume: NSObject?) -> UInt64? {
        if isCancelled { return nil }
        let keys = Self.resourceKeySet
        guard let values = try? root.resourceValues(forKeys: keys) else { return 0 }
        if values.isSymbolicLink == true || isCloudPlaceholder(values) { return 0 }
        if values.isDirectory != true {
            return allocated(values)
        }

        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: Self.resourceKeys,
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in true }
        ) else { return allocated(values) }

        var total = allocated(values)
        var seen = 0
        while let item = enumerator.nextObject() as? URL {
            seen += 1
            if seen & 63 == 0, isCancelled { return nil }
            guard let itemValues = try? item.resourceValues(forKeys: keys) else { continue }
            if itemValues.isSymbolicLink == true || itemValues.isAliasFile == true {
                enumerator.skipDescendants()
                continue
            }
            if isCloudPlaceholder(itemValues) {
                enumerator.skipDescendants()
                continue
            }
            if itemValues.isDirectory == true, !sameVolume(itemValues, rootVolume: rootVolume) {
                enumerator.skipDescendants()
                continue
            }
            if Self.skippedDirectoryNames.contains(item.lastPathComponent.lowercased()) {
                enumerator.skipDescendants()
                continue
            }
            if itemValues.isRegularFile == true || itemValues.isDirectory == true {
                total += allocated(itemValues)
            }
        }
        if isCancelled { return nil }
        return total
    }

    private func allocated(_ values: URLResourceValues) -> UInt64 {
        if let size = values.totalFileAllocatedSize, size > 0 { return UInt64(size) }
        if let size = values.fileAllocatedSize, size > 0 { return UInt64(size) }
        return 0
    }

    // MARK: - Predicates

    private func uniqueExistingRoots(home: URL) -> [URL] {
        var seen: Set<String> = []
        var result: [URL] = []
        for root in roots {
            let url = root.standardizedFileURL
            guard fileManager.fileExists(atPath: url.path) else { continue }
            guard seen.insert(url.path).inserted else { continue }
            result.append(url)
        }
        if result.isEmpty {
            return [home]
        }
        return result
    }

    private func isInstallerLocation(_ url: URL, home: URL) -> Bool {
        for name in ["Downloads", "Desktop", "Documents"] {
            if isInside(url, home.appendingPathComponent(name, isDirectory: true)) { return true }
        }
        return false
    }

    private func isInside(_ url: URL, _ directory: URL) -> Bool {
        let base = directory.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        return path == base || path.hasPrefix(base + "/")
    }

    private func isStale(_ opened: Date?, _ modified: Date?) -> Bool {
        let cutoff = Date().addingTimeInterval(-Self.oldInterval)
        guard let date = opened ?? modified else { return false }
        return date <= cutoff
    }

    private func isCloudPlaceholder(_ values: URLResourceValues) -> Bool {
        values.isUbiquitousItem == true && values.ubiquitousItemDownloadingStatus == .notDownloaded
    }

    private func isDiskImage(_ url: URL, values: URLResourceValues) -> Bool {
        if let source = values.volumeURLForRemounting {
            if Self.diskImageExtensions.contains(source.pathExtension.lowercased()) { return true }
        }
        let key = URLResourceKey(rawValue: "NSURLVolumeIsDiskImageKey")
        if let flag = (try? url.resourceValues(forKeys: [key]))?.allValues[key] as? Bool {
            return flag
        }
        return false
    }

    private func volumeIdentifier(of url: URL) -> NSObject? {
        try? url.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier as? NSObject
    }

    private func sameVolume(_ values: URLResourceValues, rootVolume: NSObject?) -> Bool {
        guard let rootVolume else { return true }
        guard let volume = values.volumeIdentifier as? NSObject else { return true }
        return volume.isEqual(rootVolume)
    }

    private func displayName(_ url: URL, home: URL) -> String {
        if url.path == home.path { return "Home" }
        return url.lastPathComponent
    }

    private func insert(_ candidate: CleanupCandidate, into found: inout [String: CleanupCandidate]) {
        let key = candidate.url.path
        guard let existing = found[key] else {
            found[key] = candidate
            return
        }
        if Self.specificity(candidate.kind) < Self.specificity(existing.kind) {
            found[key] = candidate
        }
    }

    /// Lower wins: installer, then old download, then large file.
    private static func specificity(_ kind: CleanupCandidate.Kind) -> Int {
        switch kind {
        case .installer: 0
        case .oldDownload: 1
        case .largeFile: 2
        case .xcodeArchive: 3
        case .iosBackup: 4
        case .oldDiskImageMount: 5
        }
    }

    private var isCancelled: Bool {
        lock.lock()
        let value = cancelled
        lock.unlock()
        return value
    }

    private static let resourceKeys: [URLResourceKey] = [
        .isDirectoryKey,
        .isPackageKey,
        .isSymbolicLinkKey,
        .isAliasFileKey,
        .isHiddenKey,
        .isRegularFileKey,
        .isUbiquitousItemKey,
        .ubiquitousItemDownloadingStatusKey,
        .fileAllocatedSizeKey,
        .totalFileAllocatedSizeKey,
        .contentAccessDateKey,
        .contentModificationDateKey,
        .volumeIdentifierKey,
    ]

    private static let resourceKeySet = Set(resourceKeys)

    private static let volumeKeys: [URLResourceKey] = [
        .volumeIsRootFileSystemKey,
        .volumeURLForRemountingKey,
        .volumeCreationDateKey,
        .volumeTotalCapacityKey,
        .volumeAvailableCapacityKey,
        .contentAccessDateKey,
        .contentModificationDateKey,
        .isSymbolicLinkKey,
    ]

    private static let volumeKeySet = Set(volumeKeys)
}
