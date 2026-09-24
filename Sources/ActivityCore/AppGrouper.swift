import Darwin
import Foundation

/// Folds ~1,000 processes into ~60 apps.
///
/// Order of evidence for which app a process belongs to:
/// 1. The kernel's "responsible process" (the same thing macOS uses for permission prompts).
///    This is what puts Chrome's helpers under Chrome and `node` started in Terminal under Terminal.
/// 2. The process's own path, if it lives inside a .app bundle.
/// 3. Its ancestors, walking up the parent chain.
/// Anything left is either a macOS system process or a stand-alone tool.
final class AppGrouper {
    struct Bundle: Sendable {
        let path: String
        let name: String
        let identifier: String?
        let isSystem: Bool
    }

    private var bundleCache: [String: Bundle] = [:]
    /// Which group a process belongs to never changes, so resolve it once per (pid, start time).
    private var resolved: [pid_t: (start: Date, key: String, name: String, kind: AppGroup.Kind, bundle: Bundle?)] = [:]

    func group(_ processes: [ProcessSample]) -> [AppGroup] {
        let byPID = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        var members: [String: [ProcessSample]] = [:]
        var descriptors: [String: (name: String, kind: AppGroup.Kind, bundle: Bundle?)] = [:]

        var stillAlive: [pid_t: (start: Date, key: String, name: String, kind: AppGroup.Kind, bundle: Bundle?)] = [:]
        for process in processes {
            let entry: (start: Date, key: String, name: String, kind: AppGroup.Kind, bundle: Bundle?)
            // Processes without details may gain them (and a better parent) on the next `ps` refresh; re-resolve those.
            if let cached = resolved[process.pid], cached.start == process.startTime, process.hasDetails {
                entry = cached
            } else {
                let (key, name, kind, bundle) = resolve(process, byPID: byPID)
                entry = (process.startTime, key, name, kind, bundle)
            }
            stillAlive[process.pid] = entry
            let (key, name, kind, bundle) = (entry.key, entry.name, entry.kind, entry.bundle)
            members[key, default: []].append(process)
            if descriptors[key] == nil { descriptors[key] = (name, kind, bundle) }
        }
        resolved = stillAlive

        return members.map { key, procs in
            let descriptor = descriptors[key]!
            let main = mainProcess(of: procs, bundle: descriptor.bundle)
            return AppGroup(
                id: key,
                name: descriptor.name,
                kind: descriptor.kind,
                bundlePath: descriptor.bundle?.path,
                bundleID: descriptor.bundle?.identifier,
                mainPID: main?.pid,
                processes: procs
            )
        }
    }

    private func resolve(_ process: ProcessSample, byPID: [pid_t: ProcessSample])
        -> (String, String, AppGroup.Kind, Bundle?)
    {
        if let bundle = owningBundle(of: process, byPID: byPID) {
            return (bundle.path, bundle.name, bundle.isSystem ? .system : .app, bundle)
        }
        if Self.isSystemProcess(process) {
            return ("system", "macOS", .system, nil)
        }
        return ("tool:\(process.name)", process.name, .tool, nil)
    }

    private func owningBundle(of process: ProcessSample, byPID: [pid_t: ProcessSample]) -> Bundle? {
        if let responsible = Responsibility.responsiblePID(for: process.pid),
           responsible != process.pid,
           let owner = byPID[responsible],
           let bundle = bundle(forExecutable: owner.path)
        {
            return bundle
        }
        if let bundle = bundle(forExecutable: process.path) { return bundle }

        var current = process
        var depth = 0
        while current.ppid > 1, depth < 32, let parent = byPID[current.ppid] {
            if let bundle = bundle(forExecutable: parent.path) { return bundle }
            current = parent
            depth += 1
        }
        return nil
    }

    /// The outermost .app containing an executable. Helpers nested inside
    /// `Chrome.app/Contents/Frameworks/…/Helper.app` resolve to `Chrome.app`.
    func bundle(forExecutable path: String?) -> Bundle? {
        guard let path, let range = path.range(of: ".app/") else { return nil }
        let bundlePath = String(path[..<range.lowerBound]) + ".app"
        if let cached = bundleCache[bundlePath] { return cached }

        let info = Foundation.Bundle(path: bundlePath)
        let displayName = (info?.localizedInfoDictionary?["CFBundleDisplayName"] as? String)
            ?? (info?.infoDictionary?["CFBundleDisplayName"] as? String)
            ?? FileManager.default.displayName(atPath: bundlePath).replacingOccurrences(of: ".app", with: "")
        let bundle = Bundle(
            path: bundlePath,
            name: displayName,
            identifier: info?.bundleIdentifier,
            // Agents inside /System/Library (Spotlight, Control Center…) are part of macOS,
            // but user-facing system apps (Safari, Terminal, Finder) are listed like any other app.
            isSystem: bundlePath.hasPrefix("/System/Library/") && !Self.userFacingSystemApps.contains(displayName)
        )
        bundleCache[bundlePath] = bundle
        return bundle
    }

    private static let userFacingSystemApps: Set<String> = ["Finder", "Dock", "Spotlight", "Siri", "Control Center"]

    static func isSystemProcess(_ process: ProcessSample) -> Bool {
        guard let path = process.path else { return true }
        if process.uid == 0 && !path.hasPrefix("/Library/") && !path.hasPrefix("/opt/") { return true }
        return ["/System/", "/usr/", "/sbin/", "/bin/", "/Library/Apple/"].contains { path.hasPrefix($0) }
    }

    private func mainProcess(of processes: [ProcessSample], bundle: Bundle?) -> ProcessSample? {
        if let bundle {
            let direct = bundle.path + "/Contents/MacOS/"
            if let main = processes.filter({ $0.path?.hasPrefix(direct) == true }).min(by: { $0.pid < $1.pid }) {
                return main
            }
        }
        return processes.min(by: { $0.pid < $1.pid })
    }
}

/// `responsibility_get_pid_responsible_for_pid` is private but stable since macOS 10.14;
/// Activity Monitor and most security tools rely on it. Loaded lazily so a missing
/// symbol only degrades grouping instead of crashing.
enum Responsibility {
    private typealias Function = @convention(c) (pid_t) -> pid_t

    private static let function: Function? = {
        guard let handle = dlopen(nil, RTLD_NOW),
              let symbol = dlsym(handle, "responsibility_get_pid_responsible_for_pid")
        else { return nil }
        return unsafeBitCast(symbol, to: Function.self)
    }()

    static var isAvailable: Bool { function != nil }

    static func responsiblePID(for pid: pid_t) -> pid_t? {
        guard let function else { return nil }
        let result = function(pid)
        return result > 0 ? result : nil
    }
}
