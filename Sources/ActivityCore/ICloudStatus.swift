import Foundation

/// iCloud Drive sync state as `brctl status` and `brctl quota` report it.
///
/// On current macOS `brctl status` lists one line per app data area ("container") with its sync state and
/// prints no item counts, so the counts of waiting items stay nil unless the output names them.
public struct ICloudStatus: Sendable, Equatable {
    public enum Health: String, Sendable, Equatable {
        /// iCloud Drive is switched off.
        case off
        /// No iCloud account is signed in.
        case notSignedIn
        /// Everything listed is in step.
        case idle
        /// Changes are waiting to upload or download.
        case syncing
        /// At least one data area reports a sync error.
        case stalled
        /// The output was empty or not understood.
        case unknown
    }

    public var health: Health = .unknown
    /// nil when the output does not say.
    public var driveOn: Bool?
    /// Data areas (containers) listed by `brctl status`.
    public var containers = 0
    /// Areas of apps that were uninstalled. Sync is disabled for them, so they never count as waiting.
    public var disabledContainers = 0
    /// Areas with changes waiting to upload or download.
    public var pendingContainers = 0
    /// Areas whose sync reports an error.
    public var stalledContainers = 0
    /// Items waiting to upload, only when the output prints a count.
    public var itemsToUpload: Int?
    /// Items waiting to download, only when the output prints a count.
    public var itemsToDownload: Int?
    /// Bytes of iCloud storage left (`brctl quota`).
    public var bytesRemaining: Int64?

    public init() {}

    public var isSyncing: Bool { health == .syncing }
    public var isStuck: Bool { health == .stalled }
    /// The card and the sync finding are only shown while something is syncing or stuck.
    public var needsAttention: Bool { health == .syncing || health == .stalled }

    // MARK: Reading

    /// Runs `brctl status` and `brctl quota` (both read-only). `brctl status` takes about 8 s with many iCloud
    /// areas, so its limit is 20 s: a run that is cut off would show a partial list, and that is reported as unknown.
    /// Blocking: call it off the main thread.
    public static func read() -> ICloudStatus {
        let status = ToolRunner.run("/usr/bin/brctl", ["status"], timeout: 20)
        guard status.succeeded else { return ICloudStatus() }
        let quota = ToolRunner.run("/usr/bin/brctl", ["quota"], timeout: 5)
        return parse(status: status.output, quota: quota.output)
    }

    // MARK: Parsing

    /// Active sync states; a data area in one of them has work waiting.
    static let activeStates: Set<String> = ["needs-sync", "uploading", "downloading", "syncing"]

    /// Parses the text of `brctl status` and `brctl quota`. Never fails: unreadable text gives `.unknown`.
    public static func parse(status: String, quota: String = "") -> ICloudStatus {
        var result = ICloudStatus()
        let text = stripANSI(status)
        var sawContainer = false

        for line in text.split(whereSeparator: \.isNewline).map(String.init) {
            if line.contains("{client:") {
                sawContainer = true
                result.containers += 1
                let clients = values(after: "client:", in: line)
                let sync = value(after: " sync:", in: line)
                if clients.contains("blocked-app-uninstalled") {
                    result.disabledContainers += 1
                } else if (clients + [sync]).contains(where: isError) {
                    result.stalledContainers += 1
                } else if (clients + [sync]).contains(where: { activeStates.contains($0) }) {
                    result.pendingContainers += 1
                }
                continue
            }
            // Item counts, if a future macOS prints them: "1 240 items waiting to upload".
            let lower = line.lowercased()
            if lower.contains("upload"), let count = itemCount(in: line) {
                result.itemsToUpload = (result.itemsToUpload ?? 0) + count
            } else if lower.contains("download"), let count = itemCount(in: line) {
                result.itemsToDownload = (result.itemsToDownload ?? 0) + count
            }
        }

        let lowered = text.lowercased()
        if sawContainer {
            result.driveOn = true
            if result.stalledContainers > 0 {
                result.health = .stalled
            } else if result.pendingContainers > 0 || (result.itemsToUpload ?? 0) > 0 || (result.itemsToDownload ?? 0) > 0 {
                result.health = .syncing
            } else {
                result.health = .idle
            }
        } else if ["not signed in", "signed out", "no icloud account", "not logged in"].contains(where: { lowered.contains($0) }) {
            result.health = .notSignedIn
        } else if lowered.contains("icloud drive") && ["turned off", "is off", "disabled"].contains(where: { lowered.contains($0) }) {
            result.driveOn = false
            result.health = .off
        }

        result.bytesRemaining = parseQuota(quota)
        return result
    }

    /// `brctl quota`: "89988765133 bytes of quota remaining in personal account".
    public static func parseQuota(_ text: String) -> Int64? {
        guard let match = firstMatch(#"(\d+)\s+bytes of quota remaining"#, in: stripANSI(text)) else { return nil }
        return Int64(match[1])
    }

    /// Removes terminal colour codes that `brctl` prints when it runs in a terminal.
    static func stripANSI(_ text: String) -> String {
        text.replacingOccurrences(of: #"\x{1B}\[[0-9;]*[A-Za-z]"#, with: "", options: .regularExpression)
    }

    /// The `|`-separated values after `key` (for example `client:needs-sync|blocked-app-uninstalled`).
    static func values(after key: String, in line: String) -> [String] {
        value(after: key, in: line).split(separator: "|").map(String.init)
    }

    /// The text after `key` up to the next space, comma or closing brace.
    static func value(after key: String, in line: String) -> String {
        guard let range = line.range(of: key) else { return "" }
        return String(line[range.upperBound...].prefix { $0 != " " && $0 != "," && $0 != "}" })
    }

    static func isError(_ state: String) -> Bool {
        let lower = state.lowercased()
        return lower.contains("error") || lower.contains("fail") || lower.contains("stall")
    }

    /// A count written before the word "item(s)", with digit groups separated by spaces, dots, commas or no-break spaces.
    static func itemCount(in line: String) -> Int? {
        guard let match = firstMatch(#"(\d[\d .,\x{00A0}\x{202F}]*)\s*items?\b"#, in: line) else { return nil }
        let digits = match[1].filter { $0.isASCII && $0.isNumber }
        return Int(digits)
    }

    private static func firstMatch(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (0..<match.numberOfRanges).map { index in
            Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
        }
    }
}
