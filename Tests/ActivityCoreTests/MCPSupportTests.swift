import Foundation
import Testing
@testable import ActivityCore

@Suite("MCP support")
struct MCPSupportTests {
    private func summary(_ day: Int, total: UInt64 = 100) -> DiskGrowth.Summary {
        DiskGrowth.Summary(date: Date(timeIntervalSince1970: Double(day) * 86_400), root: "/r", totalBytes: total, fileCount: 1, folders: [:], minBytes: 50_000_000)
    }

    @Test func growthPairNeedsTwoScans() {
        #expect(DiskGrowth.pair(in: []) == nil)
        #expect(DiskGrowth.pair(in: [summary(1)]) == nil)
    }

    @Test func growthPairDefaultsToPreviousScan() {
        let pair = DiskGrowth.pair(in: [summary(3), summary(1), summary(2)])
        #expect(pair?.old.date == summary(2).date)
        #expect(pair?.new.date == summary(3).date)
    }

    @Test func growthPairWithDatePicksLatestAtOrBefore() {
        let all = [summary(1), summary(5), summary(9), summary(12)]
        #expect(DiskGrowth.pair(in: all, comparedTo: summary(6).date)?.old.date == summary(5).date)
        #expect(DiskGrowth.pair(in: all, comparedTo: summary(9).date)?.old.date == summary(9).date)
        // Older than every scan: the oldest one. A date after the newest scan never compares the newest with itself.
        #expect(DiskGrowth.pair(in: all, comparedTo: summary(0).date)?.old.date == summary(1).date)
        #expect(DiskGrowth.pair(in: all, comparedTo: summary(99).date)?.old.date == summary(9).date)
    }

    @Test func cacheNamesMatchTheApp() {
        let folder = URL(fileURLWithPath: "/tmp/caches", isDirectory: true)
        let home = DiskIndexCache.home(in: folder)
        #expect(home.cacheURL.lastPathComponent == "diskindex.bin")
        #expect(home.growthURL.lastPathComponent == "growth.json")
        let startup = DiskIndexCache.startupDisk(in: folder)
        #expect(startup.cacheURL.lastPathComponent == "diskindex-\(DiskIndexCache.stableHash("/")).bin")
        // The UUID tells two drives with the same name apart.
        let a = DiskIndexCache.volume(path: "/Volumes/Untitled", uuid: "A", in: folder)
        let b = DiskIndexCache.volume(path: "/Volumes/Untitled", uuid: "B", in: folder)
        #expect(a.cacheURL != b.cacheURL)
        #expect(a.growthURL.lastPathComponent.hasPrefix("growth-"))
    }

    @Test func stableHashIsFNV1a() {
        // FNV-1a 64: the empty string gives the offset basis; "a" is a published test vector.
        #expect(DiskIndexCache.stableHash("") == "cbf29ce484222325")
        #expect(DiskIndexCache.stableHash("a") == "af63dc4c8601ec8c")
    }

    @Test func cameraGuessNeedsExactlyOneKnownApp() {
        let zoom = PrivacyReader.Client(name: "zoom", bundleID: "us.zoom.xos", pid: 1)
        let safari = PrivacyReader.Client(name: "Safari", bundleID: "com.apple.Safari", pid: 2)
        let other = PrivacyReader.Client(name: "Notes", bundleID: "com.apple.Notes", pid: 3)
        #expect(PrivacyReader.pickCameraCandidate([zoom, other]).map(\.name) == ["zoom"])
        #expect(PrivacyReader.pickCameraCandidate([zoom, safari, other]).isEmpty)
        #expect(PrivacyReader.pickCameraCandidate([other]).isEmpty)
        #expect(PrivacyReader.pickCameraCandidate([]).isEmpty)
        // Microphone users are the guess when there are any.
        #expect(PrivacyReader.cameraCandidates(microphoneUsers: [other]).map(\.name) == ["Notes"])
    }
}
