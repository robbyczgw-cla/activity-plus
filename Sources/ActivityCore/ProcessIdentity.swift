import Darwin
import Foundation

/// Guards against pid reuse before sending a signal.
public enum ProcessIdentity {
    /// True if `pid` still belongs to the process that started at `startTime`.
    /// Processes we cannot inspect (other users) cannot be signalled by us anyway, so they pass.
    public static func isSame(pid: pid_t, startTime: Date, hasDetails: Bool = true) -> Bool {
        guard hasDetails else { return true }
        guard let info = ProcessSampler.bsdInfo(pid) else { return false }
        let start = Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1_000_000)
        return abs(start.timeIntervalSince(startTime)) < 0.001
    }
}
