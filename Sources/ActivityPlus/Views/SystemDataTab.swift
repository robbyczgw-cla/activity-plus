import ActivityCore
import AppKit
import SwiftUI

extension Notification.Name {
    /// Posted by the System Data tab; the Storage page answers by switching to its Clean up tab.
    static let storageShowCleanup = Notification.Name("storageShowCleanup")
}

/// Holds the measurement so it survives tab switches while the app runs. Measuring happens off the
/// main thread; nothing is changed on disk.
@MainActor @Observable
final class SystemDataModel {
    static let shared = SystemDataModel()

    private(set) var groups: [SystemDataBreakdown.Group]?
    private(set) var measuring = false
    private(set) var progress = 0.0
    private(set) var current = ""
    private(set) var measuredAt: Date?

    private let cancelFlag = CancelFlag()

    final class CancelFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
        func set(_ newValue: Bool) { lock.lock(); value = newValue; lock.unlock() }
    }

    func start() {
        guard !measuring else { return }
        measuring = true
        progress = 0
        current = ""
        cancelFlag.set(false)
        let flag = cancelFlag
        Task.detached(priority: .userInitiated) {
            let result = SystemDataBreakdown.measure(
                isCancelled: { flag.isSet },
                progress: { fraction, name in
                    Task { @MainActor in
                        let model = SystemDataModel.shared
                        if model.measuring { model.progress = fraction; model.current = name }
                    }
                })
            await MainActor.run {
                let model = SystemDataModel.shared
                if !flag.isSet {
                    model.groups = result
                    model.measuredAt = Date()
                }
                model.measuring = false
            }
        }
    }

    func stop() { cancelFlag.set(true) }
}

struct SystemDataTab: View {
    @Environment(\.density) private var density
    @State private var model = SystemDataModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: density.stack) {
            overviewCard
            if let groups = model.groups {
                ForEach(groups) { GroupCard(group: $0) }
            }
            HiddenSpaceCard()
        }
        .onAppear {
            if ProcessInfo.processInfo.environment["ACTIVITYPLUS_SNAPSHOTS"] != nil, model.groups == nil { model.start() }
        }
    }

    private var overviewCard: some View {
        Card {
            HStack {
                CardHeader(title: "What is in System Data", systemImage: "internaldrive", tint: .indigo)
                if model.measuring {
                    Button("Stop") { model.stop() }
                } else {
                    Button(model.groups == nil ? "Measure" : "Measure again") { model.start() }
                }
            }
            Text("macOS shows one grey bar called System Data. This names its parts and says which ones are safe to clear. Activity+ only measures here and changes nothing.")
                .appFont(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            if model.measuring {
                ProgressView(value: model.progress)
                Text(verbatim: model.current).appFont(.caption).foregroundStyle(.tertiary).lineLimit(1)
            }

            if let groups = model.groups {
                if groups.isEmpty {
                    Text("Nothing found in the usual places.").appFont(.callout).foregroundStyle(.secondary)
                } else {
                    StackedBar(groups: groups)
                    ForEach(groups) { group in
                        StatLine(label: group.title, value: Format.storage(group.distinctBytes), tint: GroupStyle.tint(group.id))
                    }
                    Divider()
                    totals(groups)
                    if let at = model.measuredAt {
                        Text("Measured \(at.formatted(date: .omitted, time: .shortened)). Sizes are space actually used on disk.")
                            .appFont(.caption).foregroundStyle(.tertiary)
                    }
                }
            } else if !model.measuring {
                Text("Measuring walks a few folders and takes a few seconds, longer if Xcode simulators or big caches are present.")
                    .appFont(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder private func totals(_ groups: [SystemDataBreakdown.Group]) -> some View {
        StatLine(label: "Safe to clear", value: Format.storage(sum(.safeToClear, groups)), tint: .green)
        StatLine(label: "Look first", value: Format.storage(sum(.lookFirst, groups)), tint: .orange)
        StatLine(label: "Managed by macOS", value: Format.storage(sum(.managedByMacOS, groups)), tint: .gray)
    }

    private func sum(_ safety: Safety, _ groups: [SystemDataBreakdown.Group]) -> UInt64 {
        groups.filter { $0.safety == safety }.reduce(0) { $0 + $1.distinctBytes }
    }
}

enum GroupStyle {
    static func tint(_ id: String) -> Color {
        switch id {
        case "developer": .indigo
        case "caches": .blue
        case "logs": .teal
        case "backups": .pink
        default: .gray
        }
    }

    static func icon(_ id: String) -> String {
        switch id {
        case "developer": "hammer"
        case "caches": "tray.full"
        case "logs": "doc.text"
        case "backups": "externaldrive.badge.timemachine"
        default: "gearshape.2"
        }
    }

    static func badge(_ safety: Safety) -> (text: LocalizedStringKey, tint: Color) {
        switch safety {
        case .safeToClear: ("Safe to clear", .green)
        case .lookFirst: ("Look first", .orange)
        case .managedByMacOS: ("Managed by macOS", .gray)
        }
    }
}

/// One horizontal bar split by each group's share.
private struct StackedBar: View {
    let groups: [SystemDataBreakdown.Group]

    var body: some View {
        let total = max(1, groups.reduce(UInt64(0)) { $0 + $1.distinctBytes })
        GeometryReader { proxy in
            HStack(spacing: 2) {
                ForEach(groups.filter { $0.distinctBytes > 0 }) { group in
                    let width = proxy.size.width * Double(group.distinctBytes) / Double(total)
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(GroupStyle.tint(group.id).gradient)
                        .frame(width: max(3, width - 2))
                        .help(Text(verbatim: "\(group.title): \(Format.storage(group.distinctBytes))"))
                }
            }
        }
        .frame(height: 14)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("System Data by group")
    }
}

private struct GroupCard: View {
    let group: SystemDataBreakdown.Group

    var body: some View {
        let badge = GroupStyle.badge(group.safety)
        let tint = GroupStyle.tint(group.id)
        Card {
            CardHeader(title: group.title, systemImage: GroupStyle.icon(group.id), tint: tint,
                       trailing: Format.storage(group.distinctBytes))
            HStack(spacing: 8) {
                Text(badge.text)
                    .appFont(.caption, weight: .semibold)
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .foregroundStyle(badge.tint)
                    .background(badge.tint.opacity(0.15), in: Capsule())
                Text(blurb).appFont(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            ForEach(Array(group.items.enumerated()), id: \.element.id) { index, item in
                if index > 0 { Divider() }
                ItemRow(item: item, groupBytes: max(1, group.distinctBytes), tint: tint)
            }
            if group.safety != .managedByMacOS {
                HStack {
                    Spacer()
                    Button("Review in Clean up") { NotificationCenter.default.post(name: .storageShowCleanup, object: nil) }
                }
            }
        }
    }

    private var blurb: LocalizedStringKey {
        switch group.safety {
        case .safeToClear: "Apps and tools rebuild these when needed."
        case .lookFirst: "Removable, but may hold something you want."
        case .managedByMacOS: "Shown for understanding only. macOS manages these itself."
        }
    }
}

private struct ItemRow: View {
    let item: ReclaimableItem
    let groupBytes: UInt64
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: item.title).fontWeight(.medium)
                Spacer()
                if item.bytes > 0 {
                    Text(Format.storage(item.bytes)).monospacedDigit().fontWeight(.medium)
                } else {
                    Text("Size not reported").appFont(.caption).foregroundStyle(.tertiary)
                }
            }
            if item.bytes > 0 && item.id != SystemDataBreakdown.purgeableID {
                UsageBar(fraction: Double(item.bytes) / Double(groupBytes), tint: tint)
            }
            Text(item.reason).appFont(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text(verbatim: item.location).appFont(.caption, monospaced: true).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                if let url = revealTarget {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        .buttonStyle(.link).appFont(.caption)
                }
            }
        }
    }

    /// The item itself, or its folder when it spans several (Other caches); nil when there is nothing to show.
    private var revealTarget: URL? {
        if item.urls.count == 1 { return item.urls[0] }
        let path = (item.location as NSString).expandingTildeInPath
        guard path.hasPrefix("/"), FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }
}
