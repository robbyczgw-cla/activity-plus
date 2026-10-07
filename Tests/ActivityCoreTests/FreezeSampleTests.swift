import Foundation
import Testing
@testable import ActivityCore

@Suite("Freeze sample")
struct FreezeSampleTests {
    // Shaped like /usr/bin/sample output: the main thread blocks in a synchronous file read.
    static let report = """
    Call graph:
        300 Thread_1   DispatchQueue_1: com.apple.main-thread  (serial)
        + 300 start  (in dyld) + 6688  [0x199b13e80]
        +   300 main  (in Notes) + 40  [0x1041a8000]
        +     300 NSApplicationMain  (in AppKit) + 880  [0x19e52bc4c]
        +       290 -[NoteController save:]  (in Notes) + 120  [0x1052bb87c]
        +       ! 290 -[NSData initWithContentsOfFile:]  (in Foundation) + 64  [0x19a000000]
        +       !   290 read  (in libsystem_kernel.dylib) + 8  [0x199ea0000]
        +       10 -[NSApplication run]  (in AppKit) + 396  [0x19e55390c]
        +         10 mach_msg  (in libsystem_kernel.dylib) + 24  [0x199ea4fac]
        200 Thread_2
        + 200 start_wqthread  (in libsystem_pthread.dylib) + 8  [0x19a1]

    """

    @Test func followsTheBusiestBranchOfTheMainThread() {
        #expect(FreezeSample.mainThreadPath(Self.report) == [
            "-[NoteController save:] (Notes)",
            "-[NSData initWithContentsOfFile:] (Foundation)",
            "read (libsystem_kernel.dylib)",
        ])
    }

    @Test func noMainThreadNoPath() {
        #expect(FreezeSample.mainThreadPath("nothing here").isEmpty)
    }
}
