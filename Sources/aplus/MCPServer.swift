import Foundation
import ActivityCore
import Darwin

enum MCPServer {
    private static let queue = DispatchQueue(label: "activity-plus.mcp.sampler")
    private static let sampler = SystemSampler()
    private static let projects = ProjectScanner()
    private static var latest = SystemSnapshot()
    private static var cpuSeries: [Double] = []
    private static var appSeries: [String: [Double]] = [:]
    private static var started = false
    /// Must be kept alive: a DispatchSourceTimer that is released stops firing.
    private static var timer: DispatchSourceTimer?

    static func run() -> Never {
        startSampling()
        while let line = readLine() {
            if let response = handle(line) {
                FileHandle.standardOutput.write(Data((response + "\n").utf8))
                fflush(stdout)
            }
        }
        exit(EXIT_SUCCESS)
    }

    static func handle(_ line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let request = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        guard let method = request["method"] as? String else { return error(id: request["id"], code: -32600, message: "Invalid Request") }
        let id = request["id"]
        if method == "notifications/initialized" { return nil }
        if id == nil { return nil }
        startSampling()
        switch method {
        case "initialize":
            return result(id: id, value: ["protocolVersion": "2025-06-18", "serverInfo": ["name": "activity-plus", "version": "1.0.0"], "capabilities": ["tools": [String: Any]()]])
        case "ping": return result(id: id, value: [:])
        case "tools/list": return result(id: id, value: ["tools": toolDefinitions])
        case "tools/call":
            let params = request["params"] as? [String: Any] ?? [:]
            let name = params["name"] as? String ?? ""
            let args = params["arguments"] as? [String: Any] ?? [:]
            guard let value = callTool(name, args) else {
                return result(id: id, value: ["content": [["type": "text", "text": "Unknown tool: \(name)"]], "isError": true])
            }
            let text = pretty(value)
            return result(id: id, value: ["content": [["type": "text", "text": text]]])
        default: return error(id: id, code: -32601, message: "Method not found")
        }
    }

    private static func startSampling() {
        queue.sync {
            guard !started else { return }
            started = true
            func tick() {
                let snapshot = sampler.sample()
                latest = snapshot
                cpuSeries.append(snapshot.cpu.total)
                if cpuSeries.count > 60 { cpuSeries.removeFirst(cpuSeries.count - 60) }
                for app in snapshot.apps { appSeries[app.id, default: []].append(app.cpuPercent) }
                for key in appSeries.keys { if appSeries[key]!.count > 60 { appSeries[key]!.removeFirst(appSeries[key]!.count - 60) } }
                projects.observe(snapshot.apps.flatMap(\.processes), at: snapshot.date)
            }
            tick()
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now() + 2, repeating: 2)
            source.setEventHandler { tick() }
            source.resume()
            timer = source
        }
    }

    private static let toolDefinitions: [[String: Any]] = [
        tool("get_overview", "Current CPU, memory, disk, network, GPU, battery and temperatures", [:]),
        tool("top_apps", "Apps ranked by a live metric", ["metric": enumSchema(["cpu", "memory", "gpu", "disk", "network", "energy"]), "limit": ["type": "integer", "default": 10], "include_system": ["type": "boolean", "default": false]]),
        tool("app_processes", "Processes belonging to apps whose name contains the query", ["app": ["type": "string"]], ["app"]),
        tool("diagnose", "Diagnose current system pressure using recent samples", [:]),
        tool("dev_servers", "Read-only inventory of development servers", [:]),
        tool("history", "Historical app totals, the child processes behind the top apps, and system totals. Pass `around` (ISO 8601 time) to see which processes were busy in the 5-minute window around a moment, e.g. a spike.", ["range": enumSchema(["12h", "24h", "7d", "30d"]), "metric": enumSchema(["cpu", "memory", "gpu", "disk", "network", "energy"]), "around": ["type": "string", "description": "ISO 8601 date-time, optional"]]),
        tool("startup_items", "Non-Apple startup items", [:])
    ]

    private static func callTool(_ name: String, _ args: [String: Any]) -> Any? {
        let state = queue.sync { (latest, cpuSeries, appSeries) }
        let s = state.0
        switch name {
        case "get_overview":
            let memory = s.memory
            return ["date": iso(s.date), "cpu": ["user": s.cpu.user, "system": s.cpu.system, "used": s.cpu.total, "formatted": Format.percent(s.cpu.total), "per_core": s.cpu.perCore], "memory": ["used": memory.used, "total": memory.total, "pressure": memory.pressure.label, "swap_used": memory.swapUsed, "swap_total": memory.swapTotal, "formatted_used": Format.memory(memory.used), "formatted_total": Format.memory(memory.total)], "disk": ["total": s.disk.total, "free": s.disk.free, "read_rate": s.disk.readRate, "write_rate": s.disk.writeRate, "formatted_free": Format.storage(s.disk.free), "formatted_read_rate": Format.rate(s.disk.readRate), "formatted_write_rate": Format.rate(s.disk.writeRate)], "network": ["in_rate": s.network.inRate, "out_rate": s.network.outRate, "received": s.network.receivedSinceLaunch, "sent": s.network.sentSinceLaunch, "formatted_in_rate": Format.rate(s.network.inRate), "formatted_out_rate": Format.rate(s.network.outRate)], "gpu": s.gpu.map { ["name": $0.name, "utilization": $0.utilization, "memory": $0.memoryInUse, "formatted_utilization": Format.percent($0.utilization), "formatted_memory": Format.memory($0.memoryInUse)] } as Any? ?? NSNull(), "battery": s.battery.map { ["percent": $0.percent, "charging": $0.isCharging, "plugged_in": $0.isPluggedIn, "health": $0.health as Any? ?? NSNull(), "temperature": $0.temperature as Any? ?? NSNull(), "formatted": Format.percent($0.percent)] } as Any? ?? NSNull(), "temperatures": ["cpu": s.sensors.cpuTemperature as Any? ?? NSNull(), "gpu": s.sensors.gpuTemperature as Any? ?? NSNull(), "battery": s.sensors.batteryTemperature as Any? ?? NSNull()], "thermal": s.thermal.rawValue]
        case "top_apps":
            let metric = args["metric"] as? String ?? "cpu", limit = max(1, min(100, args["limit"] as? Int ?? 10)), includeSystem = args["include_system"] as? Bool ?? false
            let apps = s.apps.filter { includeSystem || $0.kind != .system }.sorted { score($0, metric) > score($1, metric) }.prefix(limit)
            return apps.map(appObject)
        case "app_processes":
            let query = (args["app"] as? String ?? "").lowercased()
            return s.apps.filter { $0.name.lowercased().contains(query) }.flatMap(\.processes).map { ["pid": $0.pid, "name": $0.name, "path": $0.path as Any? ?? NSNull(), "cpu": $0.cpuPercent, "memory": $0.memory, "formatted_cpu": Format.percent($0.cpuPercent), "formatted_memory": Format.memory($0.memory)] as [String: Any] }
        case "diagnose":
            let input = DiagnosisInput(snapshot: s, recentCPU: state.1, recentAppCPU: state.2)
            let d = Diagnostician.diagnose(input)
            return ["headline": d.headline, "severity": String(describing: d.severity), "summary": d.summary, "findings": d.findings.map { ["id": $0.id, "severity": String(describing: $0.severity), "title": $0.title, "detail": $0.detail, "evidence": $0.evidence] as [String: Any] }]
        case "dev_servers":
            let processes = s.apps.flatMap(\.processes)
            let result = queue.sync { projects.scan(processes) }   // same serial queue as observe()
            return result.projects.map { project in ["name": project.name, "root": project.root, "servers": project.servers.map { server in ["pid": server.pid, "name": server.name, "ports": server.ports, "command": server.command, "memory": server.memory, "formatted_memory": Format.memory(server.memory), "activity": activityText(server), "idle": server.isIdle()] as [String: Any] }] as [String: Any] }
        case "history":
            let ranges: [String: HistoryStore.Range] = ["12h": .hours12, "24h": .hours24, "7d": .days7, "30d": .days30]
            let range = ranges[args["range"] as? String ?? "24h"] ?? .hours24
            let metric = args["metric"] as? String ?? "cpu"
            let store = HistoryStore()
            let totals = store.totals(since: Calendar.current.startOfDay(for: Date()))
            if let around = (args["around"] as? String).flatMap({ ISO8601DateFormatter().date(from: $0) }) {
                return ["around": iso(around), "window_minutes": 5, "processes": store.processesAround(around, limit: 12).map(processObject)]
            }
            let end = Date(), start = end.addingTimeInterval(-range.seconds)
            let apps = store.topApps(range).sorted { historyScore($0, metric) > historyScore($1, metric) }
            return ["range": args["range"] as? String ?? "24h", "apps": apps.enumerated().map { index, a -> [String: Any] in
                var object: [String: Any] = ["name": a.name, "average_cpu": a.averageCPU, "average_memory": a.averageMemory, "peak_memory": a.peakMemory, "disk_bytes": a.diskBytes, "network_bytes": a.networkBytes, "energy_wh": a.energyWh, "gpu_average": a.gpuAverage]
                if index < 5 { object["top_processes"] = store.topProcesses(appID: a.appID, from: start, to: end, limit: 3).map(processObject) }
                return object
            }, "today_totals": ["disk_written": totals.diskWritten, "disk_read": totals.diskRead, "received": totals.received, "sent": totals.sent, "energy_wh": totals.energyWh, "average_cpu": totals.averageCPU]]
        case "startup_items":
            return StartupItemsScanner.scan().filter { !$0.isApple }.map { ["id": $0.id, "label": $0.label, "scope": $0.scope.rawValue, "owner": $0.ownerName, "program": $0.program as Any? ?? NSNull(), "enabled": !$0.isDisabled, "running": $0.isRunning] as [String: Any] }
        default: return nil
        }
    }

    private static func processObject(_ p: ProcessTotal) -> [String: Any] { ["app": p.appName, "name": p.name, "command": p.command, "pid": p.pid, "average_cpu": p.averageCPU, "peak_memory": p.peakMemory, "disk_bytes": p.diskBytes, "network_bytes": p.networkBytes] }
    private static func appObject(_ a: AppGroup) -> [String: Any] { ["name": a.name, "kind": a.kind.rawValue, "process_count": a.processes.count, "cpu": a.cpuPercent, "formatted_cpu": Format.percent(a.cpuPercent), "memory": a.memory, "formatted_memory": Format.memory(a.memory), "gpu": a.gpuPercent, "formatted_gpu": Format.percent(a.gpuPercent), "disk_read": a.diskReadRate, "disk_write": a.diskWriteRate, "formatted_disk_read": Format.rate(a.diskReadRate), "formatted_disk_write": Format.rate(a.diskWriteRate), "network_in": a.netInRate, "network_out": a.netOutRate, "formatted_network_in": Format.rate(a.netInRate), "formatted_network_out": Format.rate(a.netOutRate), "energy_watts": a.powerWatts, "formatted_energy": Format.watts(a.powerWatts), "neural_engine_memory": a.neuralMemory, "p_core_share": a.pCoreShare as Any? ?? NSNull(), "ipc": a.ipc as Any? ?? NSNull()] }
    private static func score(_ a: AppGroup, _ metric: String) -> Double { switch metric { case "memory": Double(a.memory); case "gpu": a.gpuPercent; case "disk": a.diskReadRate + a.diskWriteRate; case "network": a.netInRate + a.netOutRate; case "energy": a.powerWatts; default: a.cpuPercent } }
    private static func historyScore(_ a: HistoryStore.AppTotal, _ metric: String) -> Double { switch metric { case "memory": a.averageMemory; case "gpu": a.gpuAverage; case "disk": a.diskBytes; case "network": a.networkBytes; case "energy": a.energyWh; default: a.averageCPU } }
    private static func activityText(_ s: DevServer) -> String { switch s.activity() { case .working: "working"; case .idle(let t): "idle for \(Format.duration(t))"; case .barelyUsed(let t): "barely used, up \(Format.duration(t))" } }
    private static func tool(_ name: String, _ description: String, _ props: [String: Any], _ required: [String] = []) -> [String: Any] { ["name": name, "description": description, "inputSchema": ["type": "object", "properties": props, "required": required]] }
    private static func enumSchema(_ values: [String]) -> [String: Any] { ["type": "string", "enum": values] }
    private static func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
    private static func pretty(_ value: Any) -> String { guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]), let string = String(data: data, encoding: .utf8) else { return "{}" }; return string }
    private static func result(id: Any?, value: Any) -> String { encode(["jsonrpc": "2.0", "id": id ?? NSNull(), "result": value]) }
    private static func error(id: Any?, code: Int, message: String) -> String { encode(["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]]) }
    private static func encode(_ object: [String: Any]) -> String { guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed]), let text = String(data: data, encoding: .utf8) else { return "{}" }; return text }
}
