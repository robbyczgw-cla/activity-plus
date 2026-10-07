import Foundation
import IOKit

/// Accumulated GPU time per Metal client, straight from the graphics driver's registry entries.
/// WindowServer composes every window, so apps that draw through Core Animation show up there
/// instead of under their own name; `GPUCauseAnalysis` turns hide-and-measure runs into a ranking.
public enum GPUClientTime {
    public struct Client: Sendable {
        public let pid: pid_t
        public let name: String
        public let nanoseconds: UInt64
    }

    public static func snapshot() -> [pid_t: Client] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS
        else { return [:] }
        defer { IOObjectRelease(iterator) }

        var result: [pid_t: Client] = [:]
        var accelerator = IOIteratorNext(iterator)
        while accelerator != 0 {
            var children: io_iterator_t = 0
            if IORegistryEntryCreateIterator(accelerator, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &children) == KERN_SUCCESS {
                var child = IOIteratorNext(children)
                while child != 0 {
                    if let creator = IOKitProperty(child, "IOUserClientCreator") as? String,
                       let usage = IOKitProperty(child, "AppUsage") as? [[String: Any]],
                       let pid = GPUSampler.pid(fromCreator: creator)
                    {
                        let time = usage.reduce(UInt64(0)) { $0 + (($1["accumulatedGPUTime"] as? NSNumber)?.uint64Value ?? 0) }
                        let name = creator.split(separator: ",", maxSplits: 1).dropFirst().first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
                        let previous = result[pid]?.nanoseconds ?? 0
                        result[pid] = Client(pid: pid, name: name, nanoseconds: previous + time)
                    }
                    IOObjectRelease(child)
                    child = IOIteratorNext(children)
                }
                IOObjectRelease(children)
            }
            IOObjectRelease(accelerator)
            accelerator = IOIteratorNext(iterator)
        }
        return result
    }

    /// GPU busy percent of one client between two snapshots.
    public static func percent(pid: pid_t, from a: [pid_t: Client], to b: [pid_t: Client], seconds: Double) -> Double {
        guard seconds > 0, let end = b[pid]?.nanoseconds else { return 0 }
        let start = a[pid]?.nanoseconds ?? 0
        guard end > start else { return 0 }
        return min(100, Double(end - start) / (seconds * 1e9) * 100)
    }
}

/// Ranks apps by how much WindowServer's GPU time drops while each one is hidden.
public struct GPUCauseAnalysis: Equatable, Sendable {
    public struct Cause: Equatable, Sendable, Identifiable {
        public var id: String { bundleID ?? name }
        public let name: String
        public let bundleID: String?
        /// WindowServer GPU percent while this app was hidden.
        public let hiddenPercent: Double
        /// Baseline minus hidden, in percentage points; never negative.
        public let contribution: Double
        /// Above the run's noise, so worth naming.
        public let isMeasurable: Bool
    }

    public let baseline: Double
    /// WindowServer with every measured app hidden at once: displays, desktop, menu bar, Activity+ itself.
    public let floor: Double?
    /// How far the two baselines (start and end of the run) differ.
    public let noise: Double
    public let causes: [Cause]

    public struct Step: Sendable {
        public let name: String
        public let bundleID: String?
        public let hiddenPercent: Double
        public init(name: String, bundleID: String?, hiddenPercent: Double) {
            self.name = name
            self.bundleID = bundleID
            self.hiddenPercent = hiddenPercent
        }
    }

    public init(before: Double, after: Double, steps: [Step], floor: Double?) {
        baseline = (before + after) / 2
        noise = abs(before - after)
        self.floor = floor
        // Two points or the baseline drift, whichever is larger: smaller drops are measuring noise.
        let threshold = max(2, noise)
        causes = steps.map { step in
            let contribution = max(0, (before + after) / 2 - step.hiddenPercent)
            return Cause(name: step.name, bundleID: step.bundleID, hiddenPercent: step.hiddenPercent,
                         contribution: contribution, isMeasurable: contribution >= threshold)
        }
        .sorted { $0.contribution > $1.contribution }
    }
}
