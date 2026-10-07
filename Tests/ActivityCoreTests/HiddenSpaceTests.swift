import Foundation
import Testing
@testable import ActivityCore

@Suite("Hidden space")
struct HiddenSpaceTests {
    static let listing = """
    Snapshots for disk3s3s1 (3 found)
    |
    +-- 0CB5ACBF-1477-4AF7-B59A-91ADD6D2C6AD
    |   Name:        com.apple.os.update-5203530F8BB2
    |   XID:         3661898
    |   Purgeable:   No
    |
    +-- B3B9E4BD-6235-4915-A953-A72694CAF754
    |   Name:        com.apple.TimeMachine.2026-10-07-123456.local
    |   XID:         4240875
    |   Purgeable:   Yes
    |
    +-- C1
        Name:        com.apple.os.update-MSUPrepareUpdate
        XID:         4240999
        Purgeable:   No
    """

    @Test func readsNamesKindsAndPurgeable() throws {
        let snapshots = HiddenSpace.snapshots(parse: Self.listing)
        #expect(snapshots.count == 3)
        #expect(snapshots.map(\.kind) == [.macOSUpdate, .timeMachine, .macOSUpdate])
        #expect(snapshots.map(\.purgeable) == [false, true, false])
        let date = try #require(snapshots[1].date)
        #expect(Calendar.current.component(.hour, from: date) == 12)
    }

    @Test func noSnapshots() {
        #expect(HiddenSpace.snapshots(parse: "No snapshots for disk3s1").isEmpty)
    }
}
