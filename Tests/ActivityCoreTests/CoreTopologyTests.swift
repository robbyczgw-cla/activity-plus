import Foundation
import Testing
@testable import ActivityCore

@Suite("Core topology")
struct CoreTopologyTests {
    private func fake(_ levels: [(name: String?, cpus: Int)]) -> SysctlReader {
        var ints: [String: Int] = ["hw.nperflevels": levels.count]
        var strings: [String: String] = [:]
        for (i, level) in levels.enumerated() {
            ints["hw.perflevel\(i).logicalcpu"] = level.cpus
            if let name = level.name { strings["hw.perflevel\(i).name"] = name }
        }
        let (i, s) = (ints, strings)
        return SysctlReader(int: { i[$0] }, string: { s[$0] })
    }

    @Test func twoLevelsEfficiencyFirst() {
        let t = CoreTopology.read(fake([("Performance", 8), ("Efficiency", 2)]))
        #expect(t.clusters.map(\.kind) == [.efficiency, .performance])
        #expect(t.clusters[0].cpus == 0..<2)
        #expect(t.clusters[1].cpus == 2..<10)
        #expect(t.efficiencyCores == 2)
        #expect(t.totalCores == 10)
        #expect(t.isClassic)
        #expect(t.cluster(forCPU: 1)?.letter == "E")
        #expect(t.cluster(forCPU: 2)?.letter == "P")
    }

    @Test func oneLevel() {
        let t = CoreTopology.read(fake([("Performance", 8)]))
        #expect(t.clusters.count == 1)
        #expect(t.clusters[0].kind == .performance)
        #expect(t.clusters[0].cpus == 0..<8)
        #expect(t.efficiencyCores == 0)
        #expect(t.isClassic)
    }

    @Test func missingSysctlsFallBackToOneOrTwoLevels() {
        let none = CoreTopology.read(SysctlReader(int: { _ in nil }, string: { _ in nil }))
        #expect(none.clusters.isEmpty)
        #expect(!none.isClassic)
        let unnamed = CoreTopology.read(fake([(nil, 6), (nil, 4)]))
        #expect(unnamed.clusters.map(\.kind) == [.efficiency, .performance])
        #expect(unnamed.isClassic)
    }

    @Test func threeLevels() {
        let t = CoreTopology.read(fake([("Super", 4), ("Performance", 8), ("Efficiency", 6)]))
        #expect(t.clusters.map(\.name) == ["Efficiency", "Performance", "Super"])
        #expect(t.clusters.map(\.kind) == [.efficiency, .performance, .super])
        #expect(t.clusters.map(\.cpus) == [0..<6, 6..<14, 14..<18])
        #expect(t.efficiencyCores == 6)
        #expect(t.totalCores == 18)
        #expect(!t.isClassic)
        #expect(t.clusters[2].letter == "S")
    }

    @Test func superPlusPerformanceIsNotClassic() {
        let t = CoreTopology.read(fake([("Super", 6), ("Performance", 12)]))
        #expect(t.clusters.map(\.kind) == [.performance, .super])
        #expect(t.efficiencyCores == 0)
        #expect(!t.isClassic)
    }

    @Test func unknownNamesKeepTheRawName() {
        let t = CoreTopology.read(fake([("Mystery", 2), ("Efficiency", 4), ("Performance", 4)]))
        let unknown = t.clusters.last
        #expect(unknown?.kind == .unknown)
        #expect(unknown?.label == "Mystery")
        #expect(unknown?.letter == "M")
        #expect(!t.isClassic)
    }

    @Test func mismatchedCoreCountFallsBackToOneCluster() {
        let t = CoreTopology.read(fake([("Performance", 8), ("Efficiency", 2)]))
        #expect(t.fitted(to: 10) == t)
        let fitted = t.fitted(to: 12)
        #expect(fitted.clusters.count == 1)
        #expect(fitted.clusters[0].kind == .unknown)
        #expect(fitted.clusters[0].cpus == 0..<12)
        #expect(fitted.efficiencyCores == 0)
    }

    @Test func cpuStatsDerivesEfficiencyCores() {
        var stats = CPUStats()
        #expect(stats.efficiencyCores == 0)
        stats.clusters = CoreTopology.read(fake([("Performance", 8), ("Efficiency", 2)])).clusters
        #expect(stats.efficiencyCores == 2)
    }

    @Test func thisMacIsConsistent() {
        let t = CoreTopology.current
        #expect(t.totalCores == (Sys.sysctlInt("hw.logicalcpu") ?? 0))
    }
}
