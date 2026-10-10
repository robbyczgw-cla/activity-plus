import Foundation

/// A search like `ext:dmg size:>300mb age:>90d invoice`. STUB — the real parser replaces this file; keep the public API.
public struct FileQuery: Sendable, Equatable {
    public init() {}
    public static func parse(_ text: String) -> FileQuery { FileQuery() }
    public var isEmpty: Bool { true }
    public func matches(name: String, bytes: UInt64, modified: Date, accessed: Date?, kind: FileKind, now: Date = Date()) -> Bool { true }
}
