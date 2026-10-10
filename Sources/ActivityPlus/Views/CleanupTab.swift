import ActivityCore
import AppKit
import SwiftUI

/// Cancels the gathering from any thread, including the large-files scan that is running.
private final class GatherCancel: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    private var scanner: LargeFilesScanner?

    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    func attach(_ scanner: LargeFilesScanner) { lock.lock(); self.scanner = scanner; let stop = flag; lock.unlock(); if stop { scanner.cancel() } }
    func cancel() { lock.lock(); flag = true; let scanner = scanner; lock.unlock(); scanner?.cancel() }
}

/// What the Clean up tab found. Lives as long as the app, so the result stays when the user switches tabs.
@MainActor @Observable
final class CleanupModel {
    static let shared = CleanupModel()

    struct Summary {
        var freed: UInt64
        var count: Int
        var failures: [CleanupTrashOutcome.Failure]
        var skipped: [String]
    }

    private(set) var entries: [CleanupEntry] = []
    private(set) var running: Set<String> = []
    private(set) var progress: (fraction: Double, item: String)?
    private(set) var hasGathered = false
    private(set) var isTrashing = false
    private(set) var summary: Summary?
    var selected: Set<String> = []

    @ObservationIgnored private var systemEntries: [CleanupEntry] = []
    @ObservationIgnored private var largeEntries: [CleanupEntry] = []
    @ObservationIgnored private var known: Set<String> = []
    @ObservationIgnored private var cancel: GatherCancel?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    private init() {
        refreshRunning()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshRunning() }
            })
        }
    }

    nonisolated static func currentRunningBundleIDs() -> Set<String> {
        func read() -> Set<String> { Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)) }
        if Thread.isMainThread { return read() }
        return DispatchQueue.main.sync { read() }
    }

    func refreshRunning() {
        let now = Self.currentRunningBundleIDs()
        guard now != running else { return }
        running = now
        selected = selected.filter { id in
            guard let entry = entries.first(where: { $0.id == id }) else { return false }
            return !CleanupPlan.isBlocked(entry, running: now)
        }
    }

    func isBlocked(_ entry: CleanupEntry) -> Bool { CleanupPlan.isBlocked(entry, running: running) }

    // MARK: Gathering

    func gather(appStorage: [AppDiskUsage]) {
        guard progress == nil else { return }
        summary = nil
        let cancel = GatherCancel()
        self.cancel = cancel
        progress = (0, "")
        // With Explore's map of the home folder the large files come from memory in a moment; without it the
        // folders are walked again. That walk reads Downloads, Desktop and Documents, so snapshot runs skip it.
        let diskIndex = AppServices.shared.diskIndex
        let map = diskIndex.isCustomRoot ? nil : diskIndex.index
        let skipLarge = map == nil && SnapshotRunner.isActive
        Task.detached(priority: .utility) {
            let groups = SystemDataBreakdown.measure(isCancelled: { cancel.isCancelled }, progress: { fraction, item in
                Task { @MainActor in CleanupModel.shared.report(fraction * 0.55, item) }
            })
            let system = CleanupPlan.entries(from: groups) + CleanupPlan.macOSInstallers()
            let large: [CleanupEntry]
            if !skipLarge, !cancel.isCancelled {
                let scanner = LargeFilesScanner()
                cancel.attach(scanner)
                let report: @Sendable (Double, String) -> Void = { fraction, item in
                    Task { @MainActor in CleanupModel.shared.report(0.55 + fraction * 0.45, item) }
                }
                let found = map.map { scanner.scan(index: $0, progress: report) } ?? scanner.scan(progress: report)
                large = CleanupPlan.entries(from: found)
            } else {
                large = []
            }
            await MainActor.run {
                let model = CleanupModel.shared
                model.systemEntries = system
                model.largeEntries = large
                model.progress = nil
                model.hasGathered = true
                model.rebuild(appStorage: AppServices.shared.storage)
            }
        }
    }

    func stop() { cancel?.cancel() }

    private func report(_ fraction: Double, _ item: String) {
        if progress != nil { progress = (min(0.99, fraction), item) }
    }

    /// Merges the three sources. Entries seen for the first time get their default tick.
    func rebuild(appStorage: [AppDiskUsage]) {
        let apps = CleanupPlan.entries(fromApps: appStorage)
        let fileManager = FileManager.default
        let merged = CleanupPlan.merge(systemEntries + apps + largeEntries).filter { entry in
            entry.item.urls.contains { (try? fileManager.attributesOfItem(atPath: $0.path)) != nil }
        }
        entries = merged
        let ids = Set(merged.map(\.id))
        let fresh = merged.filter { !known.contains($0.id) }
        known.formUnion(ids)
        selected = selected.intersection(ids)
        selected.formUnion(CleanupPlan.defaultSelection(fresh, running: running))
    }

    // MARK: Totals

    var tickedEntries: [CleanupEntry] { entries.filter { selected.contains($0.id) && !isBlocked($0) } }
    var tickedBytes: UInt64 { tickedEntries.reduce(0) { $0 + $1.item.bytes } }

    func toggle(_ entry: CleanupEntry, on: Bool) {
        guard !isBlocked(entry) else { return }
        if on { selected.insert(entry.id) } else { selected.remove(entry.id) }
    }

    func setAll(_ section: CleanupSection, on: Bool) {
        for entry in entries where entry.section == section && !isBlocked(entry) {
            if on { selected.insert(entry.id) } else { selected.remove(entry.id) }
        }
    }

    // MARK: Trash

    func moveTickedToTrash() {
        let chosen = tickedEntries
        guard !chosen.isEmpty, !isTrashing else { return }
        isTrashing = true
        Task.detached(priority: .userInitiated) {
            // Only FileManager.trashItem, and each entry re-checks that its app is not running.
            let outcome = CleanupPlan.trash(chosen, runningBundleIDs: { CleanupModel.currentRunningBundleIDs() })
            await MainActor.run {
                let model = CleanupModel.shared
                model.isTrashing = false
                model.summary = Summary(freed: outcome.freed, count: outcome.movedIDs.count,
                                        failures: outcome.failures, skipped: outcome.skippedRunning)
                AppServices.shared.didTrash(outcome.movedPaths)
                model.rebuild(appStorage: AppServices.shared.storage)
            }
        }
    }

    func dismissSummary() { summary = nil }
}

struct CleanupTab: View {
    @Environment(\.density) private var density
    @Environment(AppServices.self) private var services
    @State private var model = CleanupModel.shared
    @State private var confirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: density.stack) {
            controls
            if let summary = model.summary { summaryCard(summary) }
            if model.hasGathered && model.entries.isEmpty && model.progress == nil {
                Card { Text("Nothing to clean up right now.").foregroundStyle(.secondary) }
            }
            ForEach(CleanupSection.allCases, id: \.self) { section in
                let items = model.entries.filter { $0.section == section }
                if !items.isEmpty { sectionCard(section, items) }
            }
            if services.storageScannedAt == nil && model.hasGathered { appScanHint }
            if !model.entries.isEmpty { footer }
        }
        .onAppear {
            model.refreshRunning()
            model.rebuild(appStorage: services.storage)
            if SnapshotRunner.isActive, !model.hasGathered, model.progress == nil {
                if services.storage.isEmpty { services.scanStorage() }
                model.gather(appStorage: services.storage)
            }
        }
        .onChange(of: services.storage) { _, storage in model.rebuild(appStorage: storage) }
        .confirmationDialog("Move \(model.tickedEntries.count) items to the Trash?", isPresented: $confirm) {
            Button("Move to Trash", role: .destructive) { model.moveTickedToTrash() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(Format.storage(model.tickedBytes)) in \(model.tickedEntries.count) items move to the Trash. The space is only freed when you empty the Trash. Items of apps that are open are left alone.")
        }
    }

    // MARK: Pieces

    private var controls: some View {
        Card {
            HStack(alignment: .top) {
                CardHeader(title: "Clean up", systemImage: "sparkles", tint: .green)
                Spacer()
                if let progress = model.progress {
                    ProgressView(value: progress.fraction).frame(width: 160)
                    Button("Stop") { model.stop() }
                } else {
                    Button(model.hasGathered ? "Look again" : "Find things to clean up") {
                        model.gather(appStorage: services.storage)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            if let progress = model.progress {
                Text(progress.item.isEmpty ? String(localized: "Looking…") : progress.item)
                    .appFont(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            } else if model.hasGathered {
                let total = model.entries.reduce(UInt64(0)) { $0 + $1.item.bytes }
                Text("\(model.entries.count) things found, \(Format.storage(total)) in all. \(Format.storage(model.tickedBytes)) is ticked.")
                    .appFont(.callout).foregroundStyle(.secondary)
            } else {
                Text("Caches, logs and leftovers that can go to the Trash, each with the reason. Safe items are ticked; items that need a look first are not. Apps that are open are left alone. Nothing moves until you confirm.")
                    .appFont(.callout).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var appScanHint: some View {
        Card {
            HStack {
                Text("Caches of your apps are only listed after the app scan.").appFont(.callout).foregroundStyle(.secondary)
                Spacer()
                if let progress = services.storageProgress {
                    ProgressView(value: progress.fraction).frame(width: 140)
                    Button("Stop") { services.cancelStorageScan() }
                } else {
                    Button("Scan apps") { services.scanStorage() }
                }
            }
        }
    }

    private func sectionCard(_ section: CleanupSection, _ items: [CleanupEntry]) -> some View {
        let selectable = items.filter { !model.isBlocked($0) }
        let ticked = selectable.filter { model.selected.contains($0.id) }.count
        let state: String = ticked == 0 ? "square" : (ticked == selectable.count ? "checkmark.square.fill" : "minus.square.fill")
        return Card {
            HStack(spacing: 8) {
                Button {
                    model.setAll(section, on: ticked != selectable.count)
                } label: {
                    Image(systemName: state).appFont(.title3)
                        .foregroundStyle(ticked == 0 ? Color.secondary : Color.accentColor)
                }
                .buttonStyle(.plain)
                .disabled(selectable.isEmpty)
                .help("Tick or untick everything in this group")
                Label(section.title, systemImage: section.systemImage).appFont(.headline)
                Spacer()
                Text(Format.storage(items.reduce(0) { $0 + $1.item.bytes })).monospacedDigit().foregroundStyle(.secondary)
            }
            ForEach(items) { entry in
                Divider().opacity(0.4)
                CleanupRow(entry: entry, model: model)
            }
        }
    }

    private var footer: some View {
        HStack {
            Text("\(model.tickedEntries.count) of \(model.entries.count) ticked")
                .appFont(.callout).foregroundStyle(.secondary)
            Spacer()
            Button("Move \(Format.storage(model.tickedBytes)) to Trash…") { confirm = true }
                .buttonStyle(.borderedProminent)
                .disabled(model.tickedEntries.isEmpty || model.isTrashing)
        }
    }

    private func summaryCard(_ summary: CleanupModel.Summary) -> some View {
        Card {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Moved \(Format.storage(summary.freed)) in \(summary.count) items to the Trash. Empty the Trash to free the space.",
                          systemImage: "trash")
                        .foregroundStyle(.green)
                    if !summary.skipped.isEmpty {
                        Text("Left alone because the app is open: \(summary.skipped.joined(separator: ", "))")
                            .appFont(.callout).foregroundStyle(.orange)
                    }
                    if !summary.failures.isEmpty {
                        Text("Could not be moved:").appFont(.callout).foregroundStyle(.red)
                        ForEach(Array(summary.failures.enumerated()), id: \.offset) { _, failure in
                            Text("\(failure.title): \(failure.reason)").appFont(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer()
                Button("Dismiss") { model.dismissSummary() }
            }
        }
    }
}

private struct CleanupRow: View {
    let entry: CleanupEntry
    let model: CleanupModel

    var body: some View {
        let blocked = model.isBlocked(entry)
        HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: Binding(
                get: { model.selected.contains(entry.id) && !blocked },
                set: { model.toggle(entry, on: $0) }
            ))
            .toggleStyle(.checkbox).labelsHidden().disabled(blocked)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.item.title).lineLimit(1).truncationMode(.middle)
                    if entry.item.safety == .lookFirst {
                        Text("Look first").appFont(.caption2, weight: .medium).foregroundStyle(.orange)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(.orange.opacity(0.15), in: Capsule())
                    }
                }
                Text(entry.item.location).appFont(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                if blocked {
                    Text("\(entry.ownerName ?? entry.item.title) is open").appFont(.caption).foregroundStyle(.orange)
                } else {
                    Text(entry.item.reason).appFont(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 12)
            Text(Format.storage(entry.item.bytes)).monospacedDigit().foregroundStyle(.secondary)
        }
        .appFont(.callout)
        .opacity(blocked ? 0.5 : 1)
        .contextMenu {
            Button("Show in Finder") { ProcessActions.reveal(entry.item.urls.first?.path) }
        }
    }
}
