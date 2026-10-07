import Foundation

/// How long an SSD lasts at the current pace, from its own wear counter (NVMe "percentage used",
/// 100 = rated endurance reached) and the data written so far.
public enum SSDWear {
    public struct Projection: Sendable, Equatable {
        /// Years until the drive reaches its rated endurance at this pace.
        public let yearsLeft: Double
        public let bytesPerPercent: Double
    }

    /// Nil while the drive reports 0 % used: there is nothing to extrapolate from yet.
    public static func projection(percentUsed: Int?, dataWrittenTB: Double?, bytesPerDay: Double) -> Projection? {
        guard let used = percentUsed, used > 0, used < 100, let written = dataWrittenTB, written > 0, bytesPerDay > 0 else { return nil }
        let bytesPerPercent = written * 1e12 / Double(used)
        let remaining = Double(100 - used) * bytesPerPercent
        return Projection(yearsLeft: remaining / bytesPerDay / 365, bytesPerPercent: bytesPerPercent)
    }
}
