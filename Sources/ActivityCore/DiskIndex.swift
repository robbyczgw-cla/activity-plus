import Foundation

/// A size map of one folder tree (normally the home folder), read once and kept in memory.
/// Read-only: it never deletes or moves anything. `forget(_:)` only updates the map after the app moved items to the Trash.
/// STUB — the real scanner replaces this file; keep the public API.
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
    }

    public let root: URL
    public let builtAt: Date
    public var rootID: NodeID { 0 }

    init(root: URL, builtAt: Date) {
        self.root = root
        self.builtAt = builtAt
    }

    public func node(_ id: NodeID) -> Node? { nil }
    /// Direct children, largest first.
    public func children(of id: NodeID) -> [Node] { [] }
    public func url(of id: NodeID) -> URL { root }
    /// Chain from the root to `id`, root first (for a breadcrumb).
    public func ancestry(of id: NodeID) -> [Node] { [] }
    /// Bytes per kind below `id`, for the breakdown bar.
    public func kindTotals(under id: NodeID) -> [FileKind: UInt64] { [:] }
    /// Files (not folders) matching the query, largest first.
    public func files(matching query: FileQuery, limit: Int) -> [Node] { [] }
    /// Removes items that were moved to the Trash and subtracts their size from every ancestor.
    public func forget(_ urls: [URL]) {}

    /// Walks `root`. Unreadable folders are skipped, not fatal. `progress(fraction, current folder)`; return early when `isCancelled()`.
    public static func build(root: URL, isCancelled: @escaping @Sendable () -> Bool = { false },
                             progress: @escaping @Sendable (Double, String) -> Void = { _, _ in }) -> DiskIndex {
        DiskIndex(root: root, builtAt: Date())
    }

    /// Cache on disk so the map opens instantly next time.
    public func save(to url: URL) throws {}
    public static func load(from url: URL) -> DiskIndex? { nil }
}
