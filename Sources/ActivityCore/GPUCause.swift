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
    public struct Step: Sendable {
        public let name: String
        public let bundleID: String?
        /// WindowServer GPU percent right before the app was hidden, while hidden, and right after it was shown again.
        public let before: Double
        public let hidden: Double
        public let shownAgain: Double
        public init(name: String, bundleID: String?, before: Double, hidden: Double, shownAgain: Double) {
            self.name = name
            self.bundleID = bundleID
            self.before = before
            self.hidden = hidden
            self.shownAgain = shownAgain
        }
    }

    public struct Cause: Equatable, Sendable, Identifiable {
        public var id: String { bundleID ?? name }
        public let name: String
        public let bundleID: String?
        public let hiddenPercent: Double
        /// Before minus hidden, in percentage points; never negative.
        public let contribution: Double
        /// Above this step's noise, so worth naming.
        public let isMeasurable: Bool
        /// WindowServer stayed clearly lower after the app was shown again: the app had been drawing
        /// constantly and stopped once it was hidden (Steam does this).
        public let quieterAfterShown: Bool
    }

    /// WindowServer with every window visible, at the start of the run.
    public let baseline: Double
    /// WindowServer with every measured app hidden at once.
    public let floor: Double?
    public let causes: [Cause]

    /// How much WindowServer's load wanders on its own: the median gap between the measurements
    /// right before and right after each app. The median ignores the one app that really changed it.
    public let noise: Double

    /// A drop has to clear two points, a tenth of the load, and three times the run's own noise.
    static func threshold(for load: Double, noise: Double) -> Double { max(2, load * 0.1, noise * 3) }

    public init(steps: [Step], floor: Double?) {
        baseline = steps.first?.before ?? 0
        self.floor = floor
        let gaps = steps.map { abs($0.before - $0.shownAgain) }.sorted()
        let noise = gaps.isEmpty ? 0 : gaps.count % 2 == 1 ? gaps[gaps.count / 2] : (gaps[gaps.count / 2 - 1] + gaps[gaps.count / 2]) / 2
        self.noise = noise
        causes = steps.map { step in
            let contribution = max(0, step.before - step.hidden)
            let threshold = Self.threshold(for: step.before, noise: noise)
            return Cause(name: step.name, bundleID: step.bundleID, hiddenPercent: step.hidden,
                         contribution: contribution, isMeasurable: contribution >= threshold,
                         quieterAfterShown: contribution >= threshold && step.before - step.shownAgain >= threshold)
        }
        .sorted { $0.contribution > $1.contribution }
    }
}

public enum ProcessOwner {
    /// The app macOS holds responsible for a process (Steam for "Steam Helper"), when it is known.
    public static func responsiblePID(for pid: pid_t) -> pid_t? {
        Responsibility.responsiblePID(for: pid)
    }
}
