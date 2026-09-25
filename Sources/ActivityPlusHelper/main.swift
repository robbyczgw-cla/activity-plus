import Darwin
import Foundation
import HelperShared

/// Activity+ privileged helper (LaunchDaemon, runs as root, started on demand by launchd).
/// Read-only: answers "what are the counters of these pids" and nothing else.
final class Helper: NSObject, NSXPCListenerDelegate, ActivityPlusHelperProtocol {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // The kernel checks the caller's code signature for us (macOS 13+).
        connection.setCodeSigningRequirement(HelperConstants.clientRequirement)
        connection.exportedInterface = NSXPCInterface(with: ActivityPlusHelperProtocol.self)
        connection.exportedObject = self
        connection.resume()
        return true
    }

    func version(reply: @escaping (String) -> Void) { reply(HelperConstants.version) }

    func usage(for pids: [NSNumber], reply: @escaping (Data) -> Void) {
        var result: [HelperProcessUsage] = []
        result.reserveCapacity(pids.count)
        for number in pids.prefix(5000) {
            let pid = number.int32Value
            guard pid > 0 else { continue }
            var info = proc_bsdinfo()
            let infoSize = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, infoSize) == infoSize else { continue }
            var usage = rusage_info_v6()
            let status = withUnsafeMutablePointer(to: &usage) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) }
            }
            guard status == 0 else { continue }
            var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
            let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
            result.append(HelperProcessUsage(
                pid: pid,
                startSeconds: Int64(info.pbi_start_tvsec), startMicroseconds: Int64(info.pbi_start_tvusec),
                footprint: usage.ri_phys_footprint,
                cpuTicks: usage.ri_user_time + usage.ri_system_time,
                diskRead: usage.ri_diskio_bytesread, diskWritten: usage.ri_diskio_byteswritten,
                energyNJ: usage.ri_energy_nj,
                path: length > 0 ? String(cString: buffer) : nil))
        }
        reply((try? JSONEncoder().encode(result)) ?? Data())
    }
}

let helper = Helper()
let listener = NSXPCListener(machServiceName: HelperConstants.machService)
listener.delegate = helper
listener.resume()
// launchd starts us on the first connection; exit after 10 idle minutes to use no memory at all in between.
let idle = DispatchSource.makeTimerSource()
idle.schedule(deadline: .now() + 600, repeating: 600)
idle.setEventHandler { exit(0) }
idle.resume()
RunLoop.main.run()
