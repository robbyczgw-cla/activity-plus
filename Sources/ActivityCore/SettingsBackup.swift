import Foundation

/// Settings as a portable file: menu bar, panel, alert rules, automations, performance switches.
/// Only Activity+'s own keys: no window positions, update state or anything macOS keeps for the app.
public enum SettingsBackup {
    public static let format = "Activity+ settings"
    static let excludedPrefixes = ["NS", "SU", "Apple", "com.apple", "WebKit", "AppleLanguages"]
    static let excludedKeys: Set<String> = ["settingsTab", "menuBarPanelTab", "insightNotified", "sidebarSelection"]

    public static func isPortable(_ key: String) -> Bool {
        !excludedKeys.contains(key) && !excludedPrefixes.contains { key.hasPrefix($0) }
    }

    public static func export(_ domain: [String: Any], at date: Date = Date()) throws -> Data {
        let settings = domain.filter { isPortable($0.key) }
        let payload: [String: Any] = ["format": format, "version": 1, "exported": date, "settings": settings]
        return try PropertyListSerialization.data(fromPropertyList: payload, format: .xml, options: 0)
    }

    public enum Failure: LocalizedError {
        case notActivityPlus
        public var errorDescription: String? { "This file is not an Activity+ settings export." }
    }

    /// The portable settings in the file, ready to write into the defaults.
    public static func settings(from data: Data) throws -> [String: Any] {
        guard let payload = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              payload["format"] as? String == format,
              let settings = payload["settings"] as? [String: Any]
        else { throw Failure.notActivityPlus }
        return settings.filter { isPortable($0.key) }
    }
}
