import Foundation

/// "What grew": a compact summary of each finished scan (folder sizes down to a few levels), kept for the
/// last dozen scans, and the folders that grew or shrank the most between two of them.
public enum DiskGrowth {
    /// Folder sizes of one scan. Paths are relative to the scanned root ("Library/Caches").
    public struct Summary: Codable, Sendable, Equatable {
        public var date: Date
        public var root: String
        public var totalBytes: UInt64
        public var fileCount: Int
        /// Folders down to `maxDepth` levels below the root with at least `minBytes`.
        public var folders: [String: UInt64]
        /// The threshold used; a folder missing from `folders` was smaller than this (or did not exist).
        public var minBytes: UInt64

        public init(date: Date, root: String, totalBytes: UInt64, fileCount: Int, folders: [String: UInt64], minBytes: UInt64) {
            self.date = date
            self.root = root
            self.totalBytes = totalBytes
            self.fileCount = fileCount
            self.folders = folders
            self.minBytes = minBytes
        }
    }

    /// One folder that grew (delta > 0) or shrank.
    public struct Change: Sendable, Equatable, Identifiable {
        public let path: String
        /// nil = below the summary's threshold (or not there at all).
        public let oldBytes: UInt64?
        public let newBytes: UInt64?
        public var id: String { path }

        public var delta: Int64 { Int64(clamping: newBytes ?? 0) - Int64(clamping: oldBytes ?? 0) }
        public var grew: Bool { delta > 0 }
        /// Only in the newer scan / only in the older one.
        public var isNew: Bool { oldBytes == nil }
        public var isGone: Bool { newBytes == nil }
        public var name: String { path.split(separator: "/").last.map(String.init) ?? path }
    }

    public static let defaultDepth = 4
    public static let defaultMinBytes: UInt64 = 50_000_000
    public static let keep = 12

    /// Reads the folder sizes from a map. Children come largest first, so each level stops at the first small one.
    public static func summarize(_ index: DiskIndex, date: Date? = nil, maxDepth: Int = defaultDepth,
                                 minBytes: UInt64 = defaultMinBytes) -> Summary {
        var folders: [String: UInt64] = [:]
        var stack: [(id: DiskIndex.NodeID, path: String, depth: Int)] = [(index.rootID, "", 0)]
        while let (id, path, depth) = stack.popLast() {
            guard depth < maxDepth else { continue }
            for child in index.children(of: id) {
                guard child.bytes >= minBytes else { break }
                guard child.isDirectory else { continue }
                let childPath = path.isEmpty ? child.name : path + "/" + child.name
                folders[childPath] = child.bytes
                stack.append((child.id, childPath, depth + 1))
            }
        }
        let root = index.node(index.rootID)
        return Summary(date: date ?? index.builtAt, root: index.root.standardizedFileURL.path,
                       totalBytes: root?.bytes ?? 0, fileCount: root?.fileCount ?? 0, folders: folders, minBytes: minBytes)
    }

    /// The folders that changed most from `old` to `new`, largest change first.
    ///
    /// Nested folders are not listed twice: when one subfolder accounts for at least three quarters of its
    /// parent's change, the subfolder is listed instead (more precise, same story); other subfolders that changed
    /// the same way are part of the parent's line. A subfolder that changed the other way (Library grew while
    /// Library/Caches shrank) gets its own line, and a parent whose net change is explained by lines already
    /// listed below it is left out.
    public static func changes(from old: Summary, to new: Summary, minChange: UInt64 = 100_000_000, limit: Int = 8) -> [Change] {
        let paths = Set(old.folders.keys).union(new.folders.keys)
        var all = paths.map { Change(path: $0, oldBytes: old.folders[$0], newBytes: new.folders[$0]) }
            .filter { $0.delta.magnitude >= minChange }
        all.sort { $0.delta.magnitude != $1.delta.magnitude ? $0.delta.magnitude > $1.delta.magnitude : $0.path < $1.path }

        var selected: [Change] = []
        for change in all {
            if selected.contains(where: { isAncestor(change.path, of: $0.path) }) { continue }
            if let at = selected.firstIndex(where: { isAncestor($0.path, of: change.path) && $0.grew == change.grew }) {
                if change.delta.magnitude * 4 >= selected[at].delta.magnitude * 3 { selected[at] = change }
                continue
            }
            selected.append(change)
        }
        selected.sort { $0.delta.magnitude != $1.delta.magnitude ? $0.delta.magnitude > $1.delta.magnitude : $0.path < $1.path }
        return Array(selected.prefix(limit))
    }

    static func isAncestor(_ ancestor: String, of path: String) -> Bool {
        path.count > ancestor.count && path.hasPrefix(ancestor) && path[path.index(path.startIndex, offsetBy: ancestor.count)] == "/"
    }

    /// The summaries of one scanned root, oldest first, stored as a small JSON file.
    public struct History: Codable, Sendable, Equatable {
        public var summaries: [Summary] = []

        public init(summaries: [Summary] = []) { self.summaries = summaries }

        /// Adds a summary in date order; one from the same moment replaces the old one. Keeps the newest `keep`.
        public mutating func add(_ summary: Summary, keep: Int = DiskGrowth.keep) {
            summaries.removeAll { abs($0.date.timeIntervalSince(summary.date)) < 1 }
            summaries.append(summary)
            summaries.sort { $0.date < $1.date }
            if summaries.count > keep { summaries.removeFirst(summaries.count - keep) }
        }

        public func contains(date: Date) -> Bool {
            summaries.contains { abs($0.date.timeIntervalSince(date)) < 1 }
        }

        public static func load(from url: URL) -> History {
            guard let data = try? Data(contentsOf: url) else { return History() }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            return (try? decoder.decode(History.self, from: data)) ?? History()
        }

        public func save(to url: URL) throws {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .secondsSince1970
            encoder.outputFormatting = [.sortedKeys]
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(self).write(to: url, options: .atomic)
        }
    }
}
