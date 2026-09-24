import Darwin
import Foundation

/// A process you started for development that is listening on a port.
public struct DevServer: Sendable, Identifiable, Hashable {
    public let pid: Int32
    public let name: String
    /// Short command line, e.g. "vite --port 5173".
    public let command: String
    public let ports: [Int]
    public let directory: String?
    public let startTime: Date
    public var memory: UInt64
    public var cpuPercent: Double
    public var cpuTime: Double
    /// Last time we saw it do real work (CPU or network). nil = not since Activity+ started.
    public var lastActive: Date?
    /// Pids that belong to this server (the listener and its children).
    public var pids: [Int32]
    public var id: Int32 { pid }

    public enum Activity: Sendable, Hashable {
        case working
        case idle(since: TimeInterval)
        case barelyUsed(uptime: TimeInterval)
    }

    public func activity(now: Date = Date()) -> Activity {
        let uptime = now.timeIntervalSince(startTime)
        if let lastActive, now.timeIntervalSince(lastActive) < 120 { return .working }
        // Less than 0.2 % of one core over its whole life and up for more than a day.
        if uptime > 86_400, cpuTime / uptime < 0.002 { return .barelyUsed(uptime: uptime) }
        let idleFor = now.timeIntervalSince(lastActive ?? startTime)
        return idleFor < 120 ? .working : .idle(since: idleFor)
    }

    /// Worth pointing out: running for a while without doing anything.
    public func isIdle(now: Date = Date()) -> Bool {
        switch activity(now: now) {
        case .working: false
        case .idle(let since): since > 30 * 60
        case .barelyUsed: true
        }
    }
}

public struct Project: Sendable, Identifiable, Hashable {
    public let root: String
    public let name: String
    public var servers: [DevServer]
    public var id: String { root }
}

/// A listening port owned by an app rather than a dev project (Spotify, AirPlay, databases…).
public struct OpenPort: Sendable, Identifiable, Hashable {
    public let port: Int
    public let address: String
    public let pid: Int32
    public let processName: String
    public var id: String { "\(pid):\(address):\(port)" }
}

/// Finds dev servers and groups them by the project folder they run in.
public final class ProjectScanner: @unchecked Sendable {
    public struct Result: Sendable {
        public var projects: [Project] = []
        public var otherPorts: [OpenPort] = []
        public init() {}
    }

    private var lastActive: [Int32: (start: Date, date: Date)] = [:]
    private let home = FileManager.default.homeDirectoryForCurrentUser.path

    public init() {}

    /// Call on every snapshot so idle detection sees each burst of work.
    public func observe(_ processes: [ProcessSample], at date: Date) {
        for process in processes where process.cpuPercent > 1 || process.netInRate + process.netOutRate > 2_000 {
            lastActive[process.pid] = (process.startTime, date)
        }
    }

    /// Runs `lsof` (~100–300 ms); call every few seconds at most, off the main thread.
    public func scan(_ processes: [ProcessSample]) -> Result {
        let byPID = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        let listeners = Self.listeningSockets()
        let uid = getuid()

        var result = Result()
        var serversByRoot: [String: [DevServer]] = [:]

        for (pid, sockets) in listeners {
            guard let process = byPID[pid] else { continue }
            let ports = Array(Set(sockets.map(\.port))).sorted()
            let cwd = Self.workingDirectory(of: pid)
            let isDev = process.uid == uid && Self.looksLikeDevProcess(process, cwd: cwd, home: home)
            guard isDev, let cwd, let root = projectRoot(for: cwd) else {
                for socket in sockets {
                    result.otherPorts.append(OpenPort(port: socket.port, address: socket.address, pid: pid, processName: process.name))
                }
                continue
            }

            let family = descendants(of: pid, in: processes) + [process]
            let active = family.compactMap { member -> Date? in
                guard let seen = lastActive[member.pid], seen.start == member.startTime else { return nil }
                return seen.date
            }.max()
            let server = DevServer(
                pid: pid,
                name: process.name,
                command: Self.shortCommand(pid: pid, fallback: process.name),
                ports: ports,
                directory: cwd,
                startTime: process.startTime,
                memory: family.reduce(0) { $0 + $1.memory },
                cpuPercent: family.reduce(0) { $0 + $1.cpuPercent },
                cpuTime: family.reduce(0) { $0 + $1.cpuTime },
                lastActive: active,
                pids: family.map(\.pid)
            )
            serversByRoot[root, default: []].append(server)
        }

        result.projects = serversByRoot.map { root, servers in
            Project(root: root, name: (root as NSString).lastPathComponent, servers: servers.sorted { ($0.ports.first ?? 0) < ($1.ports.first ?? 0) })
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        result.otherPorts.sort { $0.port < $1.port }

        let live = Set(processes.map(\.pid))
        lastActive = lastActive.filter { live.contains($0.key) }
        return result
    }

    /// Stops a server and its children (SIGTERM; the caller confirms first).
    @discardableResult
    public static func stop(_ server: DevServer) -> Bool {
        var stopped = false
        for pid in server.pids.sorted(by: >) where pid > 1 && pid != getpid() {
            if kill(pid, SIGTERM) == 0 { stopped = true }
        }
        return stopped
    }

    // MARK: - Heuristics

    private static let devRuntimes: Set<String> = [
        "node", "bun", "deno", "python", "python3", "ruby", "php", "java", "go", "dotnet", "beam.smp",
        "uvicorn", "gunicorn", "rails", "puma", "hugo", "caddy", "nginx", "redis-server", "postgres",
        "mysqld", "mongod", "ollama", "vite", "esbuild", "cargo", "air", "flask", "streamlit", "jupyter",
    ]

    static func looksLikeDevProcess(_ process: ProcessSample, cwd: String?, home: String) -> Bool {
        let name = process.name.lowercased()
        let path = process.path ?? ""
        if path.contains(".app/") && !devRuntimes.contains(name) { return false }
        if path.hasPrefix("/System/") || path.hasPrefix("/usr/libexec/") || path.hasPrefix("/usr/sbin/") { return false }
        if devRuntimes.contains(name) || name.hasPrefix("python") || name.hasPrefix("node") { return true }
        // Compiled servers (Go, Rust…) started from a folder in the home directory.
        guard let cwd else { return false }
        return cwd.hasPrefix(home + "/") && !cwd.hasPrefix(home + "/Library/")
    }

    private static let projectMarkers = [
        ".git", "package.json", "pyproject.toml", "requirements.txt", "Cargo.toml", "go.mod", "Gemfile",
        "composer.json", "deno.json", "Package.swift", "pom.xml", "build.gradle", "mix.exs", "docker-compose.yml",
    ]

    private var rootCache: [String: String?] = [:]

    func projectRoot(for directory: String) -> String? {
        if let cached = rootCache[directory] { return cached }
        var current = URL(fileURLWithPath: directory)
        var found: String?
        var best: String?
        while current.path.count > 1, current.path != home {
            for marker in Self.projectMarkers where FileManager.default.fileExists(atPath: current.appendingPathComponent(marker).path) {
                // Prefer the outermost folder with .git (monorepos), else the nearest marker.
                if marker == ".git" { found = current.path } else if best == nil { best = current.path }
            }
            current.deleteLastPathComponent()
        }
        let root = found ?? best ?? (directory.hasPrefix(home + "/") && directory != home ? directory : nil)
        rootCache[directory] = root
        return root
    }

    private func descendants(of pid: Int32, in processes: [ProcessSample]) -> [ProcessSample] {
        var children: [Int32: [ProcessSample]] = [:]
        for p in processes { children[p.ppid, default: []].append(p) }
        var result: [ProcessSample] = []
        var stack = children[pid] ?? []
        while let next = stack.popLast(), result.count < 200 {
            result.append(next)
            stack.append(contentsOf: children[next.pid] ?? [])
        }
        return result
    }

    // MARK: - System calls

    struct Socket: Hashable {
        let address: String
        let port: Int
    }

    /// pid → listening TCP sockets, via `lsof -F` (field output is stable and easy to parse).
    static func listeningSockets() -> [Int32: [Socket]] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-iTCP", "-sTCP:LISTEN", "-F", "pn"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return [:] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return parseLsof(String(decoding: data, as: UTF8.self))
    }

    static func parseLsof(_ output: String) -> [Int32: [Socket]] {
        var result: [Int32: Set<Socket>] = [:]
        var pid: Int32?
        for line in output.split(separator: "\n") {
            guard let tag = line.first else { continue }
            let value = line.dropFirst()
            if tag == "p" {
                pid = Int32(value)
            } else if tag == "n", let pid, let colon = value.lastIndex(of: ":"), let port = Int(value[value.index(after: colon)...]) {
                let address = String(value[..<colon])
                result[pid, default: []].insert(Socket(address: address == "*" ? "all interfaces" : address, port: port))
            }
        }
        return result.mapValues { Array($0) }
    }

    static func workingDirectory(of pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafePointer(to: &info.pvi_cdir.vip_path) {
            String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self))
        }
        return path.isEmpty || path == "/" ? nil : path
    }

    /// The process's arguments (KERN_PROCARGS2), trimmed to something readable: "vite --port 5173".
    static func shortCommand(pid: Int32, fallback: String) -> String {
        let args = arguments(of: pid)
        guard !args.isEmpty else { return fallback }
        let interesting = args.map { ($0 as NSString).lastPathComponent }
        // "node /Users/…/node_modules/.bin/vite --port 5173" → "vite --port 5173"
        let skipInterpreter = ["node", "python", "python3", "ruby", "bun", "deno", "php"].contains(interesting[0].lowercased())
            || interesting[0].lowercased().hasPrefix("python")
        let parts = skipInterpreter && interesting.count > 1 ? Array(interesting.dropFirst()) : interesting
        let joined = parts.prefix(6).joined(separator: " ")
        return joined.count > 60 ? String(joined.prefix(57)) + "…" : joined
    }

    static func arguments(of pid: Int32) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }

        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        var index = MemoryLayout<Int32>.size
        // Skip the executable path and the padding NULs after it.
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }

        var args: [String] = []
        var start = index
        while index < size, args.count < argc {
            if buffer[index] == 0 {
                args.append(String(decoding: buffer[start..<index], as: UTF8.self))
                start = index + 1
            }
            index += 1
        }
        return args
    }
}
