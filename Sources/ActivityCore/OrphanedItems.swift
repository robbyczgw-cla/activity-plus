import Foundation

/// A background item (launch agent or daemon) whose program is gone.
public struct OrphanedItem: Sendable, Hashable {
    public enum Reason: Sendable, Hashable {
        /// The program sits inside an app that no longer exists.
        case appMissing(bundlePath: String)
        /// The program file itself is gone.
        case programMissing(path: String)
    }

    public let reason: Reason
    public init(reason: Reason) { self.reason = reason }

    /// The path that is not there any more.
    public var missingPath: String {
        switch reason {
        case .appMissing(let bundle): bundle
        case .programMissing(let path): path
        }
    }

    public var badge: String {
        switch reason {
        case .appMissing: String(localized: "App missing")
        case .programMissing: String(localized: "Program missing")
        }
    }

    public var explanation: String {
        switch reason {
        case .appMissing(let bundle):
            let name = ((bundle as NSString).lastPathComponent as NSString).deletingPathExtension
            return String(localized: "\(name) was deleted, but this item stayed behind. It points to a program that is not there any more, so it does nothing and only leaves an entry in the log at every login.")
        case .programMissing(let path):
            return String(localized: "The program it should start, \((path as NSString).lastPathComponent), is not there any more, so it does nothing. Its app was probably removed without cleaning up.")
        }
    }
}

public enum OrphanedItems {
    /// Programs that run other files; for those the script they are given counts too.
    static let interpreters: Set<String> = ["sh", "bash", "zsh", "python", "python3", "perl", "ruby", "node"]

    /// Decides whether a launch item still has something to run.
    ///
    /// Items whose program path is relative, contains variables, or lives on a drive that is not connected
    /// are left alone: nothing can be said about those.
    public static func check(program: String?, arguments: [String], fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> OrphanedItem? {
        guard let program, program.hasPrefix("/"), !program.contains("$") else { return nil }
        if let missing = missingPart(of: program, fileExists: fileExists) { return missing }
        // "/bin/sh /Users/me/tools/start.sh": the script is the real program.
        if interpreters.contains((program as NSString).lastPathComponent), !arguments.contains("-c"), let script = arguments.dropFirst().first(where: { !$0.hasPrefix("-") }),
           script.hasPrefix("/"), !script.contains("$"), let missing = missingPart(of: script, fileExists: fileExists) {
            return missing
        }
        return nil
    }

    private static func missingPart(of path: String, fileExists: (String) -> Bool) -> OrphanedItem? {
        if fileExists(path) { return nil }
        // An external drive that is simply not plugged in is not an orphan.
        if path.hasPrefix("/Volumes/") {
            let parts = path.split(separator: "/")
            if parts.count >= 2, !fileExists("/Volumes/" + parts[1]) { return nil }
        }
        // The outermost .app that is missing: the whole app was deleted.
        if let range = path.range(of: ".app/") {
            let bundle = String(path[..<range.lowerBound]) + ".app"
            if !fileExists(bundle) { return OrphanedItem(reason: .appMissing(bundlePath: bundle)) }
        }
        return OrphanedItem(reason: .programMissing(path: path))
    }

    // MARK: Removing

    public enum RemoveError: LocalizedError {
        case notOwnItem, noLongerOrphaned, failed(String)
        public var errorDescription: String? {
            switch self {
            case .notOwnItem: String(localized: "Only items in your own LaunchAgents folder can be moved to the Trash here.")
            case .noLongerOrphaned: String(localized: "Its program is back, so the item was left alone.")
            case .failed(let message): message
            }
        }
    }

    /// Whether Activity+ may remove this item itself: a launch agent in the user's own folder.
    public static func canRemove(_ item: StartupItem, home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> Bool {
        guard item.scope == .userAgent, item.orphan != nil, let plist = item.plistPath else { return false }
        return plist.hasPrefix(home + "/Library/LaunchAgents/") && plist.hasSuffix(".plist")
    }

    /// Moves the plist to the Trash and unloads the agent from the user's session. Only call this after the user confirmed.
    public static func trash(_ item: StartupItem) throws {
        guard canRemove(item), let plist = item.plistPath else { throw RemoveError.notOwnItem }
        // Look again: the app may have been reinstalled since the scan.
        guard check(program: item.program, arguments: item.arguments) != nil else { throw RemoveError.noLongerOrphaned }
        do { try FileManager.default.trashItem(at: URL(fileURLWithPath: plist), resultingItemURL: nil) }
        catch { throw RemoveError.failed(error.localizedDescription) }
        // The file is safe in the Trash now; stop the loaded job, if there is one. A failure here is harmless
        // (an agent that never started is not loaded) and goes away at the next login.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["bootout", "gui/\(getuid())/\(item.label)"]
        process.standardOutput = Pipe(); process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
    }
}
