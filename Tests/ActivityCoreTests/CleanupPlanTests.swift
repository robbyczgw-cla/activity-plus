import Foundation
import Testing
@testable import ActivityCore

@Suite("Cleanup plan")
struct CleanupPlanTests {
    static let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)

    static func entry(
        _ path: String, bytes: UInt64 = 100, safety: Safety = .safeToClear, bundleID: String? = nil,
        section: CleanupSection = .caches, id: String? = nil, extra: [String] = []
    ) -> CleanupEntry {
        let urls = ([path] + extra).map { URL(fileURLWithPath: $0) }
        let item = ReclaimableItem(
            id: id ?? "x:" + path, title: (path as NSString).lastPathComponent, location: path,
            urls: urls, bytes: bytes, safety: safety, reason: "r", bundleID: bundleID
        )
        return CleanupEntry(item: item, section: section, ownerName: bundleID)
    }

    @Test func mergeKeepsOuterPath() {
        let outer = Self.entry("/Users/tester/Library/Caches/Foo", bytes: 500)
        let inner = Self.entry("/Users/tester/Library/Caches/Foo/Sub", bytes: 200)
        let other = Self.entry("/Users/tester/Library/Caches/Foobar", bytes: 50)
        let merged = CleanupPlan.merge([inner, outer, other])
        #expect(Set(merged.map(\.id)) == [outer.id, other.id])
    }

    @Test func mergeKeepsFirstOfEqualPaths() {
        let first = Self.entry("/Users/tester/Library/Caches/Foo", id: "a")
        let second = Self.entry("/Users/tester/Library/Caches/Foo/", id: "b")
        let merged = CleanupPlan.merge([first, second])
        #expect(merged.map(\.id) == ["a"])
    }

    @Test func mergeKeepsEntryThatIsOnlyPartlyCovered() {
        let outer = Self.entry("/Users/tester/A", bytes: 500)
        let partly = Self.entry("/Users/tester/A/x", bytes: 10, extra: ["/Users/tester/B"])
        #expect(CleanupPlan.merge([outer, partly]).count == 2)
    }

    @Test func mergeSortsBySectionThenSize() {
        let small = Self.entry("/Users/tester/s", bytes: 1, section: .caches)
        let big = Self.entry("/Users/tester/b", bytes: 9, section: .caches)
        let dev = Self.entry("/Users/tester/d", bytes: 99, section: .developer)
        #expect(CleanupPlan.merge([dev, small, big]).map(\.id) == [big.id, small.id, dev.id])
    }

    @Test func defaultTicksSkipLookFirstAndRunningApps() {
        let safe = Self.entry("/Users/tester/a")
        let look = Self.entry("/Users/tester/b", safety: .lookFirst)
        let running = Self.entry("/Users/tester/c", bundleID: "com.example.App")
        let selection = CleanupPlan.defaultSelection([safe, look, running], running: ["com.example.App"])
        #expect(selection == [safe.id])
        #expect(CleanupPlan.isBlocked(running, running: ["com.example.App"]))
        #expect(CleanupPlan.isBlocked(running, running: ["com.example.App.helper"]))
        #expect(!CleanupPlan.isBlocked(running, running: ["com.example.Application"]))
        #expect(!CleanupPlan.isBlocked(safe, running: ["com.example.App"]))
    }

    @Test func totalsCountOnlyTheGivenIDs() {
        let a = Self.entry("/Users/tester/a", bytes: 10)
        let b = Self.entry("/Users/tester/b", bytes: 20)
        #expect(CleanupPlan.totalBytes([a, b], ids: [b.id]) == 20)
        #expect(CleanupPlan.totalBytes([a, b], ids: []) == 0)
    }

    @Test func groupsMapToSections() {
        #expect(CleanupPlan.section(forGroupID: "logs", title: "Logs") == .logs)
        #expect(CleanupPlan.section(forGroupID: "developer", title: "Entwicklerdaten") == .developer)
        #expect(CleanupPlan.section(forGroupID: "backups", title: "Backups") == .largeOld)
        #expect(CleanupPlan.section(forGroupID: "caches", title: "Logs") == .caches)
    }

    @Test func breakdownDropsMacOSManagedAndContainers() {
        let item = { (id: String, path: String, safety: Safety) in
            ReclaimableItem(id: id, title: id, location: path, urls: [URL(fileURLWithPath: path)], bytes: 5, safety: safety, reason: "r")
        }
        let group = SystemDataBreakdown.Group(id: "caches", title: "Caches", safety: .safeToClear, items: [
            item("ok", "/Users/tester/Library/Caches/Foo", .safeToClear),
            item("look", "/Users/tester/Library/Developer/Xcode/Archives", .lookFirst),
            item("macos", "/private/var/vm", .managedByMacOS),
            item("box", "/Users/tester/Library/Containers/com.x/Data/Library/Caches", .safeToClear),
        ])
        let ids = CleanupPlan.entries(from: [group]).map(\.id)
        #expect(ids == ["sys:ok", "sys:look"])
    }

    @Test func appEntriesUseOnlySafeLocationsAndKeepBundleID() {
        let app = AppDiskUsage(id: "1", name: "Foo", bundlePath: "/Applications/Foo.app", bundleID: "com.example.Foo", lastUsed: nil, locations: [
            StorageLocation(path: "/Applications/Foo.app", kind: .bundle, bytes: 900, isSafeToClean: false),
            StorageLocation(path: "/Users/tester/Library/Caches/com.example.Foo", kind: .caches, bytes: 40, isSafeToClean: true),
            StorageLocation(path: "/Users/tester/Library/Application Support/Foo", kind: .applicationSupport, bytes: 70, isSafeToClean: false),
            StorageLocation(path: "/Users/tester/Library/Containers/com.example.Foo/Data/Library/Caches", kind: .caches, bytes: 5, isSafeToClean: true),
        ])
        let entries = CleanupPlan.entries(fromApps: [app], minimumBytes: 10, home: Self.home)
        #expect(entries.count == 1)
        #expect(entries[0].item.bundleID == "com.example.Foo")
        #expect(entries[0].section == .appCaches)
        #expect(entries[0].item.location == "~/Library/Caches/com.example.Foo")
    }

    @Test func candidatesBecomeLookFirstAndSkipMountedImages() {
        let candidates = [
            CleanupCandidate(url: URL(fileURLWithPath: "/Users/tester/Downloads/a.dmg"), kind: .installer, bytes: 10, lastOpened: nil, modified: nil),
            CleanupCandidate(url: URL(fileURLWithPath: "/Volumes/Disk"), kind: .oldDiskImageMount, bytes: 10, lastOpened: nil, modified: nil),
        ]
        let entries = CleanupPlan.entries(from: candidates, home: Self.home)
        #expect(entries.count == 1)
        #expect(entries[0].item.safety == .lookFirst)
        #expect(entries[0].section == .largeOld)
        #expect(entries[0].item.location == "~/Downloads")
    }

    @Test func trashAllowedOnlyInsideHome() {
        let home = Self.home
        func allowed(_ path: String) -> Bool { CleanupPlan.isTrashAllowed(URL(fileURLWithPath: path), home: home) }
        #expect(allowed("/Users/tester/Library/Caches/Foo"))
        #expect(allowed("/Users/tester/Downloads/big.dmg"))
        #expect(allowed("/Users/tester/stray.mov"))
        #expect(!allowed("/Users/tester"))
        #expect(!allowed("/Users/tester/Documents"))
        #expect(!allowed("/Users/tester/Library"))
        #expect(!allowed("/Users/tester/Library/Containers"))
        #expect(!allowed("/Users/tester/Library/Containers/com.x/Data"))
        #expect(!allowed("/Users/other/Library/Caches/Foo"))
        #expect(!allowed("/Users/testerX/file"))
        #expect(!allowed("/System/Library/Caches"))
        #expect(!allowed("/Applications/Safari.app"))
        #expect(!allowed("/Volumes/Disk"))
        #expect(!allowed("/Users/tester/../other/x"))
        #expect(allowed("/Applications/Install macOS Sequoia.app"))
        #expect(!allowed("/Applications/Install macOS Sequoia.app/Contents"))
        #expect(!allowed("/Applications/Install Something.app"))
    }

    @Test func trashMovesOnlyWhatIsAllowedAndSkipsRunningApps() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("cleanup-test-" + UUID().uuidString, isDirectory: true)
        let home = base.appendingPathComponent("home", isDirectory: true)
        let fakeTrash = base.appendingPathComponent("trash", isDirectory: true)
        try fm.createDirectory(at: home.appendingPathComponent("Library/Caches/A"), withIntermediateDirectories: true)
        try fm.createDirectory(at: home.appendingPathComponent("Library/Caches/B"), withIntermediateDirectories: true)
        try fm.createDirectory(at: fakeTrash, withIntermediateDirectories: true)
        let outside = base.appendingPathComponent("outside.txt")
        try Data("x".utf8).write(to: outside)
        defer { try? fm.removeItem(at: base) }

        let a = Self.entry(home.appendingPathComponent("Library/Caches/A").path, bytes: 30)
        let b = Self.entry(home.appendingPathComponent("Library/Caches/B").path, bytes: 20, bundleID: "com.example.B")
        let out = Self.entry(outside.path, bytes: 5)
        let gone = Self.entry(home.appendingPathComponent("Library/Caches/Gone").path, bytes: 7)

        // The Trash is faked: nothing of the real Trash is touched.
        let outcome = CleanupPlan.trash([a, b, out, gone], home: home, runningBundleIDs: { ["com.example.B"] }) { url in
            try fm.moveItem(at: url, to: fakeTrash.appendingPathComponent(url.lastPathComponent))
        }
        #expect(outcome.movedIDs == [a.id, gone.id])
        #expect(outcome.freed == 37)
        #expect(outcome.skippedRunning == ["com.example.B"])
        #expect(outcome.failures.map(\.title) == ["outside.txt"])
        #expect(fm.fileExists(atPath: outside.path))
        #expect(fm.fileExists(atPath: home.appendingPathComponent("Library/Caches/B").path))
        #expect(!fm.fileExists(atPath: home.appendingPathComponent("Library/Caches/A").path))
        #expect(fm.fileExists(atPath: fakeTrash.appendingPathComponent("A").path))
    }

    @Test func trashReportsMoverFailures() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("cleanup-test-" + UUID().uuidString, isDirectory: true)
        let home = base.appendingPathComponent("home", isDirectory: true)
        try fm.createDirectory(at: home.appendingPathComponent("Library/Caches/A"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        struct Boom: Error {}
        let a = Self.entry(home.appendingPathComponent("Library/Caches/A").path, bytes: 30)
        let outcome = CleanupPlan.trash([a], home: home, runningBundleIDs: { [] }) { _ in throw Boom() }
        #expect(outcome.freed == 0)
        #expect(outcome.movedIDs.isEmpty)
        #expect(outcome.failures.count == 1)
    }

    @Test func duplicateKeepsOwnerOfDroppedEntry() {
        let url = URL(fileURLWithPath: "/Users/x/Library/Caches/Arc")
        let system = CleanupEntry(item: ReclaimableItem(id: "sd:cache:Arc", title: "Arc", location: "~/Library/Caches/Arc", urls: [url],
                                                        bytes: 100, safety: .safeToClear, reason: "r"), section: .caches)
        let app = CleanupEntry(item: ReclaimableItem(id: "app:arc", title: "Arc · Cache", location: "~/Library/Caches/Arc", urls: [url],
                                                     bytes: 100, safety: .safeToClear, reason: "r", bundleID: "company.thebrowser.Browser"),
                               section: .appCaches, ownerName: "Arc")
        let merged = CleanupPlan.merge([system, app])
        #expect(merged.count == 1)
        #expect(merged[0].item.bundleID == "company.thebrowser.Browser")
        #expect(merged[0].ownerName == "Arc")
        #expect(CleanupPlan.isBlocked(merged[0], running: ["company.thebrowser.Browser"]))
    }
}
