import Foundation

/// The privileged helper's whole interface. It only reads per-process counters that macOS hides
/// from normal apps for processes of other users (root, _windowserver…). It cannot quit, change
/// or write anything.
@objc public protocol ActivityPlusHelperProtocol {
    /// Encoded `[HelperProcessUsage]` for the given pids (unknown or vanished pids are skipped).
    func usage(for pids: [NSNumber], reply: @escaping (Data) -> Void)
    func version(reply: @escaping (String) -> Void)
}

public enum HelperConstants {
    public static let machService = "at.hifiteam.activityplus.helper"
    public static let plistName = "at.hifiteam.activityplus.helper.plist"
    public static let version = "1"
    /// Only Activity+ signed by this team may connect.
    public static let clientRequirement =
        #"anchor apple generic and identifier "at.hifiteam.activityplus" and certificate leaf[subject.OU] = "P35939S43T""#
}

/// What the helper returns per process; the same counters proc_pid_rusage gives for own processes.
public struct HelperProcessUsage: Codable, Sendable {
    public let pid: Int32
    public let startSeconds: Int64
    public let startMicroseconds: Int64
    public let footprint: UInt64
    public let cpuTicks: UInt64          // user + system, mach ticks
    public let diskRead: UInt64
    public let diskWritten: UInt64
    public let energyNJ: UInt64
    public let path: String?

    public init(pid: Int32, startSeconds: Int64, startMicroseconds: Int64, footprint: UInt64, cpuTicks: UInt64,
                diskRead: UInt64, diskWritten: UInt64, energyNJ: UInt64, path: String?) {
        self.pid = pid; self.startSeconds = startSeconds; self.startMicroseconds = startMicroseconds
        self.footprint = footprint; self.cpuTicks = cpuTicks; self.diskRead = diskRead
        self.diskWritten = diskWritten; self.energyNJ = energyNJ; self.path = path
    }
}
