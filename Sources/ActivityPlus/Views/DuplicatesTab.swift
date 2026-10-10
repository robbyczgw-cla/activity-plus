import ActivityCore
import AppKit
import SwiftUI

/// Storage → Duplicates: files that exist more than once, found in the map of the folder or drive picked in Explore.
/// Same size → same first and last 64 KB → same SHA-256. Extra copies go to the Trash only after a confirmation,
/// and one copy of every file always stays.
struct DuplicatesTab: View {
    @Environment(AppServices.self) private var services
    @AppStorage("duplicatesMinMB") private var minMB = 1
    @State private var confirmTrash = false
    @State private var result: String?
    @State private var shownGroups = 40

    private var finder: DuplicatesModel { DuplicatesModel.shared }

    var body: some View {
        let map = services.diskIndex
        VStack(alignment: .leading, spacing: 16) {
            if let index = map.index {
                let current = finder.rootPath == index.root.path
                searchCard(index: index, current: current)
                if let result {
                    Label(result, systemImage: "trash").padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                }
                if current, finder.state == .done {
                    results
                }
            } else {
                noMapCard(map)
            }
        }
        .onAppear { map.loadCachedIfNeeded() }
        .task(id: map.index.map { ObjectIdentifier($0) }) {
            // Snapshot runs search right away, so the tab shows results.
            if SnapshotRunner.isActive, let index = map.index, finder.rootPath != index.root.path || finder.state == .idle {
                finder.start(index: index, minMB: minMB, scanRoot: map.selection, isCustomRoot: map.customHome != nil)
            }
        }
        .confirmationDialog("Move \(selectedFiles.count) copies to the Trash?", isPresented: $confirmTrash) {
            Button("Move to Trash", role: .destructive, action: trash)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(Format.storage(selectedBytes)) move to the Trash. One copy of each file stays where it is. You can put them back from the Trash until you empty it.")
        }
    }

    // MARK: Without a map

    private func noMapCard(_ map: DiskIndexModel) -> some View {
        Card {
            CardHeader(title: "Duplicate files", systemImage: "doc.on.doc", tint: .purple)
            if case .scanning(let fraction, let item) = map.state {
                HStack {
                    ProgressView(value: fraction)
                    Button("Stop") { map.cancel() }
                }
                Text(verbatim: item.isEmpty ? " " : item).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            } else {
                Text("Duplicates are looked up in the map that Explore builds of “\(map.rootTitle)”. Scan once, then search here.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Scan “\(map.rootTitle)”") { map.scan() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: Search

    private func searchCard(index: DiskIndex, current: Bool) -> some View {
        Card {
            CardHeader(title: "Duplicate files", systemImage: "doc.on.doc", tint: .purple)
            Text("Finds files with exactly the same contents in “\(services.diskIndex.rootTitle)”. Compares sizes first, then the first and last bytes, and reads whole files only when those match. Skips app data in Library, hidden folders and the insides of apps and libraries.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Text("Files of at least").foregroundStyle(.secondary)
                Picker("Files of at least", selection: $minMB) {
                    Text("1 MB").tag(1)
                    Text("10 MB").tag(10)
                    Text("100 MB").tag(100)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .disabled(isSearching)
                Spacer()
                if isSearching {
                    Button("Stop") { finder.stop() }
                } else {
                    Button(current && finder.state == .done ? "Search again" : "Find duplicates") {
                        result = nil
                        shownGroups = 40
                        finder.start(index: index, minMB: minMB, scanRoot: services.diskIndex.selection,
                                     isCustomRoot: services.diskIndex.customHome != nil)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            if case .searching(let progress) = finder.state {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: progress?.fraction ?? 0)
                    Text(phaseText(progress)).font(.caption).foregroundStyle(.secondary)
                }
            } else if current, finder.state == .done, let searchedAt = finder.searchedAt {
                Text("Searched \(searchedAt, format: .relative(presentation: .named)), files of at least \(finder.minMB) MB.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var isSearching: Bool {
        if case .searching = finder.state { return true }
        return false
    }

    private func phaseText(_ progress: DuplicateFinder.Progress?) -> String {
        guard let progress else { return String(localized: "Collecting files from the map…") }
        switch progress.phase {
        case .sizes: return String(localized: "Comparing sizes…")
        case .partial: return String(localized: "Comparing the first and last bytes of \(progress.total) files…")
        case .full: return String(localized: "Comparing the full contents of \(progress.total) files…")
        }
    }

    // MARK: Results

    private var selectedFiles: [DuplicateFinder.File] {
        finder.groups.flatMap { group in group.files.filter { finder.selection.contains($0.path) } }
    }

    private var selectedBytes: UInt64 { selectedFiles.reduce(0) { $0 + $1.size } }

    @ViewBuilder private var results: some View {
        let groups = finder.groups
        if groups.isEmpty {
            Card {
                Label("No duplicates of \(finder.minMB) MB or more.", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            }
        } else {
            let wasted = groups.reduce(UInt64(0)) { $0 + $1.wasted }
            Card {
                Text("\(groups.count) files exist more than once. The extra copies take \(Format.storage(wasted)).")
                    .font(.callout)
                HStack {
                    Button("Tick all extra copies") {
                        finder.selection = Set(groups.flatMap { $0.files.dropFirst().map(\.path) }.filter { services.diskIndex.refusal(for: URL(fileURLWithPath: $0)) == nil })
                    }
                    Button("Untick all") { finder.selection = [] }.disabled(finder.selection.isEmpty)
                    Spacer()
                    Button("Move \(selectedFiles.count) copies (\(Format.storage(selectedBytes))) to Trash…") { confirmTrash = true }
                        .disabled(selectedFiles.isEmpty)
                }
            }
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(groups.prefix(shownGroups)) { group in
                    groupCard(group)
                }
            }
            if groups.count > shownGroups {
                Button("Show more (\(groups.count - shownGroups) more groups)") { shownGroups += 60 }
                    .buttonStyle(.link).font(.callout)
            }
        }
    }

    private func groupCard(_ group: DuplicateFinder.Group) -> some View {
        let kind = FileKind.classify(name: group.keep.name)
        return Card {
            HStack(spacing: 10) {
                Image(systemName: FileKindStyle.symbol(kind)).foregroundStyle(FileKindStyle.color(kind)).frame(width: 20)
                Text(verbatim: group.keep.name).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                Text("\(Format.storage(group.size)) × \(group.copies)").foregroundStyle(.secondary).monospacedDigit()
                Spacer(minLength: 8)
                Text("\(Format.storage(group.wasted)) extra").monospacedDigit().foregroundStyle(.secondary)
            }
            VStack(spacing: 0) {
                ForEach(group.files) { file in
                    copyRow(file, in: group)
                    if file.id != group.files.last?.id { Divider().opacity(0.4) }
                }
            }
        }
    }

    private func copyRow(_ file: DuplicateFinder.File, in group: DuplicateFinder.Group) -> some View {
        let ticked = finder.selection.contains(file.path)
        let tickedInGroup = group.files.filter { finder.selection.contains($0.path) }.count
        let refusal = services.diskIndex.refusal(for: URL(fileURLWithPath: file.path))
        // Never all copies: the last unticked one cannot be ticked.
        let wouldTickAll = !ticked && tickedInGroup >= group.files.count - 1
        let rootPath = services.diskIndex.root.path
        let shown = file.path.hasPrefix(rootPath + "/") && rootPath != "/"
            ? String(file.path.dropFirst(rootPath.count + 1))
            : file.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        return HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { ticked }, set: { on in
                if on { finder.selection.insert(file.path) } else { finder.selection.remove(file.path) }
            }))
            .toggleStyle(.checkbox).labelsHidden()
            .disabled(refusal != nil || wouldTickAll)
            .help(refusal ?? (wouldTickAll ? String(localized: "One copy always stays.") : String(localized: "Move this copy to the Trash")))
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(verbatim: shown)
                        .lineLimit(1).truncationMode(.middle)
                    if file.path == group.keep.path && !ticked {
                        Text("Keep").font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.green.opacity(0.18), in: Capsule())
                            .foregroundStyle(.green)
                            .help("The newest copy. Tick the others to remove them.")
                    }
                }
                Text("Modified \(file.modified, format: .dateTime.day().month().year().hour().minute())")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button { ProcessActions.reveal(file.path) } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(.borderless).help("Show in Finder")
        }
        .padding(.vertical, 4)
        .help(file.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
    }

    // MARK: Trash

    private func trash() {
        var urls: [URL] = []
        var changed = 0
        for group in finder.groups {
            let wanted = group.files.map(\.path).filter { finder.selection.contains($0) }
            guard !wanted.isEmpty else { continue }
            // Checked again now: unchanged since the search, and one unchanged copy stays.
            let safe = DuplicateFinder.stillSafe(wanted, in: group)
            changed += wanted.count - safe.count
            urls += safe.map { URL(fileURLWithPath: $0) }
        }
        let outcome = services.diskIndex.trash(urls)
        let moved = Set(urls.map(\.path)).subtracting(outcome.failures.keys)
        finder.didTrash(moved)
        var message = String(localized: "Moved \(moved.count) copies (\(Format.storage(outcome.freed))) to the Trash. Empty the Trash to actually free the space.")
        if changed > 0 { message += " " + String(localized: "\(changed) copies were skipped because they or their twins changed since the search.") }
        if !outcome.failures.isEmpty { message += " " + String(localized: "\(outcome.failures.count) could not be moved.") }
        result = message
    }
}

/// Search state for the Duplicates tab; kept while switching tabs.
@MainActor @Observable
final class DuplicatesModel {
    static let shared = DuplicatesModel()

    enum State: Equatable {
        case idle
        case searching(DuplicateFinder.Progress?)
        case done
    }

    private(set) var state: State = .idle
    private(set) var groups: [DuplicateFinder.Group] = []
    /// Root of the map the results come from.
    private(set) var rootPath: String?
    private(set) var minMB = 1
    private(set) var searchedAt: Date?
    var selection: Set<String> = []
    @ObservationIgnored private var flag: StopFlag?

    func start(index: DiskIndex, minMB: Int, scanRoot: DiskIndexModel.ScanRoot, isCustomRoot: Bool) {
        flag?.stop()
        let flag = StopFlag()
        self.flag = flag
        state = .searching(nil)
        groups = []
        selection = []
        rootPath = index.root.path
        self.minMB = minMB
        let minBytes = UInt64(minMB) * 1_000_000
        let home = DiskIndexModel.homePath
        Task.detached(priority: .utility) {
            // On the whole startup disk only the home folder: everything else is not the user's to remove.
            var start = index.rootID
            if scanRoot == .startupDisk {
                start = index.id(of: URL(fileURLWithPath: home, isDirectory: true)) ?? index.rootID
            }
            var skipped = Set(DiskIndex.skippedFolders)
            if !isCustomRoot || scanRoot != .home { skipped.insert(home + "/Library") }
            let paths = DuplicateFinder.candidates(in: index, under: start, minBytes: minBytes) { skipped.contains($0) }
            let found = DuplicateFinder.find(paths: paths, minBytes: minBytes, isCancelled: { flag.isStopped }) { progress in
                Task { @MainActor in
                    guard self.flag === flag, case .searching = self.state else { return }
                    self.state = .searching(progress)
                }
            }
            let stopped = flag.isStopped
            await MainActor.run {
                guard self.flag === flag else { return }
                self.flag = nil
                if stopped {
                    self.state = .idle
                    self.rootPath = nil
                    return
                }
                self.groups = found
                self.searchedAt = Date()
                self.state = .done
            }
        }
    }

    func stop() { flag?.stop() }

    /// Takes copies that went to the Trash out of the results; groups with one copy left disappear.
    func didTrash(_ paths: Set<String>) {
        guard !paths.isEmpty else { return }
        selection.subtract(paths)
        groups = groups.compactMap { group in
            var group = group
            group.files.removeAll { paths.contains($0.path) }
            return group.files.count > 1 ? group : nil
        }
    }
}

private final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func stop() { lock.lock(); value = true; lock.unlock() }
}
