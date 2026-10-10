import Foundation
import Testing
@testable import ActivityCore

@Suite("Duplicates")
struct DuplicateFinderTests {
    /// A temp folder with:
    ///   photos/a.jpg, backup/a copy.jpg, old/a.jpg  same 300 kB (random) contents
    ///   same-size-diff-middle.bin x2               same size, same first and last 64 kB, different middle
    ///   same-size-diff-end.bin x2                  same size, different last bytes
    ///   small/x.dat + y.dat                        identical, 100 kB (first+last 64 kB cover the whole file)
    ///   hard.bin + hard-link.bin                   one file, two hard links: not duplicates
    ///   App.app/Contents/blob + loose blob         identical, but one is inside a package
    ///   .hidden/blob                               identical, but in a hidden folder
    ///   tiny1/tiny2                                identical but below the minimum size
    final class Tree {
        let root: URL
        let photo: Data
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("dupes-\(UUID().uuidString)")
            let fm = FileManager.default
            for folder in ["photos", "backup", "old", "small", "App.app/Contents", ".hidden", "mixed"] {
                try fm.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
            }
            photo = Self.random(300_000)
            try write(photo, "photos/a.jpg")
            try write(photo, "backup/a copy.jpg")
            try write(photo, "old/a.jpg")

            var middle1 = Self.random(400_000)
            var middle2 = middle1
            middle1[200_000] ^= 0xff
            middle2[200_001] ^= 0x0f
            try write(middle1, "mixed/same-size-diff-middle-1.bin")
            try write(middle2, "mixed/same-size-diff-middle-2.bin")

            let end1 = Self.random(250_000)
            var end2 = end1
            end2[end2.count - 1] ^= 0xff
            try write(end1, "mixed/same-size-diff-end-1.bin")
            try write(end2, "mixed/same-size-diff-end-2.bin")

            let small = Self.random(100_000)
            try write(small, "small/x.dat")
            try write(small, "small/y.dat")

            try write(Self.random(200_000), "hard.bin")
            try fm.linkItem(at: root.appendingPathComponent("hard.bin"), to: root.appendingPathComponent("hard-link.bin"))

            let blob = Self.random(150_000)
            try write(blob, "App.app/Contents/blob")
            try write(blob, "blob")
            try write(blob, ".hidden/blob")

            let tiny = Self.random(5_000)
            try write(tiny, "tiny1")
            try write(tiny, "tiny2")

            // Make the newest copy predictable: backup is newest, old is oldest.
            try setModified("old/a.jpg", Date(timeIntervalSinceNow: -3000))
            try setModified("photos/a.jpg", Date(timeIntervalSinceNow: -2000))
            try setModified("backup/a copy.jpg", Date(timeIntervalSinceNow: -1000))
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        static func random(_ count: Int) -> Data {
            var data = Data(count: count)
            data.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, count) }
            return data
        }

        func write(_ data: Data, _ path: String) throws { try data.write(to: root.appendingPathComponent(path)) }
        func path(_ relative: String) -> String { root.appendingPathComponent(relative).standardizedFileURL.path }
        func setModified(_ relative: String, _ date: Date) throws {
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path(relative))
        }
    }

    @Test func findsIdenticalFilesOnly() throws {
        let tree = try Tree()
        let index = DiskIndex.build(root: tree.root)
        let candidates = DuplicateFinder.candidates(in: index, under: index.rootID, minBytes: 50_000)
        #expect(!candidates.contains(tree.path("App.app/Contents/blob")))   // package insides
        #expect(!candidates.contains(tree.path(".hidden/blob")))            // hidden folder
        #expect(!candidates.contains(tree.path("tiny1")))                   // below the minimum
        #expect(candidates.contains(tree.path("blob")))

        let groups = DuplicateFinder.find(paths: candidates, minBytes: 50_000)
        let sets = groups.map { Set($0.files.map(\.path)) }
        #expect(groups.count == 2)
        #expect(sets.contains([tree.path("photos/a.jpg"), tree.path("backup/a copy.jpg"), tree.path("old/a.jpg")]))
        #expect(sets.contains([tree.path("small/x.dat"), tree.path("small/y.dat")]))

        let photos = try #require(groups.first)   // most wasted space first
        #expect(photos.copies == 3)
        #expect(photos.size == UInt64(tree.photo.count))
        #expect(photos.wasted == 2 * UInt64(tree.photo.count))
        #expect(photos.keep.path == tree.path("backup/a copy.jpg"))   // newest
        #expect(photos.files.last?.path == tree.path("old/a.jpg"))
    }

    @Test func hardLinksAndSettingsCount() throws {
        let tree = try Tree()
        // Both names of the hard link given directly: one inode, so no group.
        let linked = DuplicateFinder.find(paths: [tree.path("hard.bin"), tree.path("hard-link.bin")], minBytes: 1)
        #expect(linked.isEmpty)
        // A higher minimum leaves only the 300 kB photos.
        let index = DiskIndex.build(root: tree.root)
        let big = DuplicateFinder.find(paths: DuplicateFinder.candidates(in: index, under: index.rootID, minBytes: 280_000), minBytes: 280_000)
        #expect(big.count == 1 && big[0].copies == 3)
    }

    @Test func cancelStopsWithNothing() throws {
        let tree = try Tree()
        let index = DiskIndex.build(root: tree.root)
        let groups = DuplicateFinder.find(paths: DuplicateFinder.candidates(in: index, under: index.rootID, minBytes: 1), minBytes: 1,
                                          isCancelled: { true })
        #expect(groups.isEmpty)
    }

    @Test func reportsProgressThroughThePhases() throws {
        let tree = try Tree()
        let index = DiskIndex.build(root: tree.root)
        final class Box: @unchecked Sendable { let lock = NSLock(); var phases: [DuplicateFinder.Phase] = [] }
        let box = Box()
        _ = DuplicateFinder.find(paths: DuplicateFinder.candidates(in: index, under: index.rootID, minBytes: 1), minBytes: 1) { progress in
            box.lock.lock(); defer { box.lock.unlock() }
            if box.phases.last != progress.phase { box.phases.append(progress.phase) }
            #expect(progress.fraction >= 0 && progress.fraction <= 1)
        }
        #expect(box.phases == [.sizes, .partial, .full])
    }

    @Test func neverRemovesTheLastCopy() throws {
        let a = DuplicateFinder.File(path: "/x/a", size: 10, modified: Date(timeIntervalSince1970: 2))
        let b = DuplicateFinder.File(path: "/x/b", size: 10, modified: Date(timeIntervalSince1970: 1))
        let group = DuplicateFinder.Group(id: "g", size: 10, files: [a, b])
        #expect(DuplicateFinder.removable(["/x/b"], in: group) == ["/x/b"])
        #expect(DuplicateFinder.removable(["/x/a", "/x/b"], in: group) == ["/x/b"])   // all ticked: the kept copy stays
        #expect(DuplicateFinder.removable(["/x/a"], in: group) == ["/x/a"])           // keeping b instead is fine
        #expect(DuplicateFinder.removable(["/elsewhere"], in: group).isEmpty)
    }

    @Test func stillSafeChecksTheFilesAgain() throws {
        let tree = try Tree()
        let index = DiskIndex.build(root: tree.root)
        let groups = DuplicateFinder.find(paths: DuplicateFinder.candidates(in: index, under: index.rootID, minBytes: 50_000), minBytes: 50_000)
        let photos = try #require(groups.first { $0.copies == 3 })
        let extra = photos.files.dropFirst().map(\.path)
        #expect(Set(DuplicateFinder.stillSafe(extra, in: photos)) == Set(extra))

        // The kept copy changed since the search: one other unchanged copy still stays, so only one may go.
        try Data("changed".utf8).write(to: URL(fileURLWithPath: photos.keep.path))
        let afterChange = DuplicateFinder.stillSafe(extra, in: photos)
        #expect(afterChange.isEmpty)   // both remaining unchanged copies were to go; nothing unchanged would stay
        #expect(DuplicateFinder.stillSafe([extra[0]], in: photos) == [extra[0]])

        // A copy that is gone is never removed and does not count as staying.
        try FileManager.default.removeItem(atPath: extra[1])
        #expect(DuplicateFinder.stillSafe([extra[0]], in: photos).isEmpty)
    }
}
