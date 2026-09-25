import ActivityCore
import Foundation

// `aplus` — a terminal view of the same data the app shows.
//   aplus            top 15 apps by CPU after a 2 s measurement
//   aplus --memory   sort by memory
//   aplus --json     machine-readable output
//   aplus mcp        MCP server for AI agents (read-only tools)

let arguments = Set(CommandLine.arguments.dropFirst())
// `aplus mcp`: Model Context Protocol server on stdin/stdout for Claude, Codex & co.
if arguments.contains("mcp") { MCPServer.run() }
let sampler = SystemSampler()
if arguments.contains("--bench") {
    for (name, ms) in sampler.benchmark() { print(name.padding(toLength: 20, withPad: " ", startingAt: 0), String(format: "%7.1f ms", ms)) }
    exit(0)
}
_ = sampler.sample()                 // First sample only primes the counters.
Thread.sleep(forTimeInterval: 2)
let snapshot = sampler.sample()

let sorted = snapshot.apps.sorted {
    arguments.contains("--memory") ? $0.memory > $1.memory : $0.cpuPercent > $1.cpuPercent
}

if arguments.contains("--json") {
    let apps = sorted.map { app -> [String: Any] in
        ["name": app.name, "kind": app.kind.rawValue, "processes": app.processes.count,
         "cpu": (app.cpuPercent * 10).rounded() / 10, "memory": app.memory,
         "gpu": (app.gpuPercent * 10).rounded() / 10, "power": (app.powerWatts * 100).rounded() / 100,
         "netIn": Int(app.netInRate), "netOut": Int(app.netOutRate),
         "diskRead": Int(app.diskReadRate), "diskWrite": Int(app.diskWriteRate)]
    }
    let payload: [String: Any] = [
        "cpu": ["user": snapshot.cpu.user, "system": snapshot.cpu.system, "cores": snapshot.cpu.perCore],
        "memory": ["total": snapshot.memory.total, "used": snapshot.memory.used, "app": snapshot.memory.app,
                   "wired": snapshot.memory.wired, "compressed": snapshot.memory.compressed,
                   "swapUsed": snapshot.memory.swapUsed, "pressure": snapshot.memory.pressure.label],
        "processes": snapshot.processCount, "restricted": snapshot.restrictedProcessCount,
        "apps": apps,
    ]
    let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
    print(String(decoding: data, as: UTF8.self))
    exit(0)
}

let m = snapshot.memory
print("CPU \(Format.percent(snapshot.cpu.total)) (user \(Format.percent(snapshot.cpu.user)), system \(Format.percent(snapshot.cpu.system)))  ·  load \(String(format: "%.2f", snapshot.cpu.loadAverage.0))")
print("Memory \(Format.memory(m.used)) of \(Format.memory(m.total))  ·  app \(Format.memory(m.app)) wired \(Format.memory(m.wired)) compressed \(Format.memory(m.compressed))  ·  swap \(Format.memory(m.swapUsed))  ·  pressure \(m.pressure.label)")
print("Disk \(Format.storage(snapshot.disk.free)) free  ·  read \(Format.rate(snapshot.disk.readRate)) write \(Format.rate(snapshot.disk.writeRate))")
print("Network ↓ \(Format.rate(snapshot.network.inRate)) ↑ \(Format.rate(snapshot.network.outRate))")
if let gpu = snapshot.gpu { print("GPU \(gpu.name) \(Format.percent(gpu.utilization))  ·  \(Format.memory(gpu.memoryInUse))") }
if let b = snapshot.battery {
    print("Battery \(Format.percent(b.percent))\(b.isPluggedIn ? " plugged in" : "")  ·  health \(b.health.map { Format.percent($0) } ?? "–")  ·  cycles \(b.cycleCount)  ·  system \(b.systemPower.map(Format.watts) ?? "–")")
}
print("\(snapshot.processCount) processes → \(snapshot.apps.count) apps  (\(snapshot.restrictedProcessCount) without details)  ·  grouping API \(SystemSampler.groupingAvailable ? "ok" : "missing")\n")

func pad(_ s: String, _ n: Int) -> String { s.count >= n ? String(s.prefix(n)) : s + String(repeating: " ", count: n - s.count) }
func lpad(_ s: String, _ n: Int) -> String { s.count >= n ? s : String(repeating: " ", count: n - s.count) + s }
print(pad("APP", 28) + lpad("PROCS", 6) + lpad("CPU", 8) + lpad("MEMORY", 11) + lpad("GPU", 7) + lpad("POWER", 8) + lpad("NET ↓", 11))
for app in sorted.prefix(15) {
    print(pad(app.name, 28) + lpad("\(app.processes.count)", 6) + lpad(Format.percent(app.cpuPercent, decimals: 1), 8)
          + lpad(Format.memory(app.memory), 11) + lpad(Format.percent(app.gpuPercent), 7)
          + lpad(Format.watts(app.powerWatts), 8) + lpad(Format.rate(app.netInRate), 11))
}
