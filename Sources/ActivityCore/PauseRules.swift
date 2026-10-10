import Foundation

/// Which processes Activity+ refuses to pause (SIGSTOP). Pure rules, so they can be tested.
public enum PauseRules {
    public enum Block: Sendable, Equatable {
        case itself
        case systemProcess
        case otherUser
        case desktop
    }

    /// Processes that keep the desktop usable; pausing them freezes the screen.
    public static let desktopNames: Set<String> = [
        "WindowServer", "loginwindow", "Dock", "Finder", "ActivityPlus", "Activity+",
    ]

    /// Nil when the process may be paused. Only the user's own processes qualify.
    public static func block(pid: Int32, uid: UInt32, name: String, myPID: Int32, myUID: UInt32) -> Block? {
        if pid == myPID { return .itself }
        if pid <= 1 || uid == 0 { return .systemProcess }
        if uid != myUID { return .otherUser }
        if desktopNames.contains(name) { return .desktop }
        return nil
    }
}
