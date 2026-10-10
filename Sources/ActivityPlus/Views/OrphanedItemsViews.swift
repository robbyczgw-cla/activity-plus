import ActivityCore
import AppKit
import SwiftUI

/// One line on top of Startup Items: how many entries point to programs that are gone.
struct OrphanSummaryCard: View {
    let items: [StartupItem]

    var body: some View {
        let orphans = items.filter { $0.orphan != nil }
        if !orphans.isEmpty {
            Card {
                CardHeader(title: "Leftovers of deleted apps", systemImage: "trash.slash", tint: .orange)
                Text("\(orphans.count) items start a program that does not exist any more. They do nothing, and are marked below. Items in your own folder can be moved to the Trash here; system-wide ones need an administrator.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Under a row: why the item is marked, and what can be done about it.
struct OrphanNote: View {
    let item: StartupItem
    let trash: (StartupItem) -> Void

    var body: some View {
        if let orphan = item.orphan {
            VStack(alignment: .leading, spacing: 4) {
                Label(orphan.badge, systemImage: "exclamationmark.triangle.fill").appFont(.caption, weight: .semibold).foregroundStyle(.orange)
                Text(orphan.explanation).appFont(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    if OrphanedItems.canRemove(item) {
                        Button("Move to Trash…") { trash(item) }.controlSize(.small)
                    } else {
                        Text("Removing it needs an administrator.").appFont(.caption).foregroundStyle(.secondary)
                    }
                    if let plist = item.plistPath {
                        Button("Show in Finder") { ProcessActions.reveal(plist) }.controlSize(.small)
                    }
                }
            }
            .padding(.top, 2)
        }
    }
}

extension View {
    /// The confirmation before an orphaned launch agent is moved to the Trash and unloaded. Nothing happens without it.
    func orphanTrashDialog(_ item: Binding<StartupItem?>, finished: @escaping (String?) -> Void) -> some View {
        confirmationDialog("Move \(item.wrappedValue?.label ?? "") to the Trash?", isPresented: Binding(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } }),
                           presenting: item.wrappedValue) { entry in
            Button("Move to Trash", role: .destructive) {
                do {
                    try OrphanedItems.trash(entry)
                    finished(nil)
                } catch {
                    finished(error.localizedDescription)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { entry in
            Text("The file \((entry.plistPath as NSString?)?.lastPathComponent ?? "") moves to the Trash and the item is stopped in your session. \(entry.orphan?.missingPath ?? "") does not exist, so nothing is lost. You can put the file back from the Trash.")
        }
    }
}
