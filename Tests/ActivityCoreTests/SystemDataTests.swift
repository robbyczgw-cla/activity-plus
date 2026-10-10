import Foundation
import Testing
@testable import ActivityCore

@Suite("System Data")
struct SystemDataTests {
    /// A fake home folder, /Applications and /private/var/vm in a temp folder.
    final class Sandbox {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sd-\(UUID().uuidString)")
        var home: URL { root.appendingPathComponent("home") }
        var apps: URL { root.appendingPathComponent("Applications") }
        var vm: URL { root.appendingPathComponent("vm") }
        var places: SystemDataBreakdown.Places {
            .init(home: home, applications: apps, systemLibrary: root.appendingPathComponent("SysLib"), vm: vm)
        }
        init() {
            for url in [home, apps, vm] { try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        }
        deinit { try? FileManager.default.removeItem(at: root) }

        @discardableResult
        func file(_ path: String, megabytes: Double, under base: URL? = nil) -> URL {
            let url = (base ?? home).appendingPathComponent(path)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Non-zero bytes in every block: allocated size must not depend on sparse-file tricks.
            let count = Int(megabytes * 1_000_000)
            try? Data(repeating: 0xAB, count: count).write(to: url)
            return url
        }

        func measure(hidden: HiddenSpace.Summary? = nil, names: [String: String] = [:]) -> [SystemDataBreakdown.Group] {
            SystemDataBreakdown.measure(places: places, hidden: hidden.map { s in { s } },
                                        resolveName: { names[$0] }, isCancelled: { false }, progress: { _, _ in })
        }
    }

    static func group(_ groups: [SystemDataBreakdown.Group], _ id: String) -> SystemDataBreakdown.Group? { groups.first { $0.id == id } }

    @Test func allocatedSizeCountsFilesAndSkipsSymlinks() throws {
        let box = Sandbox()
        box.file("tree/a.bin", megabytes: 2)
        box.file("tree/sub/b.bin", megabytes: 3)
        let outside = box.file("outside/big.bin", megabytes: 20)
        try FileManager.default.createSymbolicLink(at: box.home.appendingPathComponent("tree/link"), withDestinationURL: outside)
        let bytes = try #require(SystemDataBreakdown.allocatedSize(atPath: box.home.appendingPathComponent("tree").path))
        #expect(bytes >= 5_000_000 && bytes < 6_000_000)
        #expect(SystemDataBreakdown.allocatedSize(atPath: box.home.appendingPathComponent("missing").path) == nil)
    }

    @Test func hardLinksCountOnce() throws {
        let box = Sandbox()
        let original = box.file("tree/a.bin", megabytes: 4)
        try FileManager.default.linkItem(at: original, to: box.home.appendingPathComponent("tree/b.bin"))
        let bytes = try #require(SystemDataBreakdown.allocatedSize(atPath: box.home.appendingPathComponent("tree").path))
        #expect(bytes < 5_000_000)
    }

    @Test func cancelledWalkReturnsNil() {
        let box = Sandbox()
        for i in 0..<600 { box.file("tree/f\(i).bin", megabytes: 0.001) }
        #expect(SystemDataBreakdown.allocatedSize(atPath: box.home.appendingPathComponent("tree").path, isCancelled: { true }) == nil)
    }

    @Test func cachesSplitByThresholdAndNameBundles() throws {
        let box = Sandbox()
        box.file("Library/Caches/com.example.Big/data.bin", megabytes: 60)
        box.file("Library/Caches/com.example.Small/data.bin", megabytes: 5)
        box.file("Library/Caches/Tiny/data.bin", megabytes: 1)
        let groups = box.measure(names: ["com.example.Big": "Example"])
        let caches = try #require(Self.group(groups, "caches"))
        #expect(caches.safety == .safeToClear)
        let big = try #require(caches.items.first { $0.id == "sd:cache:com.example.Big" })
        #expect(big.title.contains("Example"))
        #expect(big.bundleID == "com.example.Big")
        let other = try #require(caches.items.first { $0.id == "sd:cache:other" })
        #expect(other.urls.count == 2)
        #expect(other.bytes >= 6_000_000 && other.bytes < 7_000_000)
        #expect(!caches.items.contains { $0.id.hasSuffix("Small") })
    }

    @Test func homebrewIsListedOnceNotAlsoInOtherCaches() throws {
        let box = Sandbox()
        box.file("Library/Caches/Homebrew/bottle.tar.gz", megabytes: 80)
        box.file("Library/Caches/ms-playwright/chromium.zip", megabytes: 70)
        box.file(".npm/_cacache/blob", megabytes: 10)
        box.file(".cache/uv/wheel", megabytes: 55)
        box.file(".cache/other-tool/blob", megabytes: 60)
        let caches = try #require(Self.group(box.measure(), "caches"))
        let total = caches.items.reduce(UInt64(0)) { $0 + $1.bytes }
        #expect(caches.items.filter { $0.id == "sd:cache:homebrew" }.count == 1)
        #expect(caches.items.first { $0.id == "sd:cache:homebrew" }?.title == "Homebrew downloads")
        #expect(caches.items.contains { $0.id == "sd:cache:playwright" })
        #expect(caches.items.contains { $0.id == "sd:cache:npm" })
        #expect(caches.items.contains { $0.id == "sd:cache:uv" })
        #expect(caches.items.contains { $0.id == "sd:dotcache:other-tool" })
        // 80 + 70 + 10 + 55 + 60 MB, nothing twice.
        #expect(total >= 275_000_000 && total < 285_000_000)
        #expect(caches.items.first?.bytes == caches.items.map(\.bytes).max())
        let paths = caches.items.flatMap(\.urls).map(\.path)
        #expect(Set(paths).count == paths.count)
    }

    @Test func logsExcludeDiagnosticReportsFromAppLogs() throws {
        let box = Sandbox()
        box.file("Library/Logs/app.log", megabytes: 3)
        box.file("Library/Logs/DiagnosticReports/crash.ips", megabytes: 2)
        let logs = try #require(Self.group(box.measure(), "logs"))
        let app = try #require(logs.items.first { $0.id == "sd:logs:app" })
        let reports = try #require(logs.items.first { $0.id == "sd:logs:diagnostics" })
        #expect(app.bytes < 4_000_000 && app.bytes >= 3_000_000)
        #expect(reports.bytes >= 2_000_000 && reports.bytes < 3_000_000)
        #expect(logs.bytes >= 5_000_000 && logs.bytes < 6_000_000)
    }

    @Test func developerDataIsLookFirstAndMissingFoldersAreSkipped() throws {
        let box = Sandbox()
        box.file("Library/Developer/Xcode/DerivedData/Build/out.o", megabytes: 8)
        box.file("Library/Developer/CoreSimulator/Devices/ABC/data.bin", megabytes: 6)
        let developer = try #require(Self.group(box.measure(), "developer"))
        #expect(developer.safety == .lookFirst)
        #expect(developer.items.map(\.id) == ["sd:dev:derived-data", "sd:dev:simulator-devices"])
        #expect(developer.items.allSatisfy { $0.safety == .lookFirst && !$0.reason.isEmpty })
        #expect(developer.items[0].location == "~/Library/Developer/Xcode/DerivedData")
    }

    @Test func backupsAndInstallers() throws {
        let box = Sandbox()
        let backup = "Library/Application Support/MobileSync/Backup/00008110-ABC"
        box.file(backup + "/Manifest.db", megabytes: 9)
        let plist: [String: Any] = ["Device Name": "Robert's iPhone", "Last Backup Date": Date(timeIntervalSince1970: 1_700_000_000)]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: box.home.appendingPathComponent(backup + "/Info.plist"))
        box.file("Install macOS Tahoe.app/Contents/SharedSupport/Install.dmg", megabytes: 12, under: box.apps)
        box.file("Other.app/Contents/x", megabytes: 12, under: box.apps)
        let group = try #require(Self.group(box.measure(), "backups"))
        #expect(group.safety == .lookFirst)
        #expect(group.items.count == 2)
        #expect(group.items.contains { $0.title.contains("Robert's iPhone") })
        #expect(group.items.contains { $0.title == "Install macOS Tahoe" })
    }

    @Test func managedByMacOSNeverHasURLs() throws {
        let box = Sandbox()
        box.file("sleepimage", megabytes: 7, under: box.vm)
        box.file("swapfile0", megabytes: 3, under: box.vm)
        box.file("swapfile1", megabytes: 3, under: box.vm)
        let summary = HiddenSpace.Summary(
            snapshots: HiddenSpace.snapshots(parse: "Name: com.apple.TimeMachine.2026-10-07-123456.local\nPurgeable: Yes\n"),
            purgeableBytes: 5_000_000_000)
        let managed = try #require(Self.group(box.measure(hidden: summary), "macos"))
        #expect(managed.safety == .managedByMacOS)
        #expect(managed.items.allSatisfy { $0.urls.isEmpty && $0.safety == .managedByMacOS })
        #expect(managed.items.first { $0.id == "sd:macos:swap" }.map { $0.bytes >= 6_000_000 } == true)
        #expect(managed.items.contains { $0.id == "sd:macos:sleepimage" })
        #expect(managed.items.contains { $0.id == "sd:macos:snapshots" })
        // Purgeable overlaps with caches and snapshots, so it stays out of the distinct total.
        #expect(managed.bytes > managed.distinctBytes)
        #expect(managed.distinctBytes < 14_000_000)
    }

    @Test func emptyGroupsAreLeftOut() {
        let box = Sandbox()
        #expect(box.measure().isEmpty)
    }

    @Test func overlapGuardKeepsTheFirstClaim() {
        func item(_ id: String, _ path: String) -> ReclaimableItem {
            ReclaimableItem(id: id, title: id, location: path, urls: [URL(fileURLWithPath: path)], bytes: 1, safety: .safeToClear, reason: "r")
        }
        let kept = SystemDataBreakdown.removingOverlaps([
            item("brew", "/h/Library/Caches/Homebrew"),
            item("all", "/h/Library/Caches"),
            item("sibling", "/h/Library/Caches/Other"),
            item("inside", "/h/Library/Caches/Homebrew/downloads"),
        ])
        #expect(kept.map(\.id) == ["brew", "sibling"])
    }

    @Test func bundleIDDetection() {
        #expect(SystemDataBreakdown.Plan.looksLikeBundleID("com.apple.Safari"))
        #expect(!SystemDataBreakdown.Plan.looksLikeBundleID("Homebrew"))
        #expect(!SystemDataBreakdown.Plan.looksLikeBundleID("Google Chrome.app"))
    }
}
