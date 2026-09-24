import Foundation

/// "Why is my Mac slow?" — turns the current snapshot and recent history into a plain-language verdict.
public struct Diagnosis: Sendable {
    public enum Severity: Int, Sendable, Comparable {
        case ok, info, warning, critical
        public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    }

    public enum Action: Sendable, Hashable {
        case quitApp(id: String, name: String)
        case openStorage
        case openStartupItems
        case openProjects
        case restartMac
        case openBatterySettings
    }

    public struct Finding: Sendable, Identifiable, Hashable {
        public let id: String
        public let severity: Severity
        public let title: String
        public let detail: String
        public let evidence: [String]
        public let action: Action?
    }

    public let severity: Severity
    public let headline: String
    public let summary: String
    public let findings: [Finding]
    public let date: Date
}

public struct DiagnosisInput: Sendable {
    public var snapshot: SystemSnapshot
    /// Whole-machine CPU % for the last few minutes, oldest first.
    public var recentCPU: [Double]
    /// Per-app CPU % for the last few minutes, keyed by AppGroup.id.
    public var recentAppCPU: [String: [Double]]
    /// Non-Apple launch agents and daemons that start with the Mac, when known.
    public var startupItemCount: Int?
    /// Dev servers idle for a while and the memory they hold.
    public var idleServers: (count: Int, memory: UInt64) = (0, 0)
    public var lowPowerMode: Bool = ProcessInfo.processInfo.isLowPowerModeEnabled

    public init(snapshot: SystemSnapshot, recentCPU: [Double], recentAppCPU: [String: [Double]]) {
        self.snapshot = snapshot
        self.recentCPU = recentCPU
        self.recentAppCPU = recentAppCPU
    }
}

public enum Diagnostician {
    public static func diagnose(_ input: DiagnosisInput) -> Diagnosis {
        let s = input.snapshot
        var findings: [Diagnosis.Finding] = []
        let userApps = s.apps.filter { $0.kind != .system }
        let cores = Double(max(1, s.cpu.perCore.count))

        // Memory
        let memory = s.memory
        let swapHeavy = memory.swapUsed > memory.total / 4
        if memory.pressure == .critical || (memory.pressure == .warning && (swapHeavy || memory.swapOutRate > 1_000_000)) {
            let top = userApps.sorted { $0.memory > $1.memory }.prefix(3)
            findings.append(.init(
                id: "memory",
                severity: memory.pressure == .critical ? .critical : .warning,
                title: "Not enough memory",
                detail: "Apps need more memory than this Mac has, so macOS compresses memory and moves it to the disk (swap). Switching apps and tabs gets slow."
                    + (top.first.map { " \($0.name) uses the most." } ?? ""),
                evidence: [
                    "Memory pressure: \(memory.pressure.label)",
                    "Swap used: \(Format.memory(memory.swapUsed))",
                    "Compressed: \(Format.memory(memory.compressed))",
                ] + top.map { "\($0.name): \(Format.memory($0.memory))" },
                action: top.first.map { .quitApp(id: $0.id, name: $0.name) }
            ))
        } else if memory.pressure == .warning {
            findings.append(.init(id: "memory", severity: .info, title: "Memory is getting tight",
                                  detail: "macOS is compressing memory. It still copes, but quitting unused apps gives it room.",
                                  evidence: ["Swap used: \(Format.memory(memory.swapUsed))"], action: nil))
        }

        // CPU
        let recent = input.recentCPU.suffix(30)
        let averageCPU = recent.isEmpty ? s.cpu.total : recent.reduce(0, +) / Double(recent.count)
        if averageCPU > 60 {
            let top = s.apps.sorted { $0.cpuPercent > $1.cpuPercent }.prefix(3)
            findings.append(.init(
                id: "cpu",
                severity: averageCPU > 85 ? .critical : .warning,
                title: "The processor is busy",
                detail: "The CPU averaged \(Format.percent(averageCPU)) over the last minutes. Everything else has to wait for it."
                    + (top.first.map { " Most of it is \($0.name)." } ?? ""),
                evidence: top.map { "\($0.name): \(Format.percent($0.cpuPercent)) of one core" },
                action: top.first(where: { $0.kind != .system }).map { .quitApp(id: $0.id, name: $0.name) }
            ))
        }

        // A single runaway app: more than one full core for the whole recent window.
        for app in userApps {
            guard let series = input.recentAppCPU[app.id], series.count >= 10 else { continue }
            let window = series.suffix(30)
            let average = window.reduce(0, +) / Double(window.count)
            guard average >= 95, window.allSatisfy({ $0 > 50 }) else { continue }
            findings.append(.init(
                id: "runaway-\(app.id)",
                severity: average >= cores * 50 ? .critical : .warning,
                title: "\(app.name) is running flat out",
                detail: "It has used about \(String(format: "%.1f", average / 100)) cores without a break. If you are not waiting for it to finish something, it may be stuck.",
                evidence: ["\(Format.percent(average)) average", "\(app.processes.count) processes"],
                action: .quitApp(id: app.id, name: app.name)
            ))
        }

        // Heat
        switch s.thermal {
        case .serious, .critical:
            findings.append(.init(
                id: "thermal", severity: .critical, title: "Your Mac is too hot and slows itself down",
                detail: "macOS lowers the processor speed to cool down. Give the vents room, remove it from soft surfaces, and quit heavy apps.",
                evidence: [s.sensors.cpuTemperature.map { String(format: "CPU %.0f °C", $0) }, "Thermal state: \(s.thermal.rawValue)"].compactMap { $0 },
                action: nil))
        case .fair:
            findings.append(.init(id: "thermal", severity: .info, title: "Your Mac is warm",
                                  detail: "Not slowing down yet, but it is close.",
                                  evidence: [s.sensors.cpuTemperature.map { String(format: "CPU %.0f °C", $0) }].compactMap { $0 }, action: nil))
        case .nominal:
            break
        }

        // Disk space
        if s.disk.total > 0 {
            let fraction = Double(s.disk.free) / Double(s.disk.total)
            if s.disk.free < 10_000_000_000 || fraction < 0.1 {
                findings.append(.init(
                    id: "disk-space", severity: s.disk.free < 5_000_000_000 ? .critical : .warning,
                    title: "The disk is almost full",
                    detail: "macOS needs free space for swap, updates and caches. Below about 10 % everything gets slower and updates can fail.",
                    evidence: ["\(Format.storage(s.disk.free)) free of \(Format.storage(s.disk.total))"],
                    action: .openStorage))
            }
        }

        // Heavy disk activity
        let io = s.disk.readRate + s.disk.writeRate
        if io > 200_000_000 {
            let top = s.apps.max { ($0.diskReadRate + $0.diskWriteRate) < ($1.diskReadRate + $1.diskWriteRate) }
            findings.append(.init(id: "disk-io", severity: .info, title: "The disk is very busy",
                                  detail: "Opening files and apps waits for the disk right now." + (top.map { " \($0.name) is doing most of it." } ?? ""),
                                  evidence: ["\(Format.rate(io)) read and written"], action: nil))
        }

        // Spotlight and kernel_task tell their own stories.
        let processes = s.apps.flatMap(\.processes)
        let spotlight = processes.filter { $0.name.hasPrefix("mds") || $0.name.hasPrefix("mdworker") }.reduce(0) { $0 + $1.cpuPercent }
        if spotlight > 40 {
            findings.append(.init(id: "spotlight", severity: .info, title: "Spotlight is indexing",
                                  detail: "Spotlight is reading new or changed files so search can find them. It finishes on its own.",
                                  evidence: ["Spotlight processes: \(Format.percent(spotlight))"], action: nil))
        }
        if let kernel = processes.first(where: { $0.name == "kernel_task" }), kernel.cpuPercent > 150 {
            findings.append(.init(id: "kernel-task", severity: .warning, title: "macOS is holding the CPU back",
                                  detail: "kernel_task uses CPU time on purpose to keep the processor cool, which usually means the Mac is hot or charging with a weak adapter.",
                                  evidence: ["kernel_task: \(Format.percent(kernel.cpuPercent))"], action: nil))
        }

        // GPU
        if let gpu = s.gpu, gpu.utilization > 90 {
            let top = s.apps.max { $0.gpuPercent < $1.gpuPercent }
            findings.append(.init(id: "gpu", severity: .info, title: "The graphics processor is maxed out",
                                  detail: "Animations and video may stutter." + (top.map { " \($0.name) uses the most GPU time." } ?? ""),
                                  evidence: ["GPU \(Format.percent(gpu.utilization))"], action: nil))
        }

        // Browsers with a lot of tabs
        let browsers = ["Google Chrome", "Arc", "Safari", "Firefox", "Microsoft Edge", "Brave Browser", "Zen", "Vivaldi", "Opera"]
        for app in userApps where browsers.contains(app.name) && app.memory > 6 * 1_073_741_824 {
            findings.append(.init(id: "browser-\(app.id)", severity: .info, title: "\(app.name) holds a lot of memory",
                                  detail: "Every open tab keeps its own process. Closing tabs you do not need frees memory right away.",
                                  evidence: ["\(Format.memory(app.memory)) in \(app.processes.count) processes"], action: nil))
        }

        // Idle dev servers
        if input.idleServers.count > 0, input.idleServers.memory > 300_000_000 {
            findings.append(.init(id: "dev-servers", severity: .info, title: "Idle dev servers still hold memory",
                                  detail: "\(input.idleServers.count) dev server\(input.idleServers.count == 1 ? " has" : "s have") not done anything for a while.",
                                  evidence: ["\(Format.memory(input.idleServers.memory)) held"], action: .openProjects))
        }

        // Long uptime together with swap
        if s.uptime > 14 * 86_400 {
            findings.append(.init(id: "uptime", severity: swapHeavy ? .warning : .info, title: "Your Mac has not restarted in \(Int(s.uptime / 86_400)) days",
                                  detail: "A restart clears swap, leaked memory and stuck background processes. It is the cheapest fix there is.",
                                  evidence: ["Up \(Format.duration(s.uptime))"], action: .restartMac))
        }

        if let count = input.startupItemCount, count > 15 {
            findings.append(.init(id: "startup", severity: .info, title: "\(count) things start with your Mac",
                                  detail: "Each one runs in the background and starts at login. Turn off the ones you do not need.",
                                  evidence: [], action: .openStartupItems))
        }

        if input.lowPowerMode {
            findings.append(.init(id: "low-power", severity: .info, title: "Low Power Mode is on",
                                  detail: "It saves battery by running the processor slower.", evidence: [], action: .openBatterySettings))
        }
        if let health = s.battery?.health, health < 80 {
            findings.append(.init(id: "battery", severity: .info, title: "The battery is worn",
                                  detail: "It holds \(Format.percent(health)) of its original charge. Apple recommends service below 80 %.",
                                  evidence: ["\(s.battery?.cycleCount ?? 0) charge cycles"], action: .openBatterySettings))
        }

        findings.sort { $0.severity > $1.severity }
        let worst = findings.first?.severity ?? .ok
        let headline: String
        let summary: String
        switch worst {
        case .ok, .info:
            headline = "Your Mac is running fine"
            summary = findings.isEmpty
                ? "Memory, processor, disk and temperature all look healthy."
                : "Nothing is slowing it down right now. A few things are worth knowing."
        case .warning, .critical:
            let main = findings[0]
            headline = main.title
            let others = findings.filter { $0.severity >= .warning }.count - 1
            summary = "This is what slows your Mac down the most right now; details and a fix are below."
                + (others > 0 ? " \(others) more thing\(others == 1 ? " needs" : "s need") attention." : "")
        }
        return Diagnosis(severity: worst, headline: headline, summary: summary, findings: findings, date: s.date)
    }
}
