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

        MenuBarExtra {
            MenuBarPanel().environment(monitor).environment(AppServices.shared)
        } label: {
            MenuBarLabel().environment(monitor)
        }
        .menuBarExtraStyle(.window)

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
            AppServices.shared.attach(to: Monitor.shared)
            Monitor.shared.start()
            SnapshotRunner.runIfRequested()
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
