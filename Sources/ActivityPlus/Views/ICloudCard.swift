import ActivityCore
import AppKit
import SwiftUI

/// Shows iCloud Drive while it uploads, downloads or is stuck. When everything is in step it is not shown at all.
struct ICloudCard: View {
    @State private var status: ICloudStatus?

    var body: some View {
        Group {
            if let status, status.needsAttention {
                card(status)
            }
        }
        .task {
            while !Task.isCancelled {
                status = await Task.detached(priority: .utility) { ICloudStatus.read() }.value
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    private func card(_ status: ICloudStatus) -> some View {
        let stuck = status.isStuck
        return Card {
            CardHeader(title: stuck ? String(localized: "iCloud sync is stuck") : String(localized: "iCloud is syncing"),
                       systemImage: "icloud", tint: stuck ? .orange : .blue)
            Text(message(status))
                .appFont(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Open iCloud settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.systempreferences.AppleIDSettings:icloud")!)
                }
                Spacer()
            }
        }
    }

    private func message(_ status: ICloudStatus) -> String {
        if status.isStuck {
            return String(localized: "\(status.stalledContainers) iCloud data areas report a sync error. macOS retries by itself. If this stays, check iCloud settings.")
        }
        if let items = status.itemsToUpload, items > 0 {
            return String(localized: "iCloud is still uploading \(items) items. This is why bird and cloudd use CPU and the disk.")
        }
        if let items = status.itemsToDownload, items > 0 {
            return String(localized: "iCloud is still downloading \(items) items. This is why bird and cloudd use CPU and the disk.")
        }
        return String(localized: "iCloud still has \(status.pendingContainers) data areas waiting to sync. This is why bird and cloudd use CPU and the disk.")
    }
}
