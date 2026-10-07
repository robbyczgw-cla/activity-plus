import Foundation
import Testing
@testable import ActivityCore

@Suite("GPU cause")
struct GPUCauseTests {
    @Test func ranksAppsByTheDropWhileHidden() {
        let result = GPUCauseAnalysis(before: 52, after: 50, steps: [
            .init(name: "Safari", bundleID: "com.apple.Safari", hiddenPercent: 49),
            .init(name: "Steam", bundleID: "com.valvesoftware.steam", hiddenPercent: 14),
        ], floor: 9)
        #expect(result.baseline == 51)
        #expect(result.causes.map(\.name) == ["Steam", "Safari"])
        #expect(result.causes[0].contribution == 37)
        #expect(result.causes[0].isMeasurable)
    }

    @Test func dropsWithinTheNoiseAreNotNamed() {
        // Baseline drifted by 6 points during the run: a 4-point drop proves nothing.
        let result = GPUCauseAnalysis(before: 30, after: 24, steps: [.init(name: "Mail", bundleID: nil, hiddenPercent: 23)], floor: nil)
        #expect(result.noise == 6)
        #expect(result.causes[0].contribution == 4)
        #expect(!result.causes[0].isMeasurable)
    }

    @Test func busierWhileHiddenCountsAsZero() {
        let result = GPUCauseAnalysis(before: 10, after: 10, steps: [.init(name: "Notes", bundleID: nil, hiddenPercent: 13)], floor: 8)
        #expect(result.causes[0].contribution == 0)
    }

    @Test func percentBetweenSnapshots() {
        let a = [pid_t(417): GPUClientTime.Client(pid: 417, name: "WindowServer", nanoseconds: 1_000_000_000)]
        let b = [pid_t(417): GPUClientTime.Client(pid: 417, name: "WindowServer", nanoseconds: 2_500_000_000)]
        #expect(GPUClientTime.percent(pid: 417, from: a, to: b, seconds: 3) == 50)
        #expect(GPUClientTime.percent(pid: 1, from: a, to: b, seconds: 3) == 0)
    }
}
