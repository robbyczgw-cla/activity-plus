import Foundation

/// One of the four switches that keep a Mac safe, read from the system's own tools.
public struct SecurityCheck: Sendable, Identifiable, Equatable {
    public enum Kind: String, Sendable { case fileVault, sip, gatekeeper, firewall }
    public enum Level: Sendable { case good, warning, unknown }
    public let kind: Kind
    public let level: Level
    /// Short state, e.g. "On".
    public let state: String
    /// One plain sentence about what it means.
    public let detail: String
    public var id: Kind { kind }
    public var title: String {
        switch kind {
        case .fileVault: String(localized: "FileVault")
        case .sip: String(localized: "System Integrity Protection")
        case .gatekeeper: String(localized: "Gatekeeper")
        case .firewall: String(localized: "Firewall")
        }
    }
    public init(kind: Kind, level: Level, state: String, detail: String) {
        (self.kind, self.level, self.state, self.detail) = (kind, level, state, detail)
    }
}

public enum SecurityStatus {
    /// `fdesetup status`: "FileVault is On.", "FileVault is Off.", "Encryption in progress: Percent completed = 12".
    public static func parseFileVault(_ text: String) -> SecurityCheck {
        let lower = text.lowercased()
        if lower.contains("encryption in progress") {
            return SecurityCheck(kind: .fileVault, level: .warning, state: String(localized: "Encrypting"),
                                 detail: String(localized: "The disk is being encrypted. It is protected once this finishes."))
        }
        if lower.contains("decryption in progress") {
            return SecurityCheck(kind: .fileVault, level: .warning, state: String(localized: "Decrypting"),
                                 detail: String(localized: "FileVault is being turned off and the disk is being decrypted."))
        }
        if lower.contains("filevault is on") {
            return SecurityCheck(kind: .fileVault, level: .good, state: String(localized: "On"),
                                 detail: String(localized: "Everything on the disk is encrypted. A lost or stolen Mac stays private."))
        }
        if lower.contains("filevault is off") {
            return SecurityCheck(kind: .fileVault, level: .warning, state: String(localized: "Off"),
                                 detail: String(localized: "Anyone holding this Mac can read the disk. Turn it on in System Settings, Privacy & Security."))
        }
        return unknown(.fileVault)
    }

    /// `csrutil status`: "System Integrity Protection status: enabled." / "disabled." / "enabled (Custom Configuration)."
    public static func parseSIP(_ text: String) -> SecurityCheck {
        let lower = text.lowercased()
        guard lower.contains("status:") else { return unknown(.sip) }
        if lower.contains("custom configuration") || lower.contains("unknown") {
            return SecurityCheck(kind: .sip, level: .warning, state: String(localized: "Partly off"),
                                 detail: String(localized: "Some system protections have been switched off by hand."))
        }
        if lower.contains("status: enabled") {
            return SecurityCheck(kind: .sip, level: .good, state: String(localized: "On"),
                                 detail: String(localized: "macOS system files are protected from changes, even by apps with admin rights."))
        }
        if lower.contains("status: disabled") {
            return SecurityCheck(kind: .sip, level: .warning, state: String(localized: "Off"),
                                 detail: String(localized: "System files can be changed by any app with admin rights. Turn it back on from Recovery."))
        }
        return unknown(.sip)
    }

    /// `spctl --status`: "assessments enabled" / "assessments disabled".
    public static func parseGatekeeper(_ text: String) -> SecurityCheck {
        let lower = text.lowercased()
        if lower.contains("assessments enabled") {
            return SecurityCheck(kind: .gatekeeper, level: .good, state: String(localized: "On"),
                                 detail: String(localized: "Downloaded apps are checked before they open for the first time."))
        }
        if lower.contains("assessments disabled") {
            return SecurityCheck(kind: .gatekeeper, level: .warning, state: String(localized: "Off"),
                                 detail: String(localized: "Any app can open without being checked first."))
        }
        return unknown(.gatekeeper)
    }

    /// `socketfilterfw --getglobalstate`: "Firewall is enabled. (State = 1)"; state 2 blocks all incoming connections.
    public static func parseFirewall(_ text: String) -> SecurityCheck {
        let lower = text.lowercased()
        if lower.contains("state = 0") || lower.contains("firewall is disabled") {
            return SecurityCheck(kind: .firewall, level: .warning, state: String(localized: "Off"),
                                 detail: String(localized: "Apps can accept connections from the network without asking. Turn it on in System Settings, Network."))
        }
        if lower.contains("state = 2") {
            return SecurityCheck(kind: .firewall, level: .good, state: String(localized: "Blocking all"),
                                 detail: String(localized: "All incoming connections are blocked, except for basic system services."))
        }
        if lower.contains("state = 1") || lower.contains("firewall is enabled") {
            return SecurityCheck(kind: .firewall, level: .good, state: String(localized: "On"),
                                 detail: String(localized: "Incoming connections are limited to apps you allowed."))
        }
        return unknown(.firewall)
    }

    private static func unknown(_ kind: SecurityCheck.Kind) -> SecurityCheck {
        SecurityCheck(kind: kind, level: .unknown, state: String(localized: "Unknown"),
                      detail: String(localized: "macOS did not answer."))
    }

    /// Runs the four tools (a fraction of a second in total); call off the main thread.
    public static func read() -> [SecurityCheck] {
        [parseFileVault(ToolRunner.run("/usr/bin/fdesetup", ["status"]).output),
         parseSIP(ToolRunner.run("/usr/bin/csrutil", ["status"]).output),
         parseGatekeeper(ToolRunner.run("/usr/sbin/spctl", ["--status"]).output),
         parseFirewall(ToolRunner.run("/usr/libexec/ApplicationFirewall/socketfilterfw", ["--getglobalstate"]).output)]
    }
}
