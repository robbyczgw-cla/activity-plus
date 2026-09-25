import Foundation
import Darwin

public struct StartupItem: Sendable, Identifiable, Hashable {
    public enum Scope: String, Sendable { case userAgent, globalAgent, globalDaemon, loginItem }
    public let id: String
    public let label: String
    public let scope: Scope
    public let plistPath: String?
    public let program: String?
    public let arguments: [String]
    public let runAtLoad: Bool
    public let keepAlive: Bool
    public let isDisabled: Bool
    public let isRunning: Bool
    public let pid: Int32?
    public let ownerBundlePath: String?
    public let ownerName: String
    public let isApple: Bool
    public var canToggle: Bool { scope == .userAgent }

    public init(id: String, label: String, scope: Scope, plistPath: String?, program: String?, arguments: [String], runAtLoad: Bool, keepAlive: Bool, isDisabled: Bool, isRunning: Bool, pid: Int32?, ownerBundlePath: String?, ownerName: String, isApple: Bool) {
        self.id = id; self.label = label; self.scope = scope; self.plistPath = plistPath; self.program = program; self.arguments = arguments
        self.runAtLoad = runAtLoad; self.keepAlive = keepAlive; self.isDisabled = isDisabled; self.isRunning = isRunning; self.pid = pid
        self.ownerBundlePath = ownerBundlePath; self.ownerName = ownerName; self.isApple = isApple
    }
}

public enum StartupItemsScanner {
    public struct Error: LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
        public init(_ message: String) { self.message = message }
    }

    private struct CommandResult { let status: Int32; let output: String; let stderr: String }

    public static func scan() -> [StartupItem] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let uid = getuid()
        let disabledUser = disabledLabels(run("/bin/launchctl", ["print-disabled", "gui/\(uid)"]).output)
        let disabledSystem = disabledLabels(run("/bin/launchctl", ["print-disabled", "system"]).output)
        let running = runningProcesses(run("/bin/launchctl", ["list"]).output)
        let apps = installedApps(home: home)
        var result: [StartupItem] = []
        let roots: [(String, StartupItem.Scope)] = [(home + "/Library/LaunchAgents", .userAgent), ("/Library/LaunchAgents", .globalAgent), ("/Library/LaunchDaemons", .globalDaemon)]
        for (root, scope) in roots {
            guard let urls = try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: root), includingPropertiesForKeys: nil) else { continue }
            for url in urls where url.pathExtension == "plist" {
                guard let data = try? Data(contentsOf: url), let dict = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any] else { continue }
                guard let label = dict["Label"] as? String, !label.isEmpty else { continue }
                if label.hasPrefix("com.apple."), scope != .userAgent { continue }
                let args = dict["ProgramArguments"] as? [String] ?? []
                let program = dict["Program"] as? String ?? args.first
                let pid = scope == .userAgent ? running[label] : nil
                let owner = ownerInfo(program: program, label: label, apps: apps)
                result.append(StartupItem(id: url.path, label: label, scope: scope, plistPath: url.path, program: program, arguments: args,
                    runAtLoad: dict["RunAtLoad"] as? Bool ?? false, keepAlive: (dict["KeepAlive"] as? Bool) == true || dict["KeepAlive"] is [String: Any],
                    isDisabled: (scope == .globalDaemon ? disabledSystem : disabledUser).contains(label), isRunning: pid != nil, pid: pid,
                    ownerBundlePath: owner.path, ownerName: owner.name, isApple: label.hasPrefix("com.apple.")))
            }
        }
        return result.sorted { a, b in
            if a.isApple != b.isApple { return !a.isApple }
            return a.ownerName.localizedCaseInsensitiveCompare(b.ownerName) == .orderedAscending
        }
    }

    public static func setEnabled(_ enabled: Bool, item: StartupItem) throws {
        guard item.scope == .userAgent, let plist = item.plistPath else { throw Error("Only user LaunchAgents can be toggled.") }
        let domain = "gui/\(getuid())", service = domain + "/" + item.label
        // The persistent enable/disable flag comes first and must succeed. Loading or unloading
        // afterwards may fail harmlessly: the agent can already be (un)loaded.
        let persistent = enabled ? ["enable", service] : ["disable", service]
        let result = run("/bin/launchctl", persistent)
        if result.status != 0 { throw Error("launchctl \(persistent.joined(separator: " ")) failed (\(result.status)): \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))") }
        let load = enabled ? ["bootstrap", domain, plist] : ["bootout", domain, plist]
        let loaded = run("/bin/launchctl", load)
        if loaded.status != 0, !enabled, item.isRunning {
            throw Error("It will not start at login any more, but it could not be stopped now: launchctl \(load.joined(separator: " ")) failed (\(loaded.status)).")
        }
    }

    public static func adminCommand(toDisable item: StartupItem) -> String {
        guard let path = item.plistPath else { return "" }
        switch item.scope {
        case .globalDaemon:
            return "sudo launchctl bootout system \(shellQuote(path)); sudo launchctl disable system/\(shellQuote(item.label))"
        case .globalAgent:
            // Agents in /Library/LaunchAgents run in each user's GUI domain, not in the system domain.
            let domain = "gui/\(getuid())"
            return "launchctl bootout \(domain) \(shellQuote(path)); launchctl disable \(domain)/\(shellQuote(item.label))"
        case .userAgent, .loginItem:
            return ""
        }
    }

    private static func run(_ executable: String, _ args: [String]) -> CommandResult {
        let process = Process(), out = Pipe(), err = Pipe()
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = args; process.standardOutput = out; process.standardError = err
        do { try process.run() } catch { return CommandResult(status: -1, output: "", stderr: error.localizedDescription) }
        let outputData = out.fileHandleForReading.readDataToEndOfFile(), errorData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return CommandResult(status: process.terminationStatus, output: String(decoding: outputData, as: UTF8.self), stderr: String(decoding: errorData, as: UTF8.self))
    }
    private static func disabledLabels(_ text: String) -> Set<String> {
        let pattern = #"[\"']([^\"']+)[\"']\s*=>\s*(?:disabled|true)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let ns = text as NSString
        return Set(regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { Range($0.range(at: 1), in: text).map { String(text[$0]) } })
    }
    private static func runningProcesses(_ text: String) -> [String: Int32] {
        var values: [String: Int32] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0.isWhitespace })
            guard parts.count >= 3, let pid = Int32(parts[0]), pid > 0 else { continue }
            values[String(parts[2])] = pid
        }
        return values
    }
    private static func installedApps(home: String) -> [(id: String, path: String, name: String)] {
        let fm = FileManager.default
        var roots = ["/Applications", "/Applications/Utilities", home + "/Applications"]
        roots = Array(Set(roots))
        var found: [(String, String, String)] = []
        for root in roots {
            guard let children = try? fm.contentsOfDirectory(at: URL(fileURLWithPath: root), includingPropertiesForKeys: [.isDirectoryKey]) else { continue }
            for app in children where app.pathExtension == "app" {
                let infoPath = app.appendingPathComponent("Contents/Info.plist")
                guard let data = try? Data(contentsOf: infoPath), let info = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any], let bid = info["CFBundleIdentifier"] as? String else { continue }
                found.append((bid, app.path, (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String) ?? app.deletingPathExtension().lastPathComponent))
            }
        }
        return found
    }
    private static func ownerInfo(program: String?, label: String, apps: [(id: String, path: String, name: String)]) -> (path: String?, name: String) {
        // A program inside an app bundle belongs to its outermost .app, installed or not.
        if let program, let range = program.range(of: ".app/") {
            let bundle = String(program[..<range.lowerBound]) + ".app"
            if FileManager.default.fileExists(atPath: bundle) {
                let name = FileManager.default.displayName(atPath: bundle).replacingOccurrences(of: ".app", with: "")
                return (bundle, name)
            }
        }
        if let program {
            let matching = apps.filter { program == $0.path || program.hasPrefix($0.path + "/") }.max { $0.path.count < $1.path.count }
            if let app = matching { return (app.path, app.name) }
        }
        if let app = apps.filter({ label == $0.id || label.hasPrefix($0.id + ".") }).max(by: { $0.id.count < $1.id.count }) { return (app.path, app.name) }
        // An installed app whose name appears in the label: "com.macpaw.CleanMyMac-setapp.Agent" → CleanMyMac.
        let squashed = label.lowercased().replacingOccurrences(of: "[^a-z0-9]", with: "", options: .regularExpression)
        if let app = apps.filter({ $0.name.count >= 4 && squashed.contains($0.name.lowercased().replacingOccurrences(of: " ", with: "")) })
            .max(by: { $0.name.count < $1.name.count }) {
            return (app.path, app.name)
        }
        // The only installed app from the same vendor ("com.google.keystone.agent" → Google Chrome).
        let components = label.split(separator: ".").map(String.init)
        if components.count >= 3 {
            let vendor = components.prefix(2).joined(separator: ".") + "."
            let vendorApps = apps.filter { $0.id.hasPrefix(vendor) }
            if vendorApps.count == 1, let app = vendorApps.first { return (app.path, app.name) }
        }
        // Otherwise a readable name, skipping generic tails like "Agent" or "Helper".
        let generic: Set<String> = ["agent", "helper", "daemon", "service", "launcher", "updater", "update", "plist", "backgroundagent", "startup", "server"]
        let meaningful = components.dropFirst(components.count > 2 ? 2 : 0).filter { !generic.contains($0.lowercased()) }
        let tail = meaningful.first ?? components.last ?? label
        let words = tail.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression).replacingOccurrences(of: "[-_]", with: " ", options: .regularExpression)
        return (nil, words.split(separator: " ").map { $0.capitalized }.joined(separator: " "))
    }
    private static func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
