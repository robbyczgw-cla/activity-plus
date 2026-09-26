import AppKit

/// Where Activity+ shows itself: menu bar, Dock, or both. Never neither, or it could not be reached.
enum AppPresence: String, CaseIterable, Identifiable {
    case both, menuBarOnly, dockOnly

    var id: String { rawValue }
    static let key = "appPresence"

    var title: String {
        switch self {
        case .both: "Menu bar and Dock"
        case .menuBarOnly: "Menu bar only"
        case .dockOnly: "Dock only"
        }
    }

    var showsDock: Bool { self != .menuBarOnly }
    var showsMenuBar: Bool { self != .dockOnly }

    static var current: AppPresence {
        let defaults = UserDefaults.standard
        if let raw = defaults.string(forKey: key), let value = AppPresence(rawValue: raw) { return value }
        // Before 0.2.4 there was only the "Show in Dock" switch.
        return defaults.object(forKey: "showDockIcon") as? Bool == false ? .menuBarOnly : .both
    }

    /// Applies the Dock part right away; the menu bar items follow via `MenuBarItemStore.changed`.
    @MainActor
    static func apply(_ presence: AppPresence = current) {
        NSApp.setActivationPolicy(presence.showsDock ? .regular : .accessory)
        NotificationCenter.default.post(name: MenuBarItemStore.changed, object: nil)
    }
}
