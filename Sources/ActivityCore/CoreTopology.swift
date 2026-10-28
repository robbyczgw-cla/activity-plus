import Foundation

/// The kind of a CPU cluster as macOS names its performance level.
public enum CoreKind: String, Sendable, Hashable {
    case `super`, performance, efficiency, unknown

    /// Maps the name macOS reports in `hw.perflevelN.name` ("Super", "Performance", "Efficiency").
    init(macOSName name: String) {
        let n = name.lowercased()
        if n.contains("super") { self = .super }
        else if n.contains("perf") { self = .performance }
        else if n.contains("eff") { self = .efficiency }
        else { self = .unknown }
    }
}

/// A group of CPU cores that share a performance level. `cpus` are indices into `CPUStats.perCore`.
public struct CoreCluster: Sendable, Hashable {
    /// The name macOS reports (e.g. "Super"), or a generic one where it reports none.
    public let name: String
    public let kind: CoreKind
    public let cpus: Range<Int>

    public init(name: String, kind: CoreKind, cpus: Range<Int>) {
        self.name = name
        self.kind = kind
        self.cpus = cpus
    }

    public var count: Int { cpus.count }

    /// Localized label for the three known kinds, the raw macOS name otherwise.
    public var label: String {
        switch kind {
        case .super: String(localized: "Super")
        case .performance: String(localized: "Performance")
        case .efficiency: String(localized: "Efficiency")
        case .unknown: name
        }
    }

    /// One character for the small caption under a core bar.
    public var letter: String {
        switch kind {
        case .super: "S"
        case .performance: "P"
        case .efficiency: "E"
        case .unknown: name.first.map { String($0).uppercased() } ?? "?"
        }
    }
}

/// Reads sysctl values; injectable so tests can fake chips with any number of performance levels.
public struct SysctlReader: Sendable {
    public var int: @Sendable (String) -> Int?
    public var string: @Sendable (String) -> String?

    public init(int: @escaping @Sendable (String) -> Int?, string: @escaping @Sendable (String) -> String?) {
        self.int = int
        self.string = string
    }

    public static let system = SysctlReader(int: { Sys.sysctlInt($0) }, string: { Sys.sysctlString($0) })
}

/// The CPU clusters of this Mac, in the order of the CPU numbers (and so of `CPUStats.perCore`).
public struct CoreTopology: Sendable, Hashable {
    public let clusters: [CoreCluster]

    public init(clusters: [CoreCluster]) { self.clusters = clusters }

    /// Reads `hw.nperflevels` and, per level, `.name` and `.logicalcpu`.
    /// macOS numbers levels from the fastest (0) down; CPU numbers run the other way on Apple silicon
    /// (the efficiency cores are CPUs 0…N-1 on a two-level chip), so the last level gets the first CPUs.
    public static func read(_ sysctl: SysctlReader = .system) -> CoreTopology {
        let levels = max(1, sysctl.int("hw.nperflevels") ?? 1)
        var found: [(name: String, kind: CoreKind, count: Int)] = []
        for level in 0..<levels {
            guard let count = sysctl.int("hw.perflevel\(level).logicalcpu"), count > 0 else { continue }
            if let raw = sysctl.string("hw.perflevel\(level).name"), !raw.isEmpty {
                found.append((raw, CoreKind(macOSName: raw), count))
            } else if levels == 1 {
                found.append(("Performance", .performance, count))
            } else if levels == 2 {
                // Without names the two-level layout has always been performance + efficiency.
                found.append(level == 0 ? ("Performance", .performance, count) : ("Efficiency", .efficiency, count))
            } else {
                found.append(("Level \(level)", .unknown, count))
            }
        }
        var next = 0
        let clusters = found.reversed().map { level -> CoreCluster in
            defer { next += level.count }
            return CoreCluster(name: level.name, kind: level.kind, cpus: next..<(next + level.count))
        }
        return CoreTopology(clusters: clusters)
    }

    /// The topology of this Mac, read once.
    public static let current = CoreTopology.read()

    public var totalCores: Int { clusters.last?.cpus.upperBound ?? 0 }

    /// Falls back to one unnamed cluster when the sysctl counts do not add up to the cores the kernel lists,
    /// so a bar is never labelled with the wrong kind.
    public func fitted(to coreCount: Int) -> CoreTopology {
        if coreCount == totalCores, !clusters.isEmpty { return self }
        guard coreCount > 0 else { return CoreTopology(clusters: []) }
        return CoreTopology(clusters: [CoreCluster(name: "CPU", kind: .unknown, cpus: 0..<coreCount)])
    }

    public func cluster(forCPU index: Int) -> CoreCluster? { clusters.first { $0.cpus.contains(index) } }

    /// Number of efficiency cores; they are the first CPUs.
    public var efficiencyCores: Int { clusters.filter { $0.kind == .efficiency }.reduce(0) { $0 + $1.count } }

    /// True for the classic layout: one performance cluster and at most one efficiency cluster.
    /// Only there are the per-cluster clocks (pmgr tables `voltage-states1-sram` E and `voltage-states5-sram` P)
    /// and the kernel's `ri_user_ptime` split (performance vs. rest) known to describe what the UI says.
    public var isClassic: Bool {
        guard !clusters.isEmpty, clusters.count <= 2 else { return false }
        let kinds = clusters.map(\.kind)
        return kinds.filter({ $0 == .performance }).count == 1 && kinds.filter({ $0 == .efficiency }).count == clusters.count - 1
    }
}
