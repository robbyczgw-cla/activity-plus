import Foundation
import Testing
@testable import ActivityCore

@Suite("SSD wear")
struct SSDWearTests {
    @Test func extrapolatesFromTheWearCounter() throws {
        // 2 % used after 40 TB: 20 TB per percent, 98 % left = 1960 TB; at 100 GB a day that is 19,600 days.
        let p = try #require(SSDWear.projection(percentUsed: 2, dataWrittenTB: 40, bytesPerDay: 100e9))
        #expect(p.bytesPerPercent == 20e12)
        #expect(abs(p.yearsLeft - 19_600.0 / 365) < 0.001)
    }

    @Test func nothingToExtrapolateYet() {
        #expect(SSDWear.projection(percentUsed: 0, dataWrittenTB: 5, bytesPerDay: 1e9) == nil)
        #expect(SSDWear.projection(percentUsed: 3, dataWrittenTB: nil, bytesPerDay: 1e9) == nil)
        #expect(SSDWear.projection(percentUsed: 3, dataWrittenTB: 9, bytesPerDay: 0) == nil)
    }

    @Test func writesPerAppAreKeptApartFromReads() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("writes-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = HistoryStore(url: url)
        var s = SystemSnapshot(); s.interval = 10
        var app = AppGroup(id: "com.example.writer", name: "Writer", kind: .app, bundlePath: nil, bundleID: nil, mainPID: nil, processes: [])
        app.diskWriteRate = 1_000_000; app.diskReadRate = 5_000_000
        s.apps = [app]
        store.record(s); store.flush()
        let writers = store.topWriters(since: Date().addingTimeInterval(-3600))
        #expect(writers.apps.first?.bytes == 10_000_000)
        #expect(writers.countingSince != nil)
    }
}
