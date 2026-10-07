import Foundation
import Testing
@testable import ActivityCore

@Suite("GPU cause")
struct GPUCauseTests {
    @Test func ranksAppsByTheDropWhileHidden() {
        let result = GPUCauseAnalysis(steps: [
            .init(name: "Safari", bundleID: "com.apple.Safari", before: 52, hidden: 50, shownAgain: 51),
            .init(name: "Steam", bundleID: "com.valvesoftware.steam", before: 51, hidden: 14, shownAgain: 50),
        ], floor: 9)
        #expect(result.baseline == 52)
        #expect(result.causes.map(\.name) == ["Steam", "Safari"])
        #expect(result.causes[0].contribution == 37)
        #expect(result.causes[0].isMeasurable)
        #expect(!result.causes[1].isMeasurable)
        #expect(!result.causes[0].quieterAfterShown)
    }

    /// Steam stops drawing once hidden and stays quiet when shown again: the apps measured after it
    /// are compared with the lower load, not with the start of the run.
    @Test func appThatStaysQuietDoesNotHideTheOthers() {
        let result = GPUCauseAnalysis(steps: [
            .init(name: "Steam", bundleID: nil, before: 55, hidden: 6, shownAgain: 7),
            .init(name: "Arc", bundleID: nil, before: 7, hidden: 6, shownAgain: 7),
            .init(name: "Claude", bundleID: nil, before: 7, hidden: 2, shownAgain: 7),
        ], floor: 1)
        #expect(result.causes.map(\.name) == ["Steam", "Claude", "Arc"])
        #expect(result.causes[0].quieterAfterShown)
        #expect(result.causes[1].isMeasurable)
        #expect(!result.causes[2].isMeasurable)
    }

    @Test func busierWhileHiddenCountsAsZero() {
        let result = GPUCauseAnalysis(steps: [.init(name: "Notes", bundleID: nil, before: 10, hidden: 13, shownAgain: 10)], floor: 8)
        #expect(result.causes[0].contribution == 0)
    }

    @Test func percentBetweenSnapshots() {
        let a = [pid_t(417): GPUClientTime.Client(pid: 417, name: "WindowServer", nanoseconds: 1_000_000_000)]
        let b = [pid_t(417): GPUClientTime.Client(pid: 417, name: "WindowServer", nanoseconds: 2_500_000_000)]
        #expect(GPUClientTime.percent(pid: 417, from: a, to: b, seconds: 3) == 50)
        #expect(GPUClientTime.percent(pid: 1, from: a, to: b, seconds: 3) == 0)
    }
}
