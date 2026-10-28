import ActivityCore
import AppKit
import SwiftUI

/// Shows iCloud Drive while it uploads, downloads or is stuck. When everything is in step it is not shown at all.
struct ICloudCard: View {
    @Environment(Monitor.self) private var monitor
    @State private var status: ICloudStatus?

    /// `brctl status` takes several seconds with many containers, so look again quickly only while iCloud's own
    /// processes are busy or a sync is under way; otherwise every 15 minutes is plenty.
    private var syncProcessesBusy: Bool {
        monitor.snapshot.apps.flatMap(\.processes)
            .filter { ["bird", "cloudd", "fileproviderd"].contains($0.name) }
            .reduce(0) { $0 + $1.cpuPercent } > 10
    }

    var body: some View {
        Group {
            if let status, status.needsAttention {
                card(status)
            }
        }
        .task {
            while !Task.isCancelled {
                status = await Task.detached(priority: .utility) { ICloudStatus.read() }.value
                let soon = syncProcessesBusy || status?.needsAttention == true
                try? await Task.sleep(for: .seconds(soon ? 60 : 900))
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
