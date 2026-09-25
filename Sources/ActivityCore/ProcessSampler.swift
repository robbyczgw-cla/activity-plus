import Darwin
import Foundation

/// Counters for a process of another user, supplied by the privileged helper.
public struct PrivilegedUsage: Sendable {
    public let startTime: Date
    public let footprint: UInt64
    public let cpuTicks: UInt64
    public let diskRead: UInt64
    public let diskWritten: UInt64
    public let energyNJ: UInt64
    public let path: String?
    public init(startTime: Date, footprint: UInt64, cpuTicks: UInt64, diskRead: UInt64, diskWritten: UInt64, energyNJ: UInt64, path: String?) {
        (self.startTime, self.footprint, self.cpuTicks, self.diskRead, self.diskWritten, self.energyNJ, self.path) =
            (startTime, footprint, cpuTicks, diskRead, diskWritten, energyNJ, path)
    }
}

/// Reads every process from the kernel and turns cumulative counters into per-second rates.
final class ProcessSampler {
    /// Set when the privileged helper is installed: exact counters for processes we may not read.
    var privilegedUsage: (([pid_t]) -> [pid_t: PrivilegedUsage])?
    private struct Counters {
        let startTime: Date
        let cpuNanos: Double
        let diskRead: UInt64
        let diskWritten: UInt64
        let energyNJ: UInt64
    }

    private var previous: [pid_t: Counters] = [:]
    private var previousTime: UInt64 = 0
    private var pathCache: [pid_t: (start: Date, path: String?)] = [:]

    struct Result {
        var processes: [ProcessSample]
        var restricted: Int
    }

    // `ps` results for processes we cannot query ourselves (root, _windowserver…), refreshed every few seconds.
    private var listed: [pid_t: Listed] = [:]
    private var listedCPU: [pid_t: Double] = [:]
    private var listedAt: UInt64 = 0
    /// How often `ps` runs. It only matters for other users' processes; our own come from the kernel every tick.
    var listInterval: TimeInterval = 5

    func sample() -> Result {
        let now = DispatchTime.now().uptimeNanoseconds
        let elapsed = previousTime == 0 ? 0 : Double(now - previousTime) / 1_000_000_000
        previousTime = now

        if listedAt == 0 || Double(now - listedAt) / 1_000_000_000 >= listInterval {
            refreshListed(now: now)
        }

        var processes: [ProcessSample] = []
        var restricted = 0
        var current: [pid_t: Counters] = [:]
        var seenPaths: [pid_t: (start: Date, path: String?)] = [:]

        // Other users' processes: one batched request to the helper per sample, if it is installed.
        let me = getuid()
        let privileged = privilegedUsage?(listed.values.filter { $0.uid != me }.map(\.pid)) ?? [:]

        for pid in Self.allPIDs() {
            let bsd = Self.bsdInfo(pid)
            let entry = listed[pid]
            let helperUsage = privileged[pid]
            // Neither the kernel nor the last `ps` knows it: it started a moment ago under another user.
            guard bsd != nil || entry != nil else { continue }
            let start = bsd.map {
                Date(timeIntervalSince1970: TimeInterval($0.pbi_start_tvsec) + TimeInterval($0.pbi_start_tvusec) / 1_000_000)
            } ?? helperUsage?.startTime ?? Self.pseudoStart(for: entry!)

            let path: String?
            if let cached = pathCache[pid], cached.start == start {
                path = cached.path
            } else {
                path = Self.path(of: pid) ?? helperUsage?.path ?? entry.flatMap { $0.command.hasPrefix("/") ? $0.command : nil }
            }
            seenPaths[pid] = (start, path)

            var sample = ProcessSample(
                pid: pid,
                ppid: bsd.map { Int32($0.pbi_ppid) } ?? entry?.ppid ?? 0,
                uid: bsd?.pbi_uid ?? entry?.uid ?? 0,
                name: Self.name(bsd: bsd, path: path, command: entry?.command ?? ""),
                path: path,
                startTime: start
            )

            let exact: (counters: Counters, footprint: UInt64)? = {
                if let usage = Self.rusage(pid) {
                    return (Counters(startTime: start, cpuNanos: Double(usage.ri_user_time + usage.ri_system_time) * Sys.nanosPerTick,
                                     diskRead: usage.ri_diskio_bytesread, diskWritten: usage.ri_diskio_byteswritten,
                                     energyNJ: usage.ri_energy_nj), usage.ri_phys_footprint)
                }
                if let helperUsage, abs(helperUsage.startTime.timeIntervalSince(start)) < 0.001 || bsd == nil {
                    return (Counters(startTime: start, cpuNanos: Double(helperUsage.cpuTicks) * Sys.nanosPerTick,
                                     diskRead: helperUsage.diskRead, diskWritten: helperUsage.diskWritten,
                                     energyNJ: helperUsage.energyNJ), helperUsage.footprint)
                }
                return nil
            }()
            if let exact {
                let counters = exact.counters
                current[pid] = counters
                sample.memory = exact.footprint
                sample.cpuTime = counters.cpuNanos / 1_000_000_000

                // Only compare against the same process: pids get reused.
                if elapsed > 0, let prev = previous[pid], prev.startTime == start {
                    sample.cpuPercent = max(0, (counters.cpuNanos - prev.cpuNanos) / (elapsed * 1_000_000_000) * 100)
                    sample.diskReadRate = Double(counters.diskRead &- prev.diskRead) / elapsed
                    sample.diskWriteRate = Double(counters.diskWritten &- prev.diskWritten) / elapsed
                    if counters.energyNJ >= prev.energyNJ {
                        sample.powerWatts = Double(counters.energyNJ - prev.energyNJ) / 1_000_000_000 / elapsed
                    }
                }
            } else {
                // CPU rate over the last `ps` interval; resident memory instead of footprint.
                sample.memory = entry?.residentBytes ?? 0
                sample.cpuPercent = listedCPU[pid] ?? 0
                sample.cpuTime = entry?.cpuSeconds ?? 0
                sample.hasDetails = false
                restricted += 1
            }
            processes.append(sample)
        }

        previous = current
        pathCache = seenPaths
        return Result(processes: processes, restricted: restricted)
    }

    private func refreshListed(now: UInt64) {
        let fresh = Self.listProcesses()
        let seconds = listedAt == 0 ? 0 : Double(now - listedAt) / 1_000_000_000
        var cpu: [pid_t: Double] = [:]
        var byPID: [pid_t: Listed] = [:]
        for entry in fresh {
            byPID[entry.pid] = entry
            if seconds > 0, let old = listed[entry.pid], old.command == entry.command, entry.cpuSeconds >= old.cpuSeconds {
                cpu[entry.pid] = (entry.cpuSeconds - old.cpuSeconds) / seconds * 100
            }
        }
        listed = byPID
        listedCPU = cpu
        listedAt = now
    }

    // MARK: - ps

    struct Listed {
        let pid: pid_t
        let ppid: pid_t
        let uid: UInt32
        let cpuSeconds: Double
        let residentBytes: UInt64
        let command: String
    }

    /// Without the start time we identify a process by pid + command; a stable fake date keeps
    /// the "same process?" check working for processes we cannot query directly.
    private static func pseudoStart(for entry: Listed) -> Date {
        Date(timeIntervalSince1970: TimeInterval(abs(entry.command.hashValue % 1_000_000_000)))
    }

    static func listProcesses() -> [Listed] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,ppid=,uid=,time=,rss=,comm="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return allPIDs().map { Listed(pid: $0, ppid: 0, uid: 0, cpuSeconds: 0, residentBytes: 0, command: "") } }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return parsePS(String(decoding: data, as: UTF8.self))
    }

    static func parsePS(_ output: String) -> [Listed] {
        output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: " ", maxSplits: 5, omittingEmptySubsequences: true)
            guard fields.count == 6,
                  let pid = pid_t(fields[0]), let ppid = pid_t(fields[1]), let uid = UInt32(fields[2]),
                  let rss = UInt64(fields[4])
            else { return nil }
            return Listed(pid: pid, ppid: ppid, uid: uid, cpuSeconds: parseCPUTime(fields[3]),
                          residentBytes: rss * 1024, command: String(fields[5]))
        }
    }

    /// `ps` prints CPU time as `[dd-][hh:]mm:ss.cc`; minutes may exceed 59 ("1528:57.76").
    static func parseCPUTime(_ text: Substring) -> Double {
        var days = 0.0
        var rest = text
        if let dash = text.firstIndex(of: "-") {
            days = Double(text[..<dash]) ?? 0
            rest = text[text.index(after: dash)...]
        }
        var seconds = 0.0
        for (index, part) in rest.split(separator: ":").reversed().enumerated() {
            seconds += (Double(part) ?? 0) * pow(60, Double(index))
        }
        return seconds + days * 86_400
    }

    // MARK: - Kernel calls

    static func allPIDs() -> [pid_t] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 128)
        let count = pids.withUnsafeMutableBytes { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count))
        }
        guard count > 0 else { return [] }
        return Array(pids.prefix(Int(count)))
    }

    static func bsdInfo(_ pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info
    }

    static func rusage(_ pid: pid_t) -> rusage_info_v6? {
        var usage = rusage_info_v6()
        let status = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V6, $0)
            }
        }
        return status == 0 ? usage : nil
    }

    static func path(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    private static func name(bsd: proc_bsdinfo?, path: String?, command: String) -> String {
        // pbi_comm is truncated to 16 chars; the path's last component is the real name.
        if let path, let last = path.split(separator: "/").last { return String(last) }
        if let last = command.split(separator: "/").last, !command.isEmpty { return String(last) }
        guard var copy = bsd else { return "?" }
        return withUnsafePointer(to: &copy.pbi_name) {
            String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self))
        }
    }
}
