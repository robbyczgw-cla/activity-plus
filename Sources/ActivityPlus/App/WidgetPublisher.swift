import ActivityCore
import AppKit
import Security
import WidgetData
import WidgetKit

/// Feeds the desktop / Notification Center widgets: about once a minute it writes a small snapshot into
/// the App Group container, and every few minutes it asks WidgetKit to reload. With no widget placed it
/// writes nothing (WidgetKit is asked every few minutes whether one appeared).
@MainActor
final class WidgetPublisher {
    static let shared = WidgetPublisher()

    private var schedule = WidgetPublishSchedule()
    /// nil when this build may not use the App Group (ad-hoc builds): touching another team's group
    /// container would make macOS ask the user for access to other apps' data.
    private let fileURL: URL?
    private var icons: [String: Data] = [:]

    private init() {
        fileURL = Self.mayUseAppGroup ? WidgetStore.fileURL() : nil
    }

    func attach(to monitor: Monitor) {
        guard fileURL != nil else { return }
        monitor.observers.append { [weak self] snapshot in
            MainActor.assumeIsolated { self?.handle(snapshot) }
        }
    }

    private func handle(_ snapshot: SystemSnapshot) {
        guard let url = fileURL else { return }
        let decision = schedule.decide(at: snapshot.date)
        if decision.checkWidgets { checkWidgets() }
        guard decision.write else { return }
        let widgetSnapshot = WidgetSnapshot(snapshot, icon: iconPNG)
        let reload = decision.reload
        Task.detached(priority: .utility) {
            do {
                try WidgetStore.write(widgetSnapshot, to: url)
                if reload { WidgetCenter.shared.reloadAllTimelines() }
            } catch {
                NSLog("Widget snapshot not written: %@", error.localizedDescription)
            }
        }
    }

    private func checkWidgets() {
        WidgetCenter.shared.getCurrentConfigurations { result in
            // An error (extension not registered yet) leaves the last answer in place.
            guard case let .success(widgets) = result else { return }
            let found = !widgets.isEmpty
            DispatchQueue.main.async {
                MainActor.assumeIsolated { WidgetPublisher.shared.schedule.widgetsFound(found) }
            }
        }
    }

    /// A 64 px PNG of the app's icon, made once per app.
    func iconPNG(_ app: AppGroup) -> Data? {
        guard app.bundlePath != nil else { return nil }
        if let cached = icons[app.id] { return cached }
        let image = IconCache.icon(for: app)
        let pixels = 64
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        rep.size = NSSize(width: 32, height: 32)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: 32, height: 32))
        NSGraphicsContext.restoreGraphicsState()
        let png = rep.representation(using: .png, properties: [:])
        icons[app.id] = png
        return png
    }

    /// Signed by the team the App Group belongs to, and entitled to it (release and SIGN_IDENTITY builds).
    static var mayUseAppGroup: Bool {
        guard let task = SecTaskCreateFromSelf(nil),
              let groups = SecTaskCopyValueForEntitlement(task, "com.apple.security.application-groups" as CFString, nil) as? [String],
              groups.contains(WidgetStore.appGroup),
              let team = teamIdentifier
        else { return false }
        return WidgetStore.appGroup.hasPrefix(team + ".")
    }

    private static var teamIdentifier: String? {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let info = info as? [String: Any]
        else { return nil }
        return info[kSecCodeInfoTeamIdentifier as String] as? String
    }
}
