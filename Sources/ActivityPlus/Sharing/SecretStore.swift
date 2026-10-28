import Foundation
import Security
import SystemConfiguration

/// Small secrets for sharing between Macs: the tokens this Mac uses to read other Macs, and the hashed tokens of
/// Macs that may read this one. They live in the login Keychain, never in the defaults (which Settings → Backup exports).
///
/// `ACTIVITYPLUS_SECRETS_DIR` points tests at a JSON file instead: an ad-hoc signed dev build changes its signature
/// with every build, and the Keychain would ask for the password each time.
enum SecretStore {
    static let viewersService = "at.hifiteam.activityplus.sharing"
    static let tokensService = "at.hifiteam.activityplus.remote"

    private static var fileURL: URL? {
        ProcessInfo.processInfo.environment["ACTIVITYPLUS_SECRETS_DIR"].map { URL(fileURLWithPath: $0).appendingPathComponent("secrets.json") }
    }

    static func read(service: String, account: String) -> Data? {
        if let fileURL {
            let all = (try? Data(contentsOf: fileURL)).flatMap { try? JSONDecoder().decode([String: Data].self, from: $0) } ?? [:]
            return all["\(service)/\(account)"]
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    @discardableResult
    static func write(_ data: Data?, service: String, account: String) -> Bool {
        if let fileURL {
            var all = (try? Data(contentsOf: fileURL)).flatMap { try? JSONDecoder().decode([String: Data].self, from: $0) } ?? [:]
            all["\(service)/\(account)"] = data
            try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            return (try? JSONEncoder().encode(all).write(to: fileURL, options: .atomic)) != nil
        }
        let match: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        guard let data else { return SecItemDelete(match as CFDictionary) == errSecSuccess }
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(match as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var add = match
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = "Activity+ sharing"
        // Readable after the first unlock, so sharing keeps working while the screen is locked.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
}

enum ThisMac {
    /// The name in System Settings → General → Sharing.
    static var computerName: String {
        (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? Host.current().localizedName ?? "Mac"
    }

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}
