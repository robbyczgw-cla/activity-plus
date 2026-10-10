import Foundation

/// Names the parts of macOS's grey "System Data". STUB — replaced by the real implementation; keep the public API.
public enum SystemDataBreakdown {
    public struct Group: Sendable, Identifiable {
        public let id: String
        public let title: String
        public let safety: Safety
        public let items: [ReclaimableItem]
        public var bytes: UInt64 { items.reduce(0) { $0 + $1.bytes } }
        public init(id: String, title: String, safety: Safety, items: [ReclaimableItem]) {
            self.id = id; self.title = title; self.safety = safety; self.items = items
        }
    }

    /// Measures the known locations. Read-only. Slow (walks folders): call off the main thread.
    public static func measure(isCancelled: @escaping @Sendable () -> Bool = { false },
                               progress: @escaping @Sendable (Double, String) -> Void = { _, _ in }) -> [Group] { [] }
}
