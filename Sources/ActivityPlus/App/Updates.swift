import Sparkle
import SwiftUI

/// Sparkle auto-updates. Checks once a day (can be turned off in Settings); the feed and downloads
/// come from GitHub releases and every update is verified with our EdDSA key before installing.
@MainActor
final class Updates: ObservableObject {
    static let shared = Updates()
    let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    var updater: SPUUpdater { controller.updater }

    /// Builds made with scripts/build-app.sh (ad-hoc, no feed signature) should not try to update themselves.
    var isAvailable: Bool {
        Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") != nil
    }

    func checkForUpdates() { controller.checkForUpdates(nil) }
}

struct CheckForUpdatesButton: View {
    @ObservedObject private var updates = Updates.shared
    @State private var canCheck = true

    var body: some View {
        Button("Check for Updates…") { updates.checkForUpdates() }
            .disabled(!canCheck)
            .onReceive(updates.updater.publisher(for: \.canCheckForUpdates)) { canCheck = $0 }
    }
}
