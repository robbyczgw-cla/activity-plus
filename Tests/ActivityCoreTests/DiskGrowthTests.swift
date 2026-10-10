import Foundation
import Testing
@testable import ActivityCore

@Suite("What grew")
struct DiskGrowthTests {
    private let gb: UInt64 = 1_000_000_000
    private let mb: UInt64 = 1_000_000

    private func summary(_ folders: [String: UInt64], total: UInt64 = 0, at seconds: TimeInterval = 0) -> DiskGrowth.Summary {
        DiskGrowth.Summary(date: Date(timeIntervalSince1970: seconds), root: "/Users/test", totalBytes: total,
                           fileCount: 0, folders: folders, minBytes: 50 * mb)
    }

    @Test func listsBiggestChangesBothWays() {
        let old = summary(["Downloads": 2 * gb, "Library": 30 * gb, "Library/Caches": 8 * gb, "Movies": 10 * gb])
        let new = summary(["Downloads": 16 * gb + 200 * mb, "Library": 27 * gb, "Library/Caches": 4 * gb + 900 * mb, "Movies": 10 * gb])
        let changes = DiskGrowth.changes(from: old, to: new)
        #expect(changes.map(\.path) == ["Downloads", "Library/Caches"])   // Library's −3 GB is Caches' −3.1 GB
        #expect(changes[0].delta == Int64(14 * gb + 200 * mb))
        #expect(changes[0].grew)
        #expect(changes[1].delta == -Int64(3 * gb + 100 * mb))
        #expect(!changes[1].grew)
    }

    @Test func prefersTheSubfolderThatExplainsTheChange() {
        let old = summary(["Downloads": 1 * gb, "Downloads/Holiday": 0 + 60 * mb])
        let new = summary(["Downloads": 15 * gb, "Downloads/Holiday": 13 * gb + 500 * mb])
        let changes = DiskGrowth.changes(from: old, to: new)
        #expect(changes.map(\.path) == ["Downloads/Holiday"])
    }

    @Test func keepsTheParentWhenSeveralSubfoldersShareTheChange() {
        let old = summary(["Library": 10 * gb, "Library/Developer": 5 * gb, "Library/Mail": 5 * gb])
        let new = summary(["Library": 20 * gb, "Library/Developer": 10 * gb, "Library/Mail": 10 * gb])
        #expect(DiskGrowth.changes(from: old, to: new).map(\.path) == ["Library"])
    }

    @Test func oppositeChangesInsideOneFolderGetTheirOwnLines() {
        // Library grew by 2 GB net: Developer +5 GB, Caches −3 GB. The net line adds nothing.
        let old = summary(["Library": 20 * gb, "Library/Developer": 5 * gb, "Library/Caches": 6 * gb])
        let new = summary(["Library": 22 * gb, "Library/Developer": 10 * gb, "Library/Caches": 3 * gb])
        let changes = DiskGrowth.changes(from: old, to: new)
        #expect(changes.map(\.path) == ["Library/Developer", "Library/Caches"])
    }

    @Test func newAndGoneFoldersAndSmallChanges() {
        let old = summary(["Old project": 4 * gb, "Music": 1 * gb])
        let new = summary(["New project": 3 * gb, "Music": 1 * gb + 20 * mb])
        let changes = DiskGrowth.changes(from: old, to: new)
        #expect(changes.map(\.path) == ["Old project", "New project"])   // Music +20 MB is below the minimum
        #expect(changes[0].isGone && changes[0].delta == -Int64(4 * gb))
        #expect(changes[1].isNew && changes[1].name == "New project")
        #expect(DiskGrowth.changes(from: old, to: new, limit: 1).count == 1)
    }

    @Test func ancestorNeedsASlashBoundary() {
        #expect(DiskGrowth.isAncestor("Library", of: "Library/Caches"))
        #expect(!DiskGrowth.isAncestor("Lib", of: "Library/Caches"))
        #expect(!DiskGrowth.isAncestor("Library", of: "Library"))
    }

    @Test func historyKeepsTheNewestInDateOrder() throws {
        var history = DiskGrowth.History()
        for day in [3.0, 1, 2, 5, 4] { history.add(summary([:], at: day * 86_400), keep: 3) }
        #expect(history.summaries.map { $0.date.timeIntervalSince1970 / 86_400 } == [3, 4, 5])
        history.add(summary(["A": gb], at: 5 * 86_400), keep: 3)   // same moment: replaced
        #expect(history.summaries.count == 3)
        #expect(history.summaries.last?.folders["A"] == gb)
        #expect(history.contains(date: Date(timeIntervalSince1970: 4 * 86_400)))

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("growth-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try history.save(to: url)
        #expect(DiskGrowth.History.load(from: url) == history)
        #expect(DiskGrowth.History.load(from: url.appendingPathExtension("missing")).summaries.isEmpty)
    }

    @Test func summarizesFoldersFromTheMap() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("growth-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let fm = FileManager.default
        for folder in ["a/b/c/d/e", "small"] { try fm.createDirectory(at: base.appendingPathComponent(folder), withIntermediateDirectories: true) }
        func write(_ path: String, _ bytes: Int) throws {
            var data = Data(count: bytes)
            data.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, bytes) }
            try data.write(to: base.appendingPathComponent(path))
        }
        try write("a/b/c/d/e/deep.bin", 300_000)
        try write("small/tiny.bin", 10_000)
        let index = DiskIndex.build(root: base)
        let result = DiskGrowth.summarize(index, maxDepth: 4, minBytes: 100_000)
        #expect(Set(result.folders.keys) == ["a", "a/b", "a/b/c", "a/b/c/d"])   // depth 4, "small" below the minimum
        #expect(result.totalBytes == index.node(index.rootID)?.bytes)
        #expect(result.date == index.builtAt)
        #expect(result.folders["a/b/c/d"] == result.folders["a"])   // everything in "a" is the one deep file
    }
}
