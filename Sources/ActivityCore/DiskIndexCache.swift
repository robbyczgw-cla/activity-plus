import Foundation

/// Where the app keeps the cached size map of each root and its scan summaries ("What grew"). Shared by the app
/// and the MCP server, which only ever reads these files and never scans.
public enum DiskIndexCache {
    public struct Location: Sendable {
        /// Folder the map covers.
        public let root: URL
        public let cacheURL: URL
        public let growthURL: URL
    }

    public static var folder: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("at.hifiteam.activityplus", isDirectory: true)
    }

    /// FNV-1a; `hashValue` changes on every launch.
    public static func stableHash(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
        return String(hash, radix: 16)
    }

    /// File names for a root. `key` is nil for the home folder (the original, unsuffixed names).
    public static func location(root: URL, key: String?, in folder: URL = DiskIndexCache.folder) -> Location {
        let suffix = key.map { "-\($0)" } ?? ""
        return Location(root: root, cacheURL: folder.appendingPathComponent("diskindex\(suffix).bin"),
                        growthURL: folder.appendingPathComponent("growth\(suffix).json"))
    }

    public static func home(in folder: URL = DiskIndexCache.folder) -> Location {
        location(root: FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL, key: nil, in: folder)
    }

    public static func startupDisk(in folder: URL = DiskIndexCache.folder) -> Location {
        location(root: URL(fileURLWithPath: "/", isDirectory: true), key: stableHash("/"), in: folder)
    }

    /// Two drives can both be called "Untitled": the volume's UUID tells them apart.
    public static func volume(path: String, uuid: String?, in folder: URL = DiskIndexCache.folder) -> Location {
        location(root: URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL,
                 key: stableHash(path + "|" + (uuid ?? "")), in: folder)
    }

    /// The location for a mounted volume, looking its UUID up (nil when `path` is not a mounted volume).
    public static func mountedVolume(path: String, in folder: URL = DiskIndexCache.folder) -> Location? {
        let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        guard let values = try? url.resourceValues(forKeys: [.volumeUUIDStringKey, .volumeURLKey]),
              let mount = values.volume?.standardizedFileURL, mount.path == url.path else { return nil }
        return volume(path: url.path, uuid: values.volumeUUIDString, in: folder)
    }
}
