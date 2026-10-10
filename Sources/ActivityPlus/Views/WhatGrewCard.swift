import ActivityCore
import SwiftUI

/// Storage → Explore: the folders that grew or shrank the most since an earlier scan of the same root.
/// Shown once there are at least two scan summaries; a click opens that folder in Explore.
struct WhatGrewCard: View {
    let index: DiskIndex
    let summaries: [DiskGrowth.Summary]
    let open: (URL) -> Void
    /// Date of the older scan to compare with; nil = the one before the latest.
    @State private var compareDate: Date?

    var body: some View {
        if summaries.count >= 2, let latest = summaries.last {
            let older = Array(summaries.dropLast().reversed())
            let base = older.first { $0.date == compareDate } ?? older[0]
            let changes = DiskGrowth.changes(from: base, to: latest)
            let total = Int64(clamping: latest.totalBytes) - Int64(clamping: base.totalBytes)
            Card {
                HStack(alignment: .firstTextBaseline) {
                    Label {
                        Text("What grew since \(base.date, format: Self.dateFormat)")
                    } icon: {
                        Image(systemName: "chart.line.uptrend.xyaxis")
                    }
                    .font(.headline).foregroundStyle(.blue)
                    Spacer()
                    if older.count > 1 {
                        Picker("Compare with", selection: Binding(get: { base.date }, set: { compareDate = $0 })) {
                            ForEach(older, id: \.date) { summary in
                                Text(summary.date, format: Self.dateFormat).tag(summary.date)
                            }
                        }
                        .labelsHidden().pickerStyle(.menu).fixedSize()
                        .help("Compare with an older scan")
                    }
                }
                Text("In total \(Self.signed(total)), from \(Format.storage(base.totalBytes)) to \(Format.storage(latest.totalBytes)).")
                    .font(.callout).foregroundStyle(.secondary)
                if changes.isEmpty {
                    Text("No folder changed by more than 100 MB.").font(.callout).foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 0) {
                        ForEach(changes) { change in
                            row(change)
                            if change.id != changes.last?.id { Divider().opacity(0.4) }
                        }
                    }
                }
            }
        }
    }

    private static let dateFormat = Date.FormatStyle.dateTime.day().month(.abbreviated).year().hour().minute()

    private func row(_ change: DiskGrowth.Change) -> some View {
        let url = index.root.appendingPathComponent(change.path, isDirectory: true)
        let target = index.id(of: url).flatMap { index.node($0) }
        let canOpen = target?.isDirectory == true
        return HStack(spacing: 10) {
            Image(systemName: change.grew ? "arrow.up.right" : "arrow.down.right")
                .foregroundStyle(change.grew ? Color.orange : Color.green)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: change.path).lineLimit(1).truncationMode(.middle)
                Group {
                    if change.isGone {
                        Text("No longer there, or now under \(Format.storage(DiskGrowth.defaultMinBytes))")
                    } else if change.isNew {
                        Text("New, or was under \(Format.storage(DiskGrowth.defaultMinBytes))")
                    } else {
                        Text("\(Format.storage(change.oldBytes ?? 0)) → \(Format.storage(change.newBytes ?? 0))")
                    }
                }
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(verbatim: Self.signed(change.delta)).monospacedDigit()
                .foregroundStyle(change.grew ? Color.orange : Color.green)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                .opacity(canOpen ? 1 : 0)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onTapGesture { if canOpen { open(url) } }
        .help(canOpen ? String(localized: "Open this folder") : "")
    }

    static func signed(_ delta: Int64) -> String {
        (delta >= 0 ? "+" : "−") + Format.storage(delta.magnitude)
    }
}
