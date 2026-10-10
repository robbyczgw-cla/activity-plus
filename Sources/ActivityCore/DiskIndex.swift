import Darwin
import Foundation

/// A size map of one folder tree (normally the home folder), read once and kept in memory.
/// Read-only: it never deletes or moves anything. `forget(_:)` only updates the map after the app moved items to the Trash.
///
/// Layout: one fixed-size record per file or folder in a flat array (no URL or String per node). A folder's
/// children sit next to each other, so a folder only stores where its block starts and how long it is;
/// `childOrder` holds each block sorted by size. Names are interned into one UTF-8 pool.
/// Node ids stay stable for the lifetime of an index (also across `forget`).
public final class DiskIndex: @unchecked Sendable {
    public typealias NodeID = Int32

    public struct Node: Sendable, Hashable, Identifiable {
        public let id: NodeID
        public let parent: NodeID          // -1 for the root
        public let name: String
        public let isDirectory: Bool
        /// Allocated bytes; for folders the sum of everything below.
        public let bytes: UInt64
        /// Files below (1 for a file).
        public let fileCount: Int
        public let modified: Date
        public let accessed: Date?
        /// For files: by extension. For folders: the kind with the most bytes below.
        public let kind: FileKind
        /// A folder that could not be opened (no permission, privacy protection, gone), so its size is unknown.
        public let isUnread: Bool
    }

    public let root: URL
    public let builtAt: Date
    public var rootID: NodeID { 0 }

    // MARK: Storage

    struct Record {
        var bytes: UInt64 = 0
        var parent: Int32 = -1
        var firstChild: Int32 = 0
        var childCount: Int32 = 0
        var name: UInt32 = 0
        var fileCount: UInt32 = 0
        /// Seconds since 1970; 0 = unknown.
        var modified: UInt32 = 0
        var accessed: UInt32 = 0
        var kind: UInt8 = 0
        var flags: UInt8 = 0

        static let directory: UInt8 = 1
        static let removed: UInt8 = 2
        /// Folder whose contents were deliberately not read (see `skippedFolders`, mount points).
        static let skipped: UInt8 = 4
        /// Folder the walk tried to open but could not.
        static let unread: UInt8 = 8
        /// While walking only: a mount point (another volume sits on it).
        static let mountPoint: UInt8 = 16
        /// While walking only: left out of the map (`ScanOptions.excluded`).
        static let excluded: UInt8 = 32

        var isDirectory: Bool { flags & Self.directory != 0 }
        var isRemoved: Bool { flags & Self.removed != 0 }
    }

    private var records: [Record]
    /// `childOrder[firstChild ..< firstChild + childCount]` = that folder's children, largest first.
    private var childOrder: [Int32]
    /// Name `i` is `nameBytes[nameStarts[i] ..< nameStarts[i + 1] - 1]`; every name ends with a NUL so it can go to `openat` directly.
    private let nameStarts: [UInt32]
    private let nameBytes: [UInt8]
    private let lock = NSLock()
    /// File ids, largest first; built on the first `files(matching:)` call.
    private var filesBySize: [Int32]?

    private static let kinds = FileKind.allCases

    init(root: URL, builtAt: Date, records: [Record], childOrder: [Int32], nameStarts: [UInt32], nameBytes: [UInt8]) {
        self.root = root
        self.builtAt = builtAt
        self.records = records
        self.childOrder = childOrder
        self.nameStarts = nameStarts
        self.nameBytes = nameBytes
    }

    /// Files and folders in the map (including removed ones).
    public var nodeCount: Int { records.count }

    // MARK: Queries

    public func node(_ id: NodeID) -> Node? {
        lock.lock(); defer { lock.unlock() }
        guard valid(id) else { return nil }
        return makeNode(id)
    }

    /// Direct children, largest first.
    public func children(of id: NodeID) -> [Node] {
        lock.lock(); defer { lock.unlock() }
        guard valid(id) else { return [] }
        let r = records[Int(id)]
        guard r.isDirectory, r.childCount > 0 else { return [] }
        var result: [Node] = []
        result.reserveCapacity(Int(r.childCount))
        for slot in Int(r.firstChild) ..< Int(r.firstChild + r.childCount) {
            let child = childOrder[slot]
            if !records[Int(child)].isRemoved { result.append(makeNode(child)) }
        }
        return result
    }

    /// The `limit` largest direct children (cheaper than `children(of:)` for folders with thousands of entries).
    public func children(of id: NodeID, limit: Int) -> [Node] {
        lock.lock(); defer { lock.unlock() }
        guard valid(id), limit > 0 else { return [] }
        let r = records[Int(id)]
        guard r.isDirectory, r.childCount > 0 else { return [] }
        var result: [Node] = []
        for slot in Int(r.firstChild) ..< Int(r.firstChild + r.childCount) where result.count < limit {
            let child = childOrder[slot]
            if !records[Int(child)].isRemoved { result.append(makeNode(child)) }
        }
        return result
    }

    /// Number of direct children.
    public func childCount(of id: NodeID) -> Int {
        lock.lock(); defer { lock.unlock() }
        guard valid(id) else { return 0 }
        let r = records[Int(id)]
        guard r.isDirectory else { return 0 }
        return (Int(r.firstChild) ..< Int(r.firstChild + r.childCount)).reduce(0) { $0 + (records[$1].isRemoved ? 0 : 1) }
    }

    public func url(of id: NodeID) -> URL {
        lock.lock(); defer { lock.unlock() }
        guard valid(id), id != rootID else { return root }
        var parts: [String] = []
        var current = id
        while current > 0 {
            parts.append(name(records[Int(current)].name))
            current = records[Int(current)].parent
        }
        var url = root
        for (index, part) in parts.reversed().enumerated() {
            url.appendPathComponent(part, isDirectory: index < parts.count - 1 || records[Int(id)].isDirectory)
        }
        return url
    }

    /// Chain from the root to `id`, root first (for a breadcrumb).
    public func ancestry(of id: NodeID) -> [Node] {
        lock.lock(); defer { lock.unlock() }
        guard valid(id) else { return [] }
        var chain: [Node] = []
        var current = id
        while current >= 0 {
            chain.append(makeNode(current))
            current = records[Int(current)].parent
        }
        return chain.reversed()
    }

    /// The node at `url`, if it lies inside the map.
    public func id(of url: URL) -> NodeID? {
        lock.lock(); defer { lock.unlock() }
        return lookup(url)
    }

    /// Bytes per kind below `id`, for the breakdown bar.
    public func kindTotals(under id: NodeID) -> [FileKind: UInt64] {
        lock.lock(); defer { lock.unlock() }
        guard valid(id) else { return [:] }
        let sums = kindSums(under: id)
        var result: [FileKind: UInt64] = [:]
        for (index, kind) in Self.kinds.enumerated() where sums[index] > 0 { result[kind] = sums[index] }
        return result
    }

    /// Files (not folders) matching the query, largest first.
    public func files(matching query: FileQuery, limit: Int) -> [Node] {
        lock.lock(); defer { lock.unlock() }
        guard limit > 0 else { return [] }
        if filesBySize == nil {
            var ids: [Int32] = []
            ids.reserveCapacity(records.count)
            for (index, r) in records.enumerated() where !r.isDirectory && r.bytes > 0 { ids.append(Int32(index)) }
            ids.sort { records[Int($0)].bytes > records[Int($1)].bytes }
            filesBySize = ids
        }
        let now = Date()
        var result: [Node] = []
        for id in filesBySize! {
            let r = records[Int(id)]
            if r.isRemoved { continue }
            let kind = Self.kinds[Int(r.kind)]
            let modified = Date(timeIntervalSince1970: TimeInterval(r.modified))
            let accessed = r.accessed > 0 ? Date(timeIntervalSince1970: TimeInterval(r.accessed)) : nil
            if query.matches(name: name(r.name), bytes: r.bytes, modified: modified, accessed: accessed, kind: kind, now: now) {
                result.append(makeNode(id))
                if result.count >= limit { break }
            }
        }
        return result
    }

    /// Removes items that were moved to the Trash and subtracts their size from every ancestor.
    public func forget(_ urls: [URL]) {
        lock.lock(); defer { lock.unlock() }
        var touched: Set<Int32> = []
        for url in urls {
            guard let id = lookup(url), id != rootID, !records[Int(id)].isRemoved else { continue }
            let bytes = records[Int(id)].bytes
            let files = records[Int(id)].fileCount
            // The whole subtree goes, so `files(matching:)` no longer finds anything inside it.
            var stack: [Int32] = [id]
            while let current = stack.popLast() {
                records[Int(current)].flags |= Record.removed
                let r = records[Int(current)]
                if r.isDirectory, r.childCount > 0 {
                    stack.append(contentsOf: Int32(r.firstChild) ..< r.firstChild + r.childCount)
                }
            }
            var ancestor = records[Int(id)].parent
            while ancestor >= 0 {
                records[Int(ancestor)].bytes -= min(bytes, records[Int(ancestor)].bytes)
                records[Int(ancestor)].fileCount -= min(files, records[Int(ancestor)].fileCount)
                touched.insert(ancestor)
                ancestor = records[Int(ancestor)].parent
            }
        }
        // Sizes changed: re-sort the blocks the changed folders sit in, and update their dominant kind.
        for id in touched {
            let parent = records[Int(id)].parent
            if parent >= 0 { sortBlock(of: parent) }
            sortBlock(of: id)
            let sums = kindSums(under: id)
            records[Int(id)].kind = Self.dominantKind(sums, fallback: records[Int(id)].kind)
        }
    }

    // MARK: Private helpers (lock held)

    private func valid(_ id: NodeID) -> Bool {
        id >= 0 && Int(id) < records.count && !records[Int(id)].isRemoved
    }

    private func name(_ index: UInt32) -> String {
        let start = Int(nameStarts[Int(index)])
        let end = Int(nameStarts[Int(index) + 1]) - 1
        return nameBytes.withUnsafeBufferPointer { String(decoding: UnsafeBufferPointer(rebasing: $0[start ..< end]), as: UTF8.self) }
    }

    private func makeNode(_ id: NodeID) -> Node {
        let r = records[Int(id)]
        return Node(id: id, parent: r.parent, name: id == rootID ? root.lastPathComponent : name(r.name),
                    isDirectory: r.isDirectory, bytes: r.bytes, fileCount: Int(r.fileCount),
                    modified: Date(timeIntervalSince1970: TimeInterval(r.modified)),
                    accessed: r.accessed > 0 ? Date(timeIntervalSince1970: TimeInterval(r.accessed)) : nil,
                    kind: Self.kinds[Int(r.kind)], isUnread: r.isDirectory && r.flags & Record.unread != 0)
    }

    private func lookup(_ url: URL) -> NodeID? {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        if path == rootPath { return rootID }
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard path.hasPrefix(prefix) else { return nil }
        var current = rootID
        for component in path.dropFirst(prefix.count).split(separator: "/") {
            let r = records[Int(current)]
            guard r.isDirectory else { return nil }
            var found: Int32?
            for child in r.firstChild ..< r.firstChild + r.childCount
            where !records[Int(child)].isRemoved && name(records[Int(child)].name) == component {
                found = child
                break
            }
            guard let found else { return nil }
            current = found
        }
        return current
    }

    private func sortBlock(of id: Int32) {
        let r = records[Int(id)]
        guard r.isDirectory, r.childCount > 1 else { return }
        let range = Int(r.firstChild) ..< Int(r.firstChild + r.childCount)
        childOrder[range].sort { records[Int($0)].bytes > records[Int($1)].bytes || (records[Int($0)].bytes == records[Int($1)].bytes && $0 < $1) }
    }

    private func kindSums(under id: NodeID) -> [UInt64] {
        var sums = [UInt64](repeating: 0, count: Self.kinds.count)
        let r = records[Int(id)]
        if !r.isDirectory { sums[Int(r.kind)] = r.bytes; return sums }
        // Children always have larger ids than their folder and blocks are contiguous,
        // so an explicit stack over the blocks visits the subtree without recursion.
        var stack: [Int32] = [id]
        while let current = stack.popLast() {
            let c = records[Int(current)]
            guard c.isDirectory, c.childCount > 0 else { continue }
            for child in Int(c.firstChild) ..< Int(c.firstChild + c.childCount) {
                let cr = records[child]
                if cr.isRemoved { continue }
                if cr.isDirectory { stack.append(Int32(child)) } else { sums[Int(cr.kind)] &+= cr.bytes }
            }
        }
        return sums
    }

    static func dominantKind(_ sums: [UInt64], fallback: UInt8) -> UInt8 {
        var best = -1
        var bestBytes: UInt64 = 0
        for (index, value) in sums.enumerated() where value > bestBytes { best = index; bestBytes = value }
        return best >= 0 ? UInt8(best) : fallback
    }

    // MARK: Building

    /// Walks `root`. Unreadable folders are skipped, not fatal. `progress(fraction, current folder)`; return early when `isCancelled()`.
    public static func build(root: URL, isCancelled: @escaping @Sendable () -> Bool = { false },
                             progress: @escaping @Sendable (Double, String) -> Void = { _, _ in }) -> DiskIndex {
        build(root: root, expectedEntries: nil, isCancelled: isCancelled, progress: progress)
    }

    /// Like `build(root:isCancelled:progress:)`; `expectedEntries` (the previous map's `nodeCount`) makes the progress fraction steadier.
    public static func build(root: URL, expectedEntries: Int?, options: ScanOptions = ScanOptions(),
                             isCancelled: @escaping @Sendable () -> Bool = { false },
                             progress: @escaping @Sendable (Double, String) -> Void = { _, _ in }) -> DiskIndex {
        Builder(root: root.standardizedFileURL, expected: expectedEntries, options: options, isCancelled: isCancelled, progress: progress).run()
    }

    /// Where the walk may go besides the root's own volume. By default it stays on that volume and never
    /// opens a mount point inside the tree (an external drive, a disk image, a network share).
    public struct ScanOptions: Sendable, Equatable {
        /// Mount points (absolute paths) the walk enters anyway; their volumes count as part of the tree.
        public var mountPoints: Set<String> = []
        /// Absolute paths left out of the map entirely.
        public var excluded: Set<String> = []

        public init(mountPoints: Set<String> = [], excluded: Set<String> = []) {
            self.mountPoints = mountPoints
            self.excluded = excluded
        }

        /// The whole startup disk from "/": the system and data volumes (one volume group, joined by firmlinks),
        /// plus the swap and boot volumes. Left out: the data volume's own mount point (its folders already
        /// appear through the firmlinks, it would count twice), the Update volume (a second view of the system),
        /// and the virtual folders that show the whole disk again (/.nofollow, /.resolve, /.vol).
        public static var startupDisk: ScanOptions {
            ScanOptions(mountPoints: ["/System/Volumes/VM", "/System/Volumes/Preboot"],
                        excluded: ["/System/Volumes/Data", "/System/Volumes/Update", "/.nofollow", "/.resolve", "/.vol", "/dev"])
        }
    }

    /// Folders whose contents are never read. Since macOS 14, opening another app's container raises
    /// "Activity+ would like to access data from other apps" for every sandboxed app (App Data protection),
    /// so the walk keeps these folders as entries of size 0 instead of reading them.
    public static var skippedFolders: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        return [home + "/Library/Containers", home + "/Library/Group Containers"]
    }

    /// Folders whose whole subtree counts as one kind, whatever the files are called
    /// (cache files rarely have an extension; a package's insides are not separate documents).
    static let folderKinds: [String: FileKind] = [
        "caches": .dataCache, "cache": .dataCache, ".cache": .dataCache, "logs": .dataCache,
        "node_modules": .code, ".build": .code, "deriveddata": .code, ".git": .code, ".gradle": .code,
    ]

    static let otherKind = UInt8(FileKind.allCases.firstIndex(of: .other)!)

    /// The walk: several threads take folders from a shared stack (getattrlistbulk is kernel-bound and
    /// scales with threads on APFS). Each folder read becomes a chunk; `assemble` lays the chunks out
    /// breadth-first, so every folder's children form one contiguous block after their folder.
    private final class Builder: @unchecked Sendable {
        struct Job {
            let id: Int32
            let path: String
            let inherited: UInt8?
            let top: Int32        // index of the top-level folder it belongs to, -1 for the root
        }

        /// One folder's entries. `Record.name` is an offset into `names`; for folders `Record.firstChild`
        /// becomes the job id of that folder's own chunk (-1 = not read).
        struct Chunk {
            var entries: [Record] = []
            var names: [UInt8] = []
            /// Inode and entry index of hard-linked files (more than one link).
            var links: [(index: Int, inode: UInt64)] = []
            var device: dev_t = 0
        }

        struct LinkKey: Hashable {
            let device: dev_t
            let inode: UInt64
        }

        let root: URL
        let expected: Int?
        let options: ScanOptions
        let isCancelled: @Sendable () -> Bool
        let progress: @Sendable (Double, String) -> Void
        let skipped: Set<String>

        // Shared state, guarded by `condition`.
        let condition = NSCondition()
        var stack: [Job] = []
        var chunks: [Chunk?] = []
        var busy = 0
        var stopped = false
        var seenLinks: Set<LinkKey> = []
        var entriesRead = 0
        var topCount = 0
        var topOutstanding: [Int] = []
        var topDone = 0
        var lastReport = Date.distantPast
        /// Volumes the walk may read: the root's, plus those of `options.mountPoints`.
        var devices: Set<dev_t> = []

        init(root: URL, expected: Int?, options: ScanOptions, isCancelled: @escaping @Sendable () -> Bool, progress: @escaping @Sendable (Double, String) -> Void) {
            self.root = root
            self.expected = expected.flatMap { $0 > 1000 ? $0 : nil }
            self.options = options
            self.isCancelled = isCancelled
            self.progress = progress
            skipped = Set(DiskIndex.skippedFolders)
        }

        func run() -> DiskIndex {
            var rootRecord = Record()
            rootRecord.flags = Record.directory
            rootRecord.kind = DiskIndex.otherKind
            var info = stat()
            guard stat(root.path, &info) == 0 else { return assemble(rootRecord) }
            devices = [info.st_dev]
            for mount in options.mountPoints {
                var mountInfo = stat()
                if stat(mount, &mountInfo) == 0 { devices.insert(mountInfo.st_dev) }
            }
            rootRecord.modified = UInt32(clamping: info.st_mtimespec.tv_sec)
            rootRecord.accessed = UInt32(clamping: info.st_atimespec.tv_sec)
            chunks = [nil]
            stack = [Job(id: 0, path: root.path, inherited: nil, top: -1)]
            let workers = max(2, min(8, ProcessInfo.processInfo.activeProcessorCount))
            DispatchQueue.concurrentPerform(iterations: workers) { _ in work() }
            progress(1, "")
            return assemble(rootRecord)
        }

        private func work() {
            // Never download iCloud files that are only in the cloud: touching a dataless item fails instead.
            let previousPolicy = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
            setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
            defer { if previousPolicy >= 0 { setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, previousPolicy) } }
            let reader = Reader()
            while true {
                condition.lock()
                while stack.isEmpty && busy > 0 && !stopped { condition.wait() }
                if stack.isEmpty || stopped {
                    condition.broadcast()
                    condition.unlock()
                    return
                }
                let job = stack.removeLast()
                busy += 1
                condition.unlock()

                if isCancelled() {
                    condition.lock()
                    stopped = true
                    busy -= 1
                    condition.broadcast()
                    condition.unlock()
                    return
                }
                // Read and prepare outside the lock: paths of the subfolders to descend into.
                var chunk = reader.read(job, devices: devices)
                var childPaths: [Int: (path: String, inherited: UInt8?)] = [:]
                if var read = chunk {
                    for index in read.entries.indices where read.entries[index].isDirectory {
                        let entry = read.entries[index]
                        let path = job.path + "/" + Reader.name(at: entry.name, in: read.names)
                        if options.excluded.contains(path) {
                            read.entries[index].flags |= Record.excluded
                            continue
                        }
                        // Another volume sits here: never opened (no prompts for removable or network volumes).
                        if entry.flags & Record.mountPoint != 0, !options.mountPoints.contains(path) {
                            read.entries[index].flags |= Record.skipped
                            continue
                        }
                        if entry.flags & Record.skipped != 0 || skipped.contains(path) {
                            read.entries[index].flags |= Record.skipped
                            continue
                        }
                        childPaths[index] = (path, job.inherited ?? (entry.kind == DiskIndex.otherKind ? nil : entry.kind))
                    }
                    chunk = read
                }

                condition.lock()
                if var read = chunk {
                    // Hard links: count the data once (an inode is unique per volume).
                    for link in read.links where !seenLinks.insert(LinkKey(device: read.device, inode: link.inode)).inserted {
                        read.entries[link.index].bytes = 0
                    }
                    read.links = []
                    var jobs: [Job] = []
                    for index in read.entries.indices {
                        guard let child = childPaths[index] else { continue }
                        let id = Int32(chunks.count)
                        chunks.append(nil)
                        read.entries[index].firstChild = id
                        var top = job.top
                        if top < 0 {
                            top = Int32(topOutstanding.count)
                            topOutstanding.append(0)
                            topCount += 1
                        }
                        topOutstanding[Int(top)] += 1
                        jobs.append(Job(id: id, path: child.path, inherited: child.inherited, top: top))
                    }
                    entriesRead += read.entries.count
                    chunks[Int(job.id)] = read
                    // Reversed so the stack pops them in directory order.
                    stack.append(contentsOf: jobs.reversed())
                }
                if job.top >= 0 {
                    topOutstanding[Int(job.top)] -= 1
                    if topOutstanding[Int(job.top)] == 0 { topDone += 1 }
                }
                busy -= 1
                reportLocked(job)
                condition.broadcast()
                condition.unlock()
            }
        }

        /// Fraction: top-level folders finished, or entries read against the previous scan when known.
        private func reportLocked(_ job: Job) {
            let now = Date()
            guard now.timeIntervalSince(lastReport) > 0.1 else { return }
            lastReport = now
            var fraction = Double(topDone) / Double(max(1, topCount))
            if let expected { fraction = max(fraction, Double(entriesRead) / Double(expected)) }
            let relative = job.path.count > root.path.count ? String(job.path.dropFirst(root.path.count + 1)) : ""
            let item = relative.split(separator: "/").prefix(2).joined(separator: "/")
            progress(min(0.99, fraction), item)
        }

        /// Lays the chunks out breadth-first and interns names into one pool, then rolls sizes up.
        private func assemble(_ rootRecord: Record) -> DiskIndex {
            var records: [Record] = []
            records.reserveCapacity(entriesRead + 1)
            var nameIDs: [String: UInt32] = [:]
            var nameStarts: [UInt32] = [0]
            var nameBytes: [UInt8] = []
            func intern(_ name: String) -> UInt32 {
                if let id = nameIDs[name] { return id }
                let id = UInt32(nameStarts.count - 1)
                nameBytes.append(contentsOf: name.utf8)
                nameBytes.append(0)
                nameStarts.append(UInt32(nameBytes.count))
                nameIDs[name] = id
                return id
            }
            var first = rootRecord
            first.name = intern(root.lastPathComponent)
            if chunks.isEmpty { first.flags |= Record.unread }
            records.append(first)
            var queue: [(chunk: Int32, node: Int32)] = chunks.isEmpty ? [] : [(0, 0)]
            var head = 0
            while head < queue.count {
                let (chunkID, node) = queue[head]
                head += 1
                guard let chunk = chunks[Int(chunkID)] else {   // unreadable or cancelled
                    records[Int(node)].flags |= Record.unread
                    continue
                }
                chunks[Int(chunkID)] = nil
                let kept = chunk.entries.filter { $0.flags & Record.excluded == 0 }
                records[Int(node)].firstChild = Int32(records.count)
                records[Int(node)].childCount = Int32(kept.count)
                for entry in kept {
                    var record = entry
                    record.flags &= ~Record.mountPoint
                    record.parent = node
                    record.name = intern(Reader.name(at: entry.name, in: chunk.names))
                    record.firstChild = 0
                    record.childCount = 0
                    if entry.isDirectory, entry.firstChild > 0 { queue.append((entry.firstChild, Int32(records.count))) }
                    records.append(record)
                }
            }
            chunks = []
            return Self.finish(root: root, records: records, nameStarts: nameStarts, nameBytes: nameBytes)
        }

        /// Rolls sizes up, picks each folder's dominant kind and sorts every block by size.
        static func finish(root: URL, records input: [Record], nameStarts: [UInt32], nameBytes: [UInt8]) -> DiskIndex {
            var records = input
            let count = records.count
            let kindCount = FileKind.allCases.count
            var folderSlot = [Int32](repeating: -1, count: count)
            var folders = 0
            for index in 0 ..< count where records[index].isDirectory {
                folderSlot[index] = Int32(folders)
                folders += 1
            }
            var sums = [UInt64](repeating: 0, count: folders * kindCount)
            // Children always come after their folder, so walking backwards is a post-order traversal.
            for index in stride(from: count - 1, through: 0, by: -1) {
                let r = records[index]
                if r.isDirectory {
                    let slot = Int(folderSlot[index]) * kindCount
                    // An empty folder keeps the kind its name gave it.
                    records[index].kind = DiskIndex.dominantKind(Array(sums[slot ..< slot + kindCount]), fallback: r.kind)
                    if r.parent >= 0 {
                        let parentSlot = Int(folderSlot[Int(r.parent)]) * kindCount
                        for k in 0 ..< kindCount { sums[parentSlot + k] &+= sums[slot + k] }
                    }
                } else if r.parent >= 0 {
                    sums[Int(folderSlot[Int(r.parent)]) * kindCount + Int(r.kind)] &+= r.bytes
                }
                if r.parent >= 0 {
                    records[Int(r.parent)].bytes &+= records[index].bytes
                    records[Int(r.parent)].fileCount &+= records[index].fileCount
                }
            }
            var order = [Int32](repeating: 0, count: count)
            for index in 0 ..< count {
                let r = records[index]
                guard r.isDirectory, r.childCount > 0 else { continue }
                let range = Int(r.firstChild) ..< Int(r.firstChild + r.childCount)
                for slot in range { order[slot] = Int32(slot) }
                order[range].sort { records[Int($0)].bytes > records[Int($1)].bytes || (records[Int($0)].bytes == records[Int($1)].bytes && $0 < $1) }
            }
            return DiskIndex(root: root, builtAt: Date(), records: records, childOrder: order, nameStarts: nameStarts, nameBytes: nameBytes)
        }
    }

    /// Reads one folder with getattrlistbulk. One per worker thread (own buffer and extension cache).
    private final class Reader {
        let bufferSize = 128 * 1024
        let buffer: UnsafeMutableRawPointer
        var extensionKinds: [String: UInt8] = [:]

        init() { buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 16) }
        deinit { buffer.deallocate() }

        // Attribute bits (sys/attr.h), spelled out so the types line up.
        static let cmnName: UInt32 = 0x0000_0001
        static let cmnObjType: UInt32 = 0x0000_0008
        static let cmnModTime: UInt32 = 0x0000_0400
        static let cmnAccTime: UInt32 = 0x0000_1000
        static let cmnFlags: UInt32 = 0x0004_0000
        static let cmnFileID: UInt32 = 0x0200_0000
        static let cmnError: UInt32 = 0x2000_0000
        static let cmnReturnedAttrs: UInt32 = 0x8000_0000
        static let dirMountStatus: UInt32 = 0x0000_0004
        static let mountStatusMountPoint: UInt32 = 0x0000_0001   // DIR_MNTSTATUS_MNTPOINT
        static let fileLinkCount: UInt32 = 0x0000_0001
        static let fileAllocSize: UInt32 = 0x0000_0004
        static let dataless: UInt32 = 0x4000_0000   // SF_DATALESS

        static func name(at offset: UInt32, in names: [UInt8]) -> String {
            names.withUnsafeBufferPointer { pool in
                let start = Int(offset)
                let end = pool[start...].firstIndex(of: 0) ?? pool.count
                return String(decoding: UnsafeBufferPointer(rebasing: pool[start ..< end]), as: UTF8.self)
            }
        }

        /// nil when the folder cannot be opened (permissions, privacy protection, gone) or is on another volume.
        func read(_ job: Builder.Job, devices: Set<dev_t>) -> Builder.Chunk? {
            let fd = open(job.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { return nil }
            defer { close(fd) }
            var info = stat()
            // Never cross into another volume (mount points inside the tree).
            guard fstat(fd, &info) == 0, devices.contains(info.st_dev) else { return nil }

            var request = attrlist()
            request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
            request.commonattr = Self.cmnReturnedAttrs | Self.cmnName | Self.cmnError | Self.cmnObjType
                | Self.cmnModTime | Self.cmnAccTime | Self.cmnFlags | Self.cmnFileID
            request.dirattr = Self.dirMountStatus
            request.fileattr = Self.fileLinkCount | Self.fileAllocSize
            var chunk = Builder.Chunk()
            chunk.device = info.st_dev
            while true {
                let count = getattrlistbulk(fd, &request, buffer, bufferSize, 0)
                if count <= 0 { break }   // 0 = done, -1 = unreadable: keep what was read
                var entry = UnsafeRawPointer(buffer)
                for _ in 0 ..< Int(count) {
                    let length = Int(entry.load(as: UInt32.self))
                    parse(entry, into: &chunk, inherited: job.inherited)
                    entry += length
                }
            }
            return chunk
        }

        private func parse(_ entry: UnsafeRawPointer, into chunk: inout Builder.Chunk, inherited: UInt8?) {
            var field = entry + 4
            let returned = field.loadUnaligned(as: attribute_set_t.self)
            field += MemoryLayout<attribute_set_t>.size
            if returned.commonattr & Self.cmnError != 0 {
                let error = field.loadUnaligned(as: UInt32.self)
                field += 4
                if error != 0 { return }
            }
            guard returned.commonattr & Self.cmnName != 0 else { return }
            let nameField = field
            let nameOffset = Int(field.loadUnaligned(as: Int32.self))
            let nameLength = Int(field.loadUnaligned(fromByteOffset: 4, as: UInt32.self))   // includes the NUL
            field += 8
            var objectType: UInt32 = 0
            if returned.commonattr & Self.cmnObjType != 0 { objectType = field.loadUnaligned(as: UInt32.self); field += 4 }
            var modified = 0
            if returned.commonattr & Self.cmnModTime != 0 { modified = field.loadUnaligned(as: timespec.self).tv_sec; field += MemoryLayout<timespec>.size }
            var accessed = 0
            if returned.commonattr & Self.cmnAccTime != 0 { accessed = field.loadUnaligned(as: timespec.self).tv_sec; field += MemoryLayout<timespec>.size }
            var flags: UInt32 = 0
            if returned.commonattr & Self.cmnFlags != 0 { flags = field.loadUnaligned(as: UInt32.self); field += 4 }
            var fileID: UInt64 = 0
            if returned.commonattr & Self.cmnFileID != 0 { fileID = field.loadUnaligned(as: UInt64.self); field += 8 }
            // Directory attributes come before file attributes in the buffer.
            var mountStatus: UInt32 = 0
            if returned.dirattr & Self.dirMountStatus != 0 { mountStatus = field.loadUnaligned(as: UInt32.self); field += 4 }
            var links: UInt32 = 1
            if returned.fileattr & Self.fileLinkCount != 0 { links = field.loadUnaligned(as: UInt32.self); field += 4 }
            var allocated: Int64 = 0
            if returned.fileattr & Self.fileAllocSize != 0 { allocated = field.loadUnaligned(as: Int64.self); field += 8 }

            let nameBytes = UnsafeRawBufferPointer(start: nameField + nameOffset, count: max(0, nameLength - 1))
            var record = Record()
            record.name = UInt32(chunk.names.count)
            chunk.names.append(contentsOf: nameBytes)
            chunk.names.append(0)
            record.modified = UInt32(clamping: modified)
            record.accessed = UInt32(clamping: accessed)
            record.firstChild = -1
            if objectType == UInt32(VDIR.rawValue) {
                record.flags = Record.directory
                // Evicted iCloud folders: reading them would ask the File Provider to fetch the listing.
                if flags & Self.dataless != 0 { record.flags |= Record.skipped }
                if mountStatus & Self.mountStatusMountPoint != 0 { record.flags |= Record.mountPoint }
                // A folder with a telling name or extension (Caches, node_modules, Foo.app, X.sparsebundle)
                // passes its kind to everything below.
                let name = String(decoding: nameBytes, as: UTF8.self)
                let folderKind = DiskIndex.folderKinds[name.lowercased()].flatMap { FileKind.allCases.firstIndex(of: $0) }.map(UInt8.init)
                record.kind = inherited ?? folderKind ?? kind(of: nameBytes)
            } else {
                record.fileCount = 1
                record.kind = inherited ?? kind(of: nameBytes)
                record.bytes = UInt64(max(0, allocated))
                if links > 1, objectType == UInt32(VREG.rawValue) { chunk.links.append((chunk.entries.count, fileID)) }
            }
            chunk.entries.append(record)
        }

        /// Kind from the extension, cached per extension (FileKind.classify goes through NSString).
        private func kind(of name: UnsafeRawBufferPointer) -> UInt8 {
            guard let dot = name.lastIndex(of: UInt8(ascii: ".")), dot > 0, dot < name.count - 1, name.count - dot - 1 <= 16 else { return DiskIndex.otherKind }
            let key = String(decoding: UnsafeRawBufferPointer(rebasing: name[(dot + 1)...]), as: UTF8.self).lowercased()
            if let cached = extensionKinds[key] { return cached }
            let kind = UInt8(FileKind.allCases.firstIndex(of: FileKind.classify(name: "a." + key)) ?? Int(DiskIndex.otherKind))
            extensionKinds[key] = kind
            return kind
        }
    }

    // MARK: Cache file

    private static let magic: UInt32 = 0x4150_4458   // "APDX"
    private static let version: UInt32 = 1

    /// Cache on disk so the map opens instantly next time.
    public func save(to url: URL) throws {
        lock.lock()
        defer { lock.unlock() }
        var data = Data()
        func put<T>(_ value: T) { withUnsafeBytes(of: value) { data.append(contentsOf: $0) } }
        func putArray<T>(_ array: [T]) { array.withUnsafeBytes { data.append(contentsOf: $0) } }
        let rootPath = Array(root.path.utf8)
        put(Self.magic)
        put(Self.version)
        put(UInt32(MemoryLayout<Record>.stride))
        put(UInt32(records.count))
        put(UInt32(nameStarts.count))
        put(UInt32(nameBytes.count))
        put(UInt32(rootPath.count))
        put(UInt32(0))
        put(builtAt.timeIntervalSince1970)
        putArray(rootPath)
        while data.count % 8 != 0 { data.append(0) }
        putArray(records)
        putArray(childOrder)
        putArray(nameStarts)
        putArray(nameBytes)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    public static func load(from url: URL) -> DiskIndex? {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }
        return data.withUnsafeBytes { raw -> DiskIndex? in
            var offset = 0
            func get<T>(_: T.Type) -> T? {
                guard offset + MemoryLayout<T>.size <= raw.count else { return nil }
                defer { offset += MemoryLayout<T>.size }
                return raw.loadUnaligned(fromByteOffset: offset, as: T.self)
            }
            func getArray<T>(_: T.Type, _ count: Int) -> [T]? {
                let size = count * MemoryLayout<T>.stride
                guard count >= 0, offset + size <= raw.count else { return nil }
                defer { offset += size }
                return [T](unsafeUninitializedCapacity: count) { buffer, initialized in
                    UnsafeMutableRawBufferPointer(buffer).copyMemory(from: UnsafeRawBufferPointer(rebasing: raw[offset ..< offset + size]))
                    initialized = count
                }
            }
            guard get(UInt32.self) == magic, get(UInt32.self) == version,
                  get(UInt32.self) == UInt32(MemoryLayout<Record>.stride),
                  let count = get(UInt32.self), let nameCount = get(UInt32.self), let poolSize = get(UInt32.self),
                  let pathLength = get(UInt32.self), get(UInt32.self) != nil, let built = get(Double.self),
                  let path = getArray(UInt8.self, Int(pathLength)) else { return nil }
            offset = (offset + 7) / 8 * 8
            guard count > 0, nameCount > 0,
                  let records = getArray(Record.self, Int(count)),
                  let order = getArray(Int32.self, Int(count)),
                  let starts = getArray(UInt32.self, Int(nameCount)),
                  let pool = getArray(UInt8.self, Int(poolSize)),
                  starts.last == UInt32(pool.count) else { return nil }
            // Cheap sanity check against a damaged file: every reference stays in range.
            for r in records {
                guard Int(r.name) + 1 < starts.count, r.parent < Int32(count),
                      r.firstChild >= 0, Int(r.firstChild) + Int(r.childCount) <= Int(count), Int(r.kind) < kinds.count else { return nil }
            }
            return DiskIndex(root: URL(fileURLWithPath: String(decoding: path, as: UTF8.self), isDirectory: true),
                             builtAt: Date(timeIntervalSince1970: built), records: records, childOrder: order,
                             nameStarts: starts, nameBytes: pool)
        }
    }
}
