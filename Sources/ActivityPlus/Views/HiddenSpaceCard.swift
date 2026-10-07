import ActivityCore
import AppKit
import SwiftUI

/// What takes space without showing up as an app or a file: snapshots and purgeable space.
/// Activity+ explains and points to the right setting; it never deletes snapshots itself.
struct HiddenSpaceCard: View {
    @State private var summary: HiddenSpace.Summary?

    var body: some View {
        Card {
            CardHeader(title: "Space you can't see in Finder", systemImage: "eye.slash", tint: .orange)
            if let summary {
                content(summary)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task {
            summary = await Task.detached(priority: .utility) { HiddenSpace.read() }.value
        }
    }

    @ViewBuilder private func content(_ s: HiddenSpace.Summary) -> some View {
        let timeMachine = s.snapshots.filter { $0.kind == .timeMachine }
        let updates = s.snapshots.filter { $0.kind == .macOSUpdate }
        let other = s.snapshots.filter { $0.kind == .other }

        StatLine(label: "Purgeable", value: Format.storage(s.purgeableBytes))
        Text("Space macOS frees by itself as soon as something needs it: caches, iCloud files that are also in the cloud, older snapshots. It counts as used in some places and as free in others, which is why numbers disagree.")
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

        Divider()
        if s.snapshots.isEmpty {
            Text("No snapshots on this volume.").font(.callout).foregroundStyle(.secondary)
        }
        if !timeMachine.isEmpty {
            let dates = timeMachine.compactMap(\.date).sorted()
            row(icon: "clock.arrow.circlepath", title: "\(timeMachine.count) local Time Machine \(timeMachine.count == 1 ? "snapshot" : "snapshots")",
                detail: (dates.first.map { "Oldest from \($0.formatted(date: .abbreviated, time: .shortened)). " } ?? "")
                    + "Time Machine keeps them while the backup disk is away and removes them after 24 hours or when space runs low.",
                button: "Time Machine Settings", url: "x-apple.systempreferences:com.apple.Time-Machine-Settings.extension")
        }
        if !updates.isEmpty {
            let prepared = updates.contains { $0.name.contains("MSUPrepareUpdate") }
            row(icon: "arrow.down.circle", title: "\(updates.count) macOS update \(updates.count == 1 ? "snapshot" : "snapshots")",
                detail: prepared
                    ? "One belongs to an update that is downloaded and prepared but not installed yet. It can take several GB until you install the update."
                    : "Left by macOS updates so the system can be restored. macOS removes them on its own.",
                button: "Software Update", url: "x-apple.systempreferences:com.apple.Software-Update-Settings.extension")
        }
        if !other.isEmpty {
            row(icon: "camera.on.rectangle", title: "\(other.count) other \(other.count == 1 ? "snapshot" : "snapshots")",
                detail: other.map(\.name).prefix(3).joined(separator: ", ") + ". Made by a backup app or by hand.", button: nil, url: nil)
        }
        Text("macOS does not reveal how much each snapshot takes.").font(.caption).foregroundStyle(.tertiary)
    }

    private func row(icon: String, title: String, detail: String, button: String?, url: String?) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(.orange).frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).fontWeight(.medium)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if let button, let url, let link = URL(string: url) {
                Button(button) { NSWorkspace.shared.open(link) }
            }
        }
    }
}
