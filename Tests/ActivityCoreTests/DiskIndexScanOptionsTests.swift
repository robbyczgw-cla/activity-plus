import Foundation
import Testing
@testable import ActivityCore

@Suite("Disk index: other roots")
struct DiskIndexScanOptionsTests {
    private func makeTree() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scanoptions-\(UUID().uuidString)")
        let fm = FileManager.default
        for folder in ["keep", "leave-out/inner", "locked"] {
            try fm.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        for (path, bytes) in [("keep/a.bin", 120_000), ("leave-out/inner/b.bin", 300_000), ("locked/c.bin", 50_000)] {
            var data = Data(count: bytes)
            data.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, bytes) }
            try data.write(to: root.appendingPathComponent(path))
        }
        return root.standardizedFileURL
    }

    @Test func excludedPathsAreLeftOut() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let full = DiskIndex.build(root: root)
        let index = DiskIndex.build(root: root, expectedEntries: nil,
                                    options: DiskIndex.ScanOptions(excluded: [root.appendingPathComponent("leave-out").path]))
        #expect(Set(index.children(of: index.rootID).map(\.name)) == ["keep", "locked"])
        #expect(index.id(of: root.appendingPathComponent("leave-out")) == nil)
        let leftOut = try #require(full.id(of: root.appendingPathComponent("leave-out")).flatMap { full.node($0) })
        #expect(index.node(index.rootID)!.bytes == full.node(full.rootID)!.bytes - leftOut.bytes)
    }

    @Test func foldersThatCannotBeOpenedAreMarkedUnread() throws {
        let root = try makeTree()
        let locked = root.appendingPathComponent("locked")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
            try? FileManager.default.removeItem(at: root)
        }
        let index = DiskIndex.build(root: root)
        let node = try #require(index.id(of: locked).flatMap { index.node($0) })
        #expect(node.isUnread)
        #expect(node.bytes == 0)
        let keep = try #require(index.id(of: root.appendingPathComponent("keep")).flatMap { index.node($0) })
        #expect(!keep.isUnread)
        #expect(!(index.node(index.rootID)!.isUnread))

        // The flag survives the cache file.
        let cache = root.deletingLastPathComponent().appendingPathComponent("\(root.lastPathComponent).bin")
        defer { try? FileManager.default.removeItem(at: cache) }
        try index.save(to: cache)
        let loaded = try #require(DiskIndex.load(from: cache))
        #expect(loaded.id(of: locked).flatMap { loaded.node($0) }?.isUnread == true)
    }

    @Test func startupDiskOptionsLeaveOutDoubleViews() {
        let options = DiskIndex.ScanOptions.startupDisk
        #expect(options.excluded.contains("/System/Volumes/Data"))
        #expect(options.excluded.contains("/.nofollow") && options.excluded.contains("/.resolve"))
        #expect(!options.mountPoints.contains("/System/Volumes/Data"))
    }
}
