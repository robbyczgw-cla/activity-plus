import Foundation

/// Whether Spotlight is building its search index right now, and what that costs.
///
/// `mdutil -s` only says whether indexing is switched on for a volume, never whether it is busy, so
/// "indexing" is read from the work the Spotlight processes do (mds, mds_stores, mdworker).
public struct SpotlightStatus: Sendable, Equatable {
    public struct Volume: Sendable, Equatable, Identifiable {
        public enum State: Sendable, Equatable { case on, off, unknown }
        public let path: String
        public let state: State
        public var id: String { path }
        public init(path: String, state: State) { self.path = path; self.state = state }

        /// "/" is shown by its volume name ("Macintosh HD"), other mount points by their folder name.
        public var displayName: String {
            if path == "/" || path == "/System/Volumes/Data" {
                return (try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeNameKey]).volumeName) ?? String(localized: "the startup disk")
            }
            return (path as NSString).lastPathComponent
        }
    }

    public var volumes: [Volume] = []
    public var cpuPercent: Double = 0
    /// Bytes per second read and written by the Spotlight processes.
    public var diskRate: Double = 0
    public var processCount: Int = 0

    public init() {}

    /// Spotlight at idle uses a few percent; indexing after an update or a big copy keeps several processes busy.
    public static let indexingThreshold: Double = 25

    public var isIndexing: Bool { cpuPercent >= Self.indexingThreshold && volumes.contains { $0.state != .off } }

    /// Volumes that hold user data and are indexed: the system's helper volumes (Preboot, VM…) are left out.
    public var indexedVolumes: [Volume] {
        volumes.filter { $0.state == .on && !Self.isSystemHelperVolume($0.path) }
    }

    static func isSystemHelperVolume(_ path: String) -> Bool {
        (path.hasPrefix("/System/Volumes/") && path != "/System/Volumes/Data") || path.contains("/DeviceFS") || path.hasPrefix("/private/")
    }

    /// Names of the volumes being indexed, for the card title.
    public var indexingTitle: String {
        let names = indexedVolumes.map(\.displayName)
        let unique = names.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        return unique.isEmpty ? String(localized: "Spotlight is indexing") : String(localized: "Spotlight is indexing \(unique.joined(separator: ", "))")
    }

    // MARK: Reading

    /// Sums what the Spotlight processes use right now.
    public static func usage(of processes: [ProcessSample]) -> (cpu: Double, disk: Double, count: Int) {
        let spotlight = processes.filter { $0.name.hasPrefix("mds") || $0.name.hasPrefix("mdworker") }
        return (spotlight.reduce(0) { $0 + $1.cpuPercent }, spotlight.reduce(0) { $0 + $1.diskReadRate + $1.diskWriteRate }, spotlight.count)
    }

    /// Output of `mdutil -s -a`: a volume line ending in ":" followed by an indented status line.
    public static func parseMdutil(_ output: String) -> [Volume] {
        var volumes: [Volume] = []
        var path: String?
        for raw in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(raw)
            if !line.hasPrefix("\t"), !line.hasPrefix(" "), line.hasSuffix(":") {
                path = String(line.dropLast())
            } else if let current = path {
                let text = line.trimmingCharacters(in: .whitespaces).lowercased()
                let state: Volume.State = text.contains("disabled") || text.contains("turned off") ? .off : text.contains("enabled") ? .on : .unknown
                volumes.append(Volume(path: current, state: state))
                path = nil
            }
        }
        return volumes
    }

    /// Runs `mdutil -s -a` (read-only). Takes a moment; call it off the main thread.
    public static func readVolumes() -> [Volume] {
        let process = Process(), out = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdutil")
        process.arguments = ["-s", "-a"]
        process.standardOutput = out
        process.standardError = Pipe()
        do { try process.run() } catch { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return parseMdutil(String(decoding: data, as: UTF8.self))
    }

    // MARK: Rebuilding

    /// The AppleScript that rebuilds the index of the startup disk. Only built here; the app runs it after the user confirmed.
    public static let rebuildAppleScript = #"do shell script "/usr/bin/mdutil -E /" with administrator privileges"#
}
