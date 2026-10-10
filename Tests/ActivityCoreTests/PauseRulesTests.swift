import Testing
@testable import ActivityCore

@Suite("Pause rules")
struct PauseRulesTests {
    static func block(pid: Int32 = 4_242, uid: UInt32 = 501, name: String = "node") -> PauseRules.Block? {
        PauseRules.block(pid: pid, uid: uid, name: name, myPID: 9_999, myUID: 501)
    }

    @Test func ownProcessMayBePaused() {
        #expect(Self.block() == nil)
    }

    @Test func refusesItself() {
        #expect(PauseRules.block(pid: 9_999, uid: 501, name: "node", myPID: 9_999, myUID: 501) == .itself)
    }

    @Test func refusesLaunchdAndRoot() {
        #expect(Self.block(pid: 1, uid: 501, name: "launchd") == .systemProcess)
        #expect(Self.block(pid: 300, uid: 0, name: "kernel_task") == .systemProcess)
    }

    @Test func refusesOtherUsers() {
        #expect(Self.block(uid: 88, name: "_windowserver") == .otherUser)
    }

    @Test func refusesDesktopProcesses() {
        for name in ["WindowServer", "loginwindow", "Dock", "Finder", "Activity+"] {
            #expect(Self.block(name: name) == .desktop)
        }
    }
}
