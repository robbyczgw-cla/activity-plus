import Darwin
import Foundation
import Security

/// One ancestor of a process, walking from the parent up to launchd.
public struct ParentProcess: Sendable, Hashable {
    public let pid: Int32
    public let name: String

    public init(pid: Int32, name: String) {
        self.pid = pid
        self.name = name
    }
}

/// On-disk code signature of an executable. `nil` from the inspector means "not signed".
public struct CodeSignature: Sendable, Hashable {
    public let identifier: String?
    public let teamID: String?
    public let authority: String?
    /// Apple platform binary (`anchor apple`), not Developer ID.
    public let isApple: Bool
    /// `nil` when the notarization check could not be decided.
    public let isNotarized: Bool?
    public let isValid: Bool

    public init(identifier: String?, teamID: String?, authority: String?, isApple: Bool, isNotarized: Bool?, isValid: Bool) {
        self.identifier = identifier
        self.teamID = teamID
        self.authority = authority
        self.isApple = isApple
        self.isNotarized = isNotarized
        self.isValid = isValid
    }
}

/// One TCP or UDP socket. `remoteHost` is left nil; the caller resolves names.
public struct Connection: Sendable, Hashable, Identifiable {
    public let id: String
    public let proto: String
    public let local: String
    public let remote: String
    public let remoteHost: String?
    public let state: String

    public init(id: String, proto: String, local: String, remote: String, remoteHost: String?, state: String) {
        self.id = id
        self.proto = proto
        self.local = local
        self.remote = remote
        self.remoteHost = remoteHost
        self.state = state
    }
}

/// Everything the inspector can see about one process. Missing rights become nil or empty, never a crash.
public struct ProcessDetails: Sendable, Hashable {
    public let pid: Int32
    public let executable: String?
    /// Full argv. Empty when the kernel refuses `KERN_PROCARGS2`.
    public let arguments: [String]
    public let workingDirectory: String?
    /// Parents, nearest first, ending at launchd (pid 1) when the chain is visible.
    public let parentChain: [ParentProcess]
    public let user: String
    public let startTime: Date?
    public let signature: CodeSignature?
    /// Regular files only, at most 200. Devices, sockets and pipes are left out.
    public let openFiles: [String]
    public let connections: [Connection]

    public init(pid: Int32, executable: String?, arguments: [String], workingDirectory: String?, parentChain: [ParentProcess], user: String, startTime: Date?, signature: CodeSignature?, openFiles: [String], connections: [Connection]) {
        self.pid = pid
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.parentChain = parentChain
        self.user = user
        self.startTime = startTime
        self.signature = signature
        self.openFiles = openFiles
        self.connections = connections
    }
}

/// Reads process identity, code signature, open files and sockets.
/// Own processes come from the kernel; other users' processes fall back to `ps` and setuid `lsof`.
public enum ProcessInspector {
    /// Full picture of `pid`. Fields the caller may not access stay nil or empty.
    public static func details(pid: Int32) -> ProcessDetails {
        var listed: [Int32: ProcessSampler.Listed]?
        let selfInfo = describe(pid, listed: &listed)
        let executable = selfInfo.path
        let signature = executable.flatMap { Self.signature(path: $0) }
        return ProcessDetails(
            pid: pid,
            executable: executable,
            arguments: ProjectScanner.arguments(of: pid),
            workingDirectory: ProjectScanner.workingDirectory(of: pid),
            parentChain: parentChain(ppid: selfInfo.ppid, origin: pid, listed: &listed),
            user: selfInfo.uid.map(userName) ?? "",
            startTime: selfInfo.start,
            signature: signature,
            openFiles: openFiles(pid: pid),
            connections: connections(pid: pid)
        )
    }

    /// TCP and UDP sockets of one process, numeric addresses, no reverse DNS.
    public static func connections(pid: Int32) -> [Connection] {
        // `-a` ANDs -p with -i. Without it lsof ORs the selectors and lists every socket on the machine.
        let output = runLsof(["-n", "-P", "-p", String(pid), "-a", "-i", "-F", "pPTnf"])
        return parseConnections(output, establishedOnly: false)[pid] ?? []
    }

    /// Every established TCP socket and every UDP socket that has a peer, from a single `lsof` pass.
    public static func connectionsByPID() -> [Int32: [Connection]] {
        let output = runLsof(["-n", "-P", "-i", "-F", "pPTnf"])
        return parseConnections(output, establishedOnly: true)
    }

    /// Signature of the executable at `path`. Unsigned or unreadable files return nil.
    public static func signature(path: String) -> CodeSignature? {
        var code: SecStaticCode?
        let url = URL(fileURLWithPath: path) as CFURL
        guard SecStaticCodeCreateWithPath(url, [], &code) == errSecSuccess, let code else { return nil }

        var raw: CFDictionary?
        let copied = SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &raw)
        guard copied == errSecSuccess, let raw else { return nil }
        let info = raw as NSDictionary

        let identifier = info[kSecCodeInfoIdentifier as NSString] as? String
        let teamID = info[kSecCodeInfoTeamIdentifier as NSString] as? String
        let certificates = info[kSecCodeInfoCertificates as NSString] as? [SecCertificate]
        let authority = certificates?.first.flatMap { SecCertificateCopySubjectSummary($0) as String? }
        let flags = (info[kSecCodeInfoFlags as NSString] as? NSNumber)?.uint32Value ?? 0
        let platform = info[kSecCodeInfoPlatformIdentifier as NSString] != nil || (flags & Self.platformBinary) != 0
        let requirement = requirementText(info)
        let appleAnchor = requirement.map(isAppleAnchor) ?? false

        // Checks the signature and every page of the executable. Resources (images, nibs) are skipped:
        // validating them can take seconds for large apps, and the inspector opens on a double-click.
        let valid = SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSDoNotValidateResources), nil) == errSecSuccess
        return CodeSignature(
            identifier: identifier,
            teamID: teamID,
            authority: authority,
            isApple: platform || appleAnchor,
            isNotarized: notarized(code),
            isValid: valid
        )
    }

    // MARK: - Identity

    private struct Identity {
        var ppid: Int32
        var uid: UInt32?
        var name: String
        var path: String?
        var start: Date?
    }

    /// `CS_PLATFORM_BINARY` from the kernel code-signing flags.
    private static let platformBinary: UInt32 = 0x04000000

    private static func describe(_ pid: Int32, listed: inout [Int32: ProcessSampler.Listed]?) -> Identity {
        if let bsd = ProcessSampler.bsdInfo(pid) {
            let path = ProcessSampler.path(of: pid)
            let name = lastComponent(path) ?? commName(bsd)
            let seconds = TimeInterval(bsd.pbi_start_tvsec) + TimeInterval(bsd.pbi_start_tvusec) / 1_000_000
            return Identity(
                ppid: Int32(truncatingIfNeeded: bsd.pbi_ppid),
                uid: bsd.pbi_uid,
                name: name.isEmpty ? "?" : name,
                path: path,
                start: seconds > 1 ? Date(timeIntervalSince1970: seconds) : nil
            )
        }
        if listed == nil { listed = loadListed() }
        if let entry = listed?[pid] {
            let path = entry.command.hasPrefix("/") ? entry.command : nil
            let name = lastComponent(path) ?? (entry.command.isEmpty ? "?" : entry.command)
            return Identity(ppid: entry.ppid, uid: entry.uid, name: name, path: path, start: psStart(pid))
        }
        return Identity(ppid: 0, uid: nil, name: "?", path: nil, start: nil)
    }

    private static func parentChain(ppid: Int32, origin: Int32, listed: inout [Int32: ProcessSampler.Listed]?) -> [ParentProcess] {
        var chain: [ParentProcess] = []
        var current = ppid
        var seen: Set<Int32> = [origin]
        while current > 0, seen.insert(current).inserted, chain.count < 32 {
            let parent = describe(current, listed: &listed)
            chain.append(ParentProcess(pid: current, name: parent.name))
            if current == 1 { break }
            current = parent.ppid
        }
        return chain
    }

    /// `ps` is setuid, so it still reports the start time when `proc_pidinfo` is refused.
    private static func psStart(_ pid: Int32) -> Date? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", String(pid), "-o", "lstart="]
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        let cleaned = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !cleaned.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        formatter.timeZone = .current
        return formatter.date(from: cleaned)
    }

    private static func loadListed() -> [Int32: ProcessSampler.Listed] {
        var map: [Int32: ProcessSampler.Listed] = [:]
        for entry in ProcessSampler.listProcesses() { map[entry.pid] = entry }
        return map
    }

    private static func commName(_ info: proc_bsdinfo) -> String {
        var copy = info
        let name = withUnsafePointer(to: &copy.pbi_name) {
            String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self))
        }
        if !name.isEmpty { return name }
        return withUnsafePointer(to: &copy.pbi_comm) {
            String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self))
        }
    }

    private static func lastComponent(_ path: String?) -> String? {
        guard let path, let last = path.split(separator: "/").last, !last.isEmpty else { return nil }
        return String(last)
    }

    private static func userName(_ uid: UInt32) -> String {
        guard let pw = getpwuid(uid), let name = pw.pointee.pw_name else { return String(uid) }
        return String(cString: name)
    }

    // MARK: - Signature

    private static func requirementText(_ info: NSDictionary) -> String? {
        guard let raw = info[kSecCodeInfoDesignatedRequirement as NSString] else { return nil }
        let requirement = raw as! SecRequirement
        var text: CFString?
        guard SecRequirementCopyString(requirement, [], &text) == errSecSuccess, let text else { return nil }
        return text as String
    }

    /// `anchor apple` is a platform binary. `anchor apple generic` is Developer ID or the App Store.
    private static func isAppleAnchor(_ requirement: String) -> Bool {
        var rest = Substring(requirement)
        while let found = rest.range(of: "anchor apple") {
            let after = rest[found.upperBound...]
            if !after.hasPrefix(" generic") { return true }
            rest = after
        }
        return false
    }

    private static func notarized(_ code: SecStaticCode) -> Bool? {
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString("notarized" as CFString, [], &requirement) == errSecSuccess,
              let requirement else { return nil }
        let status = SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSBasicValidateOnly), requirement)
        if status == errSecSuccess { return true }
        if status == errSecCSReqFailed { return false }
        return nil
    }

    // MARK: - lsof

    private static func runLsof(_ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    private static func openFiles(pid: Int32) -> [String] {
        let output = runLsof(["-n", "-P", "-p", String(pid), "-F", "tn"])
        var type = ""
        var files: [String] = []
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            if tag == "t" {
                type = value
            } else if tag == "n" {
                if type == "REG", !value.isEmpty, !value.hasPrefix("/dev"), files.count < 200 {
                    files.append(value)
                }
                type = ""
            }
        }
        return files
    }

    /// `-F` records: `p` pid, `f` fd, `P` protocol, `n` name, `T` with `ST=` state.
    private static func parseConnections(_ output: String, establishedOnly: Bool) -> [Int32: [Connection]] {
        var result: [Int32: [Connection]] = [:]
        var ordinal: [Int32: Int] = [:]
        var pid: Int32 = -1
        var proto = ""
        var name = ""
        var state = ""

        func flush() {
            defer { proto = ""; name = ""; state = "" }
            guard pid > 0, proto == "TCP" || proto == "UDP", !name.isEmpty else { return }
            let halves = name.components(separatedBy: "->")
            let local = halves[0]
            let remote = halves.count > 1 ? halves[1] : ""
            if establishedOnly {
                if proto == "TCP" {
                    guard state == "ESTABLISHED", hasPeer(remote) else { return }
                } else if !hasPeer(remote) {
                    return
                }
            }
            let index = ordinal[pid, default: 0]
            ordinal[pid] = index + 1
            let connection = Connection(
                id: "\(pid) \(proto) \(local) \(remote) \(state) \(index)",
                proto: proto,
                local: local,
                remote: remote,
                remoteHost: nil,
                state: state
            )
            result[pid, default: []].append(connection)
        }

        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            switch tag {
            case "p":
                flush()
                pid = Int32(value) ?? -1
            case "f":
                flush()
            case "P":
                proto = value
            case "n":
                name = value
            case "T":
                if value.hasPrefix("ST=") { state = String(value.dropFirst(3)) }
            default:
                break
            }
        }
        flush()
        return result
    }

    private static func hasPeer(_ remote: String) -> Bool {
        !remote.isEmpty && remote != "*" && !remote.hasPrefix("*:")
    }
}
