import Foundation
import Testing
@testable import ActivityCore

@Suite("Disk index")
struct DiskIndexTests {
    /// root/
    ///   Movies/clip.mov (400 kB), Movies/old.mov (100 kB)
    ///   Code/main.swift (20 kB), Code/Caches/blob (50 kB, counts as data & caches)
    ///   notes.txt (8 kB), link-to-outside -> a folder outside the root (not followed)
    ///   twin.dat + twin-link.dat (one file, two hard links: counted once)
    final class Tree {
        let root: URL
        let outside: URL

        init() throws {
            let base = FileManager.default.temporaryDirectory.appendingPathComponent("diskindex-\(UUID().uuidString)")
            root = base.appendingPathComponent("root")
            outside = base.appendingPathComponent("outside")
            let fm = FileManager.default
            for folder in ["Movies", "Code/Caches"] { try fm.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true) }
            try fm.createDirectory(at: outside, withIntermediateDirectories: true)
            try write("Movies/clip.mov", 400_000)
            try write("Movies/old.mov", 100_000)
            try write("Code/main.swift", 20_000)
            try write("Code/Caches/blob", 50_000)
            try write("notes.txt", 8_000)
            try write("twin.dat", 64_000)
            try fm.linkItem(at: root.appendingPathComponent("twin.dat"), to: root.appendingPathComponent("twin-link.dat"))
            try Data(count: 2_000_000).write(to: outside.appendingPathComponent("big.bin"))
            try fm.createSymbolicLink(at: root.appendingPathComponent("link-to-outside"), withDestinationURL: outside)
        }

        deinit { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

        func write(_ path: String, _ bytes: Int) throws {
            // Random bytes so APFS cannot compress or share the blocks.
            var data = Data(count: bytes)
            data.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, bytes) }
            try data.write(to: root.appendingPathComponent(path))
        }

        func allocated(_ path: String) -> UInt64 {
            var info = stat()
            guard lstat(root.appendingPathComponent(path).path, &info) == 0 else { return 0 }
            return UInt64(info.st_blocks) * 512
        }
    }

    @Test func rollsSizesUpAndSortsChildren() throws {
        let tree = try Tree()
        let index = DiskIndex.build(root: tree.root)
        let root = try #require(index.node(index.rootID))
        let files = ["Movies/clip.mov", "Movies/old.mov", "Code/main.swift", "Code/Caches/blob", "notes.txt", "twin.dat", "link-to-outside"]
        let expected = files.reduce(UInt64(0)) { $0 + tree.allocated($1) }
        #expect(root.bytes == expected)          // twin-link.dat adds nothing, the symlink is not followed
        #expect(root.fileCount == 8)             // every name counts as a file, hard link included
        #expect(root.isDirectory && root.parent == -1)

        let children = index.children(of: index.rootID)
        #expect(children.map(\.bytes) == children.map(\.bytes).sorted(by: >))
        #expect(children.first?.name == "Movies")
        let movies = try #require(children.first)
        #expect(movies.bytes == tree.allocated("Movies/clip.mov") + tree.allocated("Movies/old.mov"))
        #expect(movies.fileCount == 2)
        #expect(movies.kind == .video)
        #expect(index.children(of: movies.id).map(\.name) == ["clip.mov", "old.mov"])
        let link = try #require(children.first { $0.name == "link-to-outside" })
        #expect(!link.isDirectory)
    }

    @Test func kindsAndPaths() throws {
        let tree = try Tree()
        let index = DiskIndex.build(root: tree.root)
        let totals = index.kindTotals(under: index.rootID)
        #expect(totals[.video] == tree.allocated("Movies/clip.mov") + tree.allocated("Movies/old.mov"))
        #expect(totals[.dataCache] == tree.allocated("Code/Caches/blob"))   // no extension, but inside Caches
        #expect(totals[.code] == tree.allocated("Code/main.swift"))
        #expect(totals[.document] == tree.allocated("notes.txt"))

        let blobURL = tree.root.appendingPathComponent("Code/Caches/blob")
        let blob = try #require(index.id(of: blobURL))
        #expect(index.url(of: blob).standardizedFileURL.path == blobURL.standardizedFileURL.path)
        #expect(index.ancestry(of: blob).map(\.name) == [tree.root.lastPathComponent, "Code", "Caches", "blob"])
        #expect(index.id(of: tree.outside) == nil)
    }

    @Test func forgetSubtractsFromAncestors() throws {
        let tree = try Tree()
        let index = DiskIndex.build(root: tree.root)
        let before = try #require(index.node(index.rootID))
        let movies = try #require(index.id(of: tree.root.appendingPathComponent("Movies")))
        let clip = tree.root.appendingPathComponent("Movies/clip.mov")
        index.forget([clip])
        #expect(index.node(index.rootID)?.bytes == before.bytes - tree.allocated("Movies/clip.mov"))
        #expect(index.node(index.rootID)?.fileCount == before.fileCount - 1)
        #expect(index.children(of: movies).map(\.name) == ["old.mov"])
        #expect(index.id(of: clip) == nil)
        #expect(!index.files(matching: FileQuery(), limit: 100).contains { $0.name == "clip.mov" })

        // A whole folder: its files disappear from searches too.
        index.forget([tree.root.appendingPathComponent("Code")])
        #expect(index.node(index.rootID)?.fileCount == before.fileCount - 3)
        #expect(!index.children(of: index.rootID).contains { $0.name == "Code" })
        #expect(!index.files(matching: FileQuery(), limit: 100).contains { $0.name == "main.swift" })
        // Order still follows the new sizes.
        let sizes = index.children(of: index.rootID).map(\.bytes)
        #expect(sizes == sizes.sorted(by: >))
    }

    @Test func filesComeLargestFirst() throws {
        let tree = try Tree()
        let index = DiskIndex.build(root: tree.root)
        let files = index.files(matching: FileQuery(), limit: 3)
        #expect(files.count == 3)
        #expect(files.first?.name == "clip.mov")
        #expect(files.allSatisfy { !$0.isDirectory })
        #expect(files.map(\.bytes) == files.map(\.bytes).sorted(by: >))
    }

    @Test func saveAndLoadRoundTrip() throws {
        let tree = try Tree()
        let index = DiskIndex.build(root: tree.root)
        index.forget([tree.root.appendingPathComponent("notes.txt")])
        let file = tree.root.deletingLastPathComponent().appendingPathComponent("cache/index.bin")
        try index.save(to: file)
        let loaded = try #require(DiskIndex.load(from: file))
        #expect(loaded.root.path == index.root.path)
        #expect(abs(loaded.builtAt.timeIntervalSince(index.builtAt)) < 0.001)
        #expect(loaded.node(loaded.rootID) == index.node(index.rootID))
        #expect(loaded.children(of: loaded.rootID) == index.children(of: index.rootID))
        #expect(loaded.kindTotals(under: loaded.rootID) == index.kindTotals(under: index.rootID))
        let clip = tree.root.appendingPathComponent("Movies/clip.mov")
        #expect(loaded.id(of: clip) == index.id(of: clip))
        #expect(loaded.id(of: tree.root.appendingPathComponent("notes.txt")) == nil)

        // A damaged file is rejected, not trusted.
        var data = try Data(contentsOf: file)
        data.count = data.count / 2
        try data.write(to: file)
        #expect(DiskIndex.load(from: file) == nil)
    }

    @Test func cancelStopsEarly() throws {
        let tree = try Tree()
        let index = DiskIndex.build(root: tree.root, isCancelled: { true })
        #expect(index.node(index.rootID) != nil)
        #expect((index.node(index.rootID)?.fileCount ?? 0) < 8)
    }

    @Test func unreadableRootGivesAnEmptyMap() {
        let index = DiskIndex.build(root: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)"))
        #expect(index.node(index.rootID)?.bytes == 0)
        #expect(index.children(of: index.rootID).isEmpty)
    }
}
