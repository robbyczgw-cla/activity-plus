import ActivityCore
import SwiftUI

@main
struct ActivityPlusApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private let monitor = Monitor.shared

    var body: some Scene {
        Window("Activity+", id: "main") {
            ContentView()
                .environment(monitor)
                .environment(AppServices.shared)
        }
        .defaultSize(width: 1080, height: 720)
        .commands {
            CommandGroup(after: .appInfo) { CheckForUpdatesButton() }
        }


        Settings {
            SettingsView().environment(monitor).environment(AppServices.shared)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let showDock = UserDefaults.standard.object(forKey: "showDockIcon") as? Bool ?? true
        NSApp.setActivationPolicy(showDock ? .regular : .accessory)
        MainActor.assumeIsolated {
            UnitPreferences.apply()
            _ = Updates.shared
            AppServices.shared.attach(to: Monitor.shared)
            HelperClient.shared.attach(to: Monitor.shared)
            Monitor.shared.start()
            StatusItemsController.shared.start()
            SnapshotRunner.runIfRequested()
            // Started at login (or asked not to): stay in the menu bar only.
            let hidden = ProcessInfo.processInfo.environment["ACTIVITYPLUS_HIDDEN"] != nil
                || (UserDefaults.standard.object(forKey: "openWindowAtLaunch") as? Bool == false)
            if hidden {
                // Ordered out, not closed: the window (and SwiftUI's open-window action) stays available.
                DispatchQueue.main.async { NSApp.windows.first { $0.title == "Activity+" }?.orderOut(nil) }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            AppServices.shared.history.flush()
            AppServices.shared.volumeController.stopAll()
        }
    }

    /// Closing the window keeps Activity+ running in the menu bar.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
