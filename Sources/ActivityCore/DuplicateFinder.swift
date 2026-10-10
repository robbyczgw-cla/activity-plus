import CryptoKit
import Darwin
import Foundation

/// Finds files with identical contents: same size first, then a hash of the first and last 64 KB,
/// then a full SHA-256 only for the files still alike. Reads files, never changes them.
public enum DuplicateFinder {
    public struct File: Sendable, Hashable, Identifiable {
        public let path: String
        /// Logical size in bytes.
        public let size: UInt64
        public let modified: Date
        public var id: String { path }
        public var name: String { (path as NSString).lastPathComponent }

        public init(path: String, size: UInt64, modified: Date) {
            self.path = path
            self.size = size
            self.modified = modified
        }
    }

    /// Copies of one file. `files[0]` is the copy to keep: the newest, or the first found when equally new.
    public struct Group: Sendable, Identifiable, Equatable {
        public let id: String
        public let size: UInt64
        public var files: [File]

        public init(id: String, size: UInt64, files: [File]) {
            self.id = id
            self.size = size
            self.files = files
        }

        public var keep: File { files[0] }
        public var copies: Int { files.count }
        /// Space the extra copies take.
        public var wasted: UInt64 { size * UInt64(max(0, files.count - 1)) }
    }

    public enum Phase: Sendable, Equatable {
        case sizes, partial, full
    }

    public struct Progress: Sendable, Equatable {
        public let phase: Phase
        public let done: Int
        public let total: Int
        /// Overall, 0...1 (sizes 5 %, first and last bytes 25 %, full contents 70 %).
        public var fraction: Double {
            let local = total > 0 ? Double(done) / Double(total) : 1
            switch phase {
            case .sizes: return 0.05 * local
            case .partial: return 0.05 + 0.25 * local
            case .full: return 0.30 + 0.70 * local
            }
        }
    }

    /// Folders whose insides belong together (apps, libraries, project packages): never searched.
    public static let packageExtensions: Set<String> = [
        "app", "appex", "bundle", "framework", "plugin", "kext", "xpc", "systemextension", "driver", "prefpane",
        "saver", "qlgenerator", "mdimporter", "component", "vst", "vst3", "aaxplugin", "wdgt",
        "photoslibrary", "photolibrary", "aplibrary", "migratedphotolibrary", "musiclibrary", "tvlibrary",
        "imovielibrary", "theater", "fcpbundle", "logicx", "band", "lrdata", "lrlibrary",
        "sparsebundle", "xcarchive", "xcodeproj", "xcworkspace", "playground", "docarchive", "dsym", "mlmodelc",
        "pages", "numbers", "key", "rtfd", "pkg", "mpkg",
    ]

    public static let partialChunk = 64 * 1024

    /// Files of at least `minBytes` (allocated) below `start` in the map. Never goes into packages, hidden folders
    /// or folders for which `skip(path)` is true. Files that only exist in iCloud or are a second hard link have
    /// 0 bytes in the map, so they are left out here already.
    public static func candidates(in index: DiskIndex, under start: DiskIndex.NodeID, minBytes: UInt64,
                                  skip: (String) -> Bool = { _ in false }) -> [String] {
        let base = index.url(of: start).standardizedFileURL.path
        var result: [String] = []
        var stack: [(id: DiskIndex.NodeID, path: String)] = [(start, base == "/" ? "" : base)]
        while let (id, path) = stack.popLast() {
            for child in index.children(of: id) {
                guard child.bytes >= max(1, minBytes) else { break }   // largest first
                let childPath = path + "/" + child.name
                if child.isDirectory {
                    if isPackage(child.name) || child.name.hasPrefix(".") || skip(childPath) { continue }
                    stack.append((child.id, childPath))
                } else {
                    result.append(childPath)
                }
            }
        }
        return result
    }

    static func isPackage(_ name: String) -> Bool {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return false }
        return packageExtensions.contains(name[name.index(after: dot)...].lowercased())
    }

    /// Groups of identical files among `paths`, most wasted space first. Skips anything that is not a regular
    /// file, smaller than `minBytes`, only in iCloud (nothing allocated) or another hard link to a file already seen.
    public static func find(paths: [String], minBytes: UInt64, workers: Int = 4,
                            isCancelled: @escaping @Sendable () -> Bool = { false },
                            progress: @escaping @Sendable (Progress) -> Void = { _ in }) -> [Group] {
        // 1. Sizes.
        var seen: Set<FileKey> = []
        var bySize: [UInt64: [File]] = [:]
        for (position, path) in paths.enumerated() {
            if isCancelled() { return [] }
            if position % 500 == 0 { progress(Progress(phase: .sizes, done: position, total: paths.count)) }
            var info = stat()
            guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size > 0,
                  UInt64(info.st_size) >= minBytes, info.st_blocks > 0, info.st_flags & dataless == 0,
                  seen.insert(FileKey(device: info.st_dev, inode: info.st_ino)).inserted else { continue }
            bySize[UInt64(info.st_size), default: []].append(File(path: path, size: UInt64(info.st_size), modified: modified(info)))
        }
        let sameSize = bySize.values.filter { $0.count > 1 }
        guard !sameSize.isEmpty else { return [] }

        // 2. First and last 64 KB.
        let partialFiles = sameSize.flatMap { $0 }
        let partial = hashAll(partialFiles, phase: .partial, workers: workers, isCancelled: isCancelled, progress: progress) {
            partialHash(of: $0)
        }
        if isCancelled() { return [] }
        var byPartial: [String: [File]] = [:]
        for file in partialFiles {
            guard let hash = partial[file.path] else { continue }
            byPartial["\(file.size)-\(hash)", default: []].append(file)
        }

        // 3. Full contents, only where the first and last bytes did not already cover the whole file.
        var groups: [Group] = []
        var needFull: [[File]] = []
        for (key, files) in byPartial where files.count > 1 {
            if files[0].size <= UInt64(2 * partialChunk) {
                groups.append(Group(id: key, size: files[0].size, files: files))
            } else {
                needFull.append(files)
            }
        }
        let fullFiles = needFull.flatMap { $0 }
        let full = hashAll(fullFiles, phase: .full, workers: workers, isCancelled: isCancelled, progress: progress) {
            fullHash(of: $0, isCancelled: isCancelled)
        }
        if isCancelled() { return [] }
        var byFull: [String: [File]] = [:]
        for file in fullFiles {
            guard let hash = full[file.path] else { continue }
            byFull["\(file.size)-\(hash)", default: []].append(file)
        }
        for (key, files) in byFull where files.count > 1 {
            groups.append(Group(id: key, size: files[0].size, files: files))
        }

        // Keep the newest copy; equally new: the first found.
        let order = Dictionary(paths.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        for at in groups.indices {
            groups[at].files.sort {
                $0.modified != $1.modified ? $0.modified > $1.modified : (order[$0.path] ?? 0) < (order[$1.path] ?? 0)
            }
        }
        groups.sort { $0.wasted != $1.wasted ? $0.wasted > $1.wasted : $0.keep.path < $1.keep.path }
        return groups
    }

    /// The selected copies of `group` that may go, never all of them: if every copy is selected, the copy to keep stays.
    public static func removable(_ selection: Set<String>, in group: Group) -> [String] {
        let chosen = group.files.map(\.path).filter { selection.contains($0) }
        if chosen.count >= group.files.count { return chosen.filter { $0 != group.keep.path } }
        return chosen
    }

    /// Checks right before moving to the Trash: of `removing`, only copies that are unchanged since the search,
    /// and only while at least one other copy is still there, unchanged. Otherwise nothing.
    public static func stillSafe(_ removing: [String], in group: Group) -> [String] {
        let wanted = Set(removable(Set(removing), in: group))
        let unchanged = Set(group.files.filter { isUnchanged($0) }.map(\.path))
        let staying = group.files.filter { !wanted.contains($0.path) && unchanged.contains($0.path) }
        guard !staying.isEmpty else { return [] }
        return group.files.map(\.path).filter { wanted.contains($0) && unchanged.contains($0) }
    }

    static func isUnchanged(_ file: File) -> Bool {
        var info = stat()
        guard lstat(file.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return false }
        return UInt64(info.st_size) == file.size && abs(modified(info).timeIntervalSince(file.modified)) < 0.001
    }

    // MARK: Hashing

    struct FileKey: Hashable {
        let device: dev_t
        let inode: UInt64
    }

    static let dataless: UInt32 = 0x4000_0000   // SF_DATALESS

    static func modified(_ info: stat) -> Date {
        Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1e9)
    }

    /// Hashes every file on `workers` threads; a file that cannot be read (or changed meanwhile) gets no hash.
    private static func hashAll(_ files: [File], phase: Phase, workers: Int, isCancelled: @escaping @Sendable () -> Bool,
                                progress: @escaping @Sendable (Progress) -> Void,
                                hash: @escaping @Sendable (File) -> String?) -> [String: String] {
        guard !files.isEmpty else { return [:] }
        let lock = NSLock()
        var results: [String: String] = [:]
        var next = 0
        var done = 0
        progress(Progress(phase: phase, done: 0, total: files.count))
        DispatchQueue.concurrentPerform(iterations: max(1, min(workers, files.count))) { _ in
            while true {
                lock.lock()
                let at = next
                next += 1
                lock.unlock()
                guard at < files.count, !isCancelled() else { return }
                let value = hash(files[at])
                lock.lock()
                if let value { results[files[at].path] = value }
                done += 1
                let count = done
                lock.unlock()
                if count % 20 == 0 || count == files.count { progress(Progress(phase: phase, done: count, total: files.count)) }
            }
        }
        return results
    }

    /// Opens without following links and without downloading iCloud files; nil if it changed since the size step.
    private static func withFile<T>(_ file: File, _ body: (Int32) -> T?) -> T? {
        let previous = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
        setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
        defer { if previous >= 0 { setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, previous) } }
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, UInt64(info.st_size) == file.size else { return nil }
        return body(fd)
    }

    static func partialHash(of file: File) -> String? {
        withFile(file) { fd in
            var hasher = SHA256()
            let chunk = partialChunk
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: chunk, alignment: 16)
            defer { buffer.deallocate() }
            func readAt(_ offset: off_t, _ count: Int) -> Bool {
                var got = 0
                while got < count {
                    let n = pread(fd, buffer + got, count - got, offset + off_t(got))
                    if n <= 0 { return false }
                    got += n
                }
                hasher.update(bufferPointer: UnsafeRawBufferPointer(start: buffer, count: count))
                return true
            }
            let size = Int(file.size)
            if size <= 2 * chunk {
                var offset = 0
                while offset < size {
                    let count = min(chunk, size - offset)
                    guard readAt(off_t(offset), count) else { return nil }
                    offset += count
                }
            } else {
                guard readAt(0, chunk), readAt(off_t(size - chunk), chunk) else { return nil }
            }
            return hex(hasher.finalize())
        }
    }

    static func fullHash(of file: File, isCancelled: @Sendable () -> Bool) -> String? {
        withFile(file) { fd in
            _ = fcntl(fd, F_NOCACHE, 1)   // one pass over possibly large files: keep the cache for everything else
            var hasher = SHA256()
            let chunk = 1 << 20
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: chunk, alignment: 16)
            defer { buffer.deallocate() }
            var total: UInt64 = 0
            while true {
                if isCancelled() { return nil }
                let n = read(fd, buffer, chunk)
                if n < 0 { return nil }
                if n == 0 { break }
                hasher.update(bufferPointer: UnsafeRawBufferPointer(start: buffer, count: n))
                total += UInt64(n)
            }
            guard total == file.size else { return nil }
            return hex(hasher.finalize())
        }
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
