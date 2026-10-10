import Foundation

// Shared types for the Storage tabs (Explore, System Data, Biggest, Clean up).
// Nothing in here touches the disk.

/// What a file is, by extension. Drives the colour in the treemap and the breakdown by kind.
public enum FileKind: String, Sendable, CaseIterable, Codable {
    case video, image, audio, archive, code, document, app, dataCache, other

    private static let byExtension: [String: FileKind] = {
        var map: [String: FileKind] = [:]
        func add(_ kind: FileKind, _ extensions: String) {
            for ext in extensions.split(separator: " ") { map[String(ext)] = kind }
        }
        add(.video, "mov mp4 m4v mkv avi webm mpg mpeg mts m2ts braw r3d prores 3gp")
        add(.image, "jpg jpeg png heic heif gif tiff tif bmp webp raw cr2 cr3 nef arw dng raf orf psd ai svg exr")
        add(.audio, "mp3 m4a aac wav aif aiff flac alac ogg opus caf logicx band")
        add(.archive, "zip tar gz tgz bz2 xz 7z rar dmg pkg mpkg iso xip sparseimage sparsebundle cdr ipa apk")
        add(.code, "swift c h m mm cpp hpp cc rs go py rb js mjs cjs ts tsx jsx java kt kts cs php sh zsh lua dart scala json yml yaml toml xml html css scss o a dylib so class jar wasm")
        add(.document, "pdf doc docx pages key numbers xls xlsx ppt pptx txt rtf md csv epub odt ods")
        add(.dataCache, "db sqlite sqlite3 sqlite-wal sqlite-shm realm cache log plist ldb sst blob")
        return map
    }()

    /// Kind for a file name or extension (case-insensitive). Bundles such as `.app` count as `.app`.
    public static func classify(name: String) -> FileKind {
        let ext = (name as NSString).pathExtension.lowercased()
        if ext == "app" { return .app }
        return byExtension[ext] ?? .other
    }
}

/// How careful the user has to be before removing something.
public enum Safety: String, Sendable, Codable {
    /// Rebuilt automatically by the app or tool that made it (caches, logs, package manager downloads).
    case safeToClear
    /// Can be removed, but holds something the user may want (simulators, archives, backups, downloads).
    case lookFirst
    /// macOS manages it (swap, sleep image, local snapshots); shown for understanding only, never removable here.
    case managedByMacOS
}

/// Space the user could get back, with a plain reason. Produced by System Data and Clean up; never deletes anything itself.
public struct ReclaimableItem: Sendable, Identifiable, Hashable {
    public let id: String
    /// Short name, e.g. "Homebrew downloads" or "CoreSimulator".
    public let title: String
    /// Where it lives, for display, e.g. "~/Library/Caches/Homebrew".
    public let location: String
    /// Everything that would move to the Trash. Empty for `.managedByMacOS`.
    public let urls: [URL]
    /// Allocated bytes.
    public let bytes: UInt64
    public let safety: Safety
    /// One sentence: why it exists and what happens if it is removed.
    public let reason: String
    /// The app that owns it, so it can be skipped while that app runs.
    public let bundleID: String?

    public init(id: String, title: String, location: String, urls: [URL], bytes: UInt64, safety: Safety, reason: String, bundleID: String? = nil) {
        self.id = id
        self.title = title
        self.location = location
        self.urls = urls
        self.bytes = bytes
        self.safety = safety
        self.reason = reason
        self.bundleID = bundleID
    }
}
