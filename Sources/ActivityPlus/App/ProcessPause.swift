import ActivityCore
import Darwin

/// Pausing (SIGSTOP) and resuming (SIGCONT) the user's own processes. Callers confirm a pause first.
enum ProcessPause {
    /// Why this process cannot be paused, nil when it can.
    static func block(_ process: ProcessSample) -> PauseRules.Block? {
        PauseRules.block(pid: process.pid, uid: process.uid, name: process.name, myPID: getpid(), myUID: getuid())
    }

    @discardableResult
    static func pause(_ process: ProcessSample) -> Bool {
        guard block(process) == nil, isSame(process) else { return false }
        return kill(process.pid, SIGSTOP) == 0
    }

    @discardableResult
    static func resume(_ process: ProcessSample) -> Bool {
        guard process.uid == getuid(), isSame(process) else { return false }
        return kill(process.pid, SIGCONT) == 0
    }

    /// Only signals the process the user saw: pids get reused while a dialog is open.
    private static func isSame(_ process: ProcessSample) -> Bool {
        process.pid > 1 && process.pid != getpid()
            && ProcessIdentity.isSame(pid: process.pid, startTime: process.startTime, hasDetails: process.hasDetails)
    }
}
