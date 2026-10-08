import Foundation

/// A few seconds of call stacks from an app that stopped responding, taken with `/usr/bin/sample`
/// (works for apps of the same user, signed or not, without root). The report stays on this Mac.
public enum FreezeSample {
    public struct Report: Sendable {
        public let url: URL
        /// The main thread's busiest path, outermost first, with run-loop and kernel plumbing left out.
        public let mainThreadPath: [String]
        /// The app binary's own name, as sample labels its frames ("Mail" in "… (Mail)").
        public var binary: String? = nil

        /// The deepest frame from the app's own code, which is where its developer would look first.
        public var ownFrame: String? {
            guard let binary else { return nil }
            return mainThreadPath.last { $0.hasSuffix("(\(binary))") }
        }
    }

    public static var folder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Activity+/Freezes", isDirectory: true)
    }

    /// Samples `pid` for `seconds` and summarizes it. Nil when sample fails (the app quit, or macOS refused).
    public static func capture(pid: pid_t, name: String, seconds: Int = 3) async -> Report? {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let safeName = name.replacingOccurrences(of: "/", with: "-")
        let url = folder.appendingPathComponent("\(safeName) \(stamp).txt")
        let ok = await Task.detached(priority: .utility) { () -> Bool in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
            process.arguments = [String(pid), String(seconds), "-mayDie", "-file", url.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return false }
            process.waitUntilExit()
            return process.terminationStatus == 0
        }.value
        guard ok, let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        prune()
        var report = Report(url: url, mainThreadPath: mainThreadPath(text))
        report.binary = binaryName(text)
        return report
    }

    /// "Path:            /System/Applications/Mail.app/Contents/MacOS/Mail" → "Mail"
    static func binaryName(_ text: String) -> String? {
        guard let line = text.components(separatedBy: "\n").first(where: { $0.hasPrefix("Path:") }) else { return nil }
        return line.dropFirst(5).trimmingCharacters(in: .whitespaces).components(separatedBy: "/").last
    }

    /// Keeps the newest 30 reports; older ones go to the Trash, never deleted outright.
    static func prune(keep: Int = 30) {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let sorted = files.filter { $0.pathExtension == "txt" }.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a > b
        }
        for file in sorted.dropFirst(keep) { try? FileManager.default.trashItem(at: file, resultingItemURL: nil) }
    }

    /// Follows the heaviest branch of the main thread's call graph and returns its frames.
    ///
    /// sample prints the graph as indented lines like `+   613 -[NSApplication run]  (in AppKit) + 396  [0x…]`;
    /// the indentation is the depth, the number how many samples passed through that frame.
    public static func mainThreadPath(_ text: String) -> [String] {
        let lines = text.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.contains("com.apple.main-thread") }) else { return [] }
        struct Frame { let depth: Int; let count: Int; let symbol: String }
        var frames: [Frame] = []
        for line in lines[(start + 1)...] {
            // The next thread starts at the outermost level again.
            if line.hasPrefix("    ") && !line.hasPrefix("    +") && !line.hasPrefix("     ") { break }
            if line.trimmingCharacters(in: .whitespaces).isEmpty { break }
            guard let digit = line.firstIndex(where: \.isNumber) else { continue }
            let prefix = line[..<digit]
            guard prefix.allSatisfy({ " +!:|".contains($0) }) else { continue }
            let rest = line[digit...]
            let countText = rest.prefix { $0.isNumber }
            guard let count = Int(countText) else { continue }
            let symbol = rest.dropFirst(countText.count).trimmingCharacters(in: .whitespaces)
            frames.append(Frame(depth: prefix.count, count: count, symbol: symbol))
        }
        guard !frames.isEmpty else { return [] }
        // Walk down: at each step take the busiest child of the current frame.
        var path: [Frame] = [frames[0]]
        var index = 0
        while true {
            let parent = frames[index]
            guard index + 1 < frames.count, frames[index + 1].depth > parent.depth else { break }
            let childDepth = frames[index + 1].depth
            var best: (index: Int, count: Int)?
            var i = index + 1
            while i < frames.count, frames[i].depth > parent.depth {
                if frames[i].depth == childDepth, frames[i].count > (best?.count ?? -1) { best = (i, frames[i].count) }
                i += 1
            }
            guard let best, best.index > index else { break }
            index = best.index
            path.append(frames[index])
        }
        return path.map { clean($0.symbol) }.filter { !isPlumbing($0) }
    }

    /// "-[NSApplication run]  (in AppKit) + 396  [0x19e55390c]" → "-[NSApplication run] (AppKit)"
    static func clean(_ symbol: String) -> String {
        var s = symbol
        if let bracket = s.range(of: "  [0x") { s = String(s[..<bracket.lowerBound]) }
        if let plus = s.range(of: #"\) \+ \d+"#, options: .regularExpression) { s = String(s[..<plus.lowerBound]) + ")" }
        s = s.replacingOccurrences(of: "  (in ", with: " (")
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// Frames every app has on its main thread; they say nothing about why this one is stuck.
    static func isPlumbing(_ frame: String) -> Bool {
        let plumbing = ["start (dyld)", "NSApplicationMain", "-[NSApplication run]", "nextEventMatchingMask", "_DPSNextEvent",
                        "BlockUntilNextEventMatchingListInMode", "ReceiveNextEventCommon", "RunCurrentEventLoopInMode",
                        "_CFRunLoopRun", "__CFRunLoopRun", "__CFRunLoopServiceMachPort", "mach_msg", "main (", "???"]
        return plumbing.contains { frame.contains($0) }
    }
}
