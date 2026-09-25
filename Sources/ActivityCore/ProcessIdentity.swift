import Darwin
import Foundation

/// Guards against pid reuse before sending a signal.
public enum ProcessIdentity {
    /// True if `pid` still belongs to the process that started at `startTime`.
    /// A process we could not inspect when it was sampled (another user's) passes only while we still
    /// cannot inspect that pid: signalling it fails anyway. If the pid has become inspectable, it now
    /// belongs to a different process of ours, so it fails closed.
    public static func isSame(pid: pid_t, startTime: Date, hasDetails: Bool = true) -> Bool {
        guard hasDetails else { return ProcessSampler.bsdInfo(pid) == nil && kill(pid, 0) == -1 && errno == EPERM }
        guard let info = ProcessSampler.bsdInfo(pid) else { return false }
        let start = Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1_000_000)
        return abs(start.timeIntervalSince(startTime)) < 0.001
    }
}
