import ActivityCore
import AppKit
import SwiftUI

/// Storage > Biggest: the largest files in the home folder, filtered live by a search query
/// (`ext:dmg size:>300mb age:>90d invoice`). Searches the map built in Explore; nothing here deletes
/// anything permanently, items go to the Trash after a confirmation.
struct BiggestTab: View {
    @Environment(\.density) private var density
    @Environment(AppServices.self) private var services

    /// One result row, decoupled from the index so it stays cheap to diff and easy to fake in previews.
    struct Row: Identifiable, Hashable {
        let id: Int32
        let name: String
        let folder: String
        let url: URL
        let kind: FileKind
        let bytes: UInt64
        let modified: Date
        let accessed: Date?
    }

    @State private var text = ""
    @State private var rows: [Row] = []
    @State private var matchSeconds: Double = 0
    @State private var searching = false
    @State private var selected: Set<Int32> = []
    @State private var pendingTrash: [Row] = []
    @State private var confirmTrash = false
    @State private var message: String?
    @State private var failures: [String] = []
    @State private var showHelp = false

    private static let chips: [(title: LocalizedStringKey, query: String)] = [
        ("Over 1 GB", "size:>1gb"),
        ("Installers", "ext:dmg,pkg,xip,iso"),
        ("Videos", "kind:video"),
        ("Archives", "kind:archive"),
        ("Not opened for a year", "opened:>1y"),
    ]


    private var model: DiskIndexModel { services.diskIndex }
    private var hasIndex: Bool { model.index != nil }
    private var selectedRows: [Row] { rows.filter { selected.contains($0.id) } }
    private var selectedBytes: UInt64 { selectedRows.reduce(0) { $0 + $1.bytes } }

    var body: some View {
        VStack(alignment: .leading, spacing: density.stack) {
            if hasIndex {
                searchCard
                resultsCard
            } else {
                noIndexCard
            }
        }
        .onAppear { model.loadCachedIfNeeded() }
        .task(id: QueryKey(text: text, generation: model.generation, ready: hasIndex)) { await runQuery() }
        .confirmationDialog("Move \(pendingTrash.count) items to the Trash?", isPresented: $confirmTrash) {
            Button("Move to Trash", role: .destructive) { trash(pendingTrash) }
            Button("Cancel", role: .cancel) { pendingTrash = [] }
        } message: {
            Text("\(Format.storage(pendingTrash.reduce(0) { $0 + $1.bytes })) move to the Trash. You can put them back from the Trash until you empty it.")
        }
    }

    // MARK: - No index

    private var noIndexCard: some View {
        Card {
            CardHeader(title: "Biggest files", systemImage: "doc.text.magnifyingglass", tint: .orange)
            if case .scanning(let fraction, let item) = model.state {
                HStack {
                    ProgressView(value: fraction)
                    Button("Stop") { model.cancel() }
                }
                Text(item).appFont(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            } else {
                Text("This tab searches the map of your home folder that Explore builds. Scan once and every search after that is instant.")
                    .appFont(.callout).foregroundStyle(.secondary)
                if case .failed(let reason) = model.state {
                    Text(reason).appFont(.callout).foregroundStyle(.red)
                }
                Button("Scan home folder") { model.scan() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: - Search

    private var searchCard: some View {
        Card {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search by name, kind, size or age", text: $text)
                    .textFieldStyle(.plain)
                    .appFont(.body)
                    .autocorrectionDisabled()
                if !text.isEmpty {
                    Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.tertiary)
                        .help("Clear")
                }
                Button { showHelp.toggle() } label: { Image(systemName: "info.circle") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("Search syntax")
                    .popover(isPresented: $showHelp, arrowEdge: .bottom) { helpView }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(.background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.separator))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(Self.chips.enumerated()), id: \.offset) { _, chip in
                        let active = text == chip.query
                        Button { text = active ? "" : chip.query } label: {
                            Text(chip.title).appFont(.callout)
                                .padding(.horizontal, 10).padding(.vertical, 4)
                                .background(active ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.06), in: Capsule())
                                .overlay(Capsule().strokeBorder(active ? Color.accentColor.opacity(0.6) : .clear))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var helpView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Search syntax").appFont(.headline)
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
                helpRow("invoice", "Words in the name; all must match")
                helpRow("-draft", "Leave out names containing a word")
                helpRow("ext:dmg,pkg", "File extension")
                helpRow("kind:video", "video, image, audio, archive, code, document, app")
                helpRow("size:>300mb", "Larger (or <) than a size")
                helpRow("size:500mb..2gb", "Size between two values")
                helpRow("age:>90d", "Modified more than 90 days ago")
                helpRow("opened:>180d", "Not opened for 180 days")
            }
            Text("Combine as you like: ext:mov size:>1gb age:>1y")
                .appFont(.caption).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: 400)
    }

    private func helpRow(_ syntax: String, _ meaning: LocalizedStringKey) -> some View {
        GridRow {
            Text(syntax).appFont(.callout, design: .monospaced)
            Text(meaning).appFont(.callout).foregroundStyle(.secondary)
        }
    }

    // MARK: - Results

    private var resultsCard: some View {
        Card {
            HStack {
                Text(text.trimmingCharacters(in: .whitespaces).isEmpty ? "Largest files" : "Matches")
                    .appFont(.headline)
                Spacer()
                Text(summary).appFont(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            if rows.isEmpty {
                Text(searching ? "Searching…" : "No files match.")
                    .foregroundStyle(.secondary).padding(.vertical, 12)
            } else {
                let largest = max(1, rows.first?.bytes ?? 1)
                LazyVStack(spacing: 0) {
                    ForEach(rows) { row in
                        rowView(row, largest: largest)
                        if row.id != rows.last?.id { Divider() }
                    }
                }
            }
            footer
        }
    }

    private var summary: String {
        let ms = matchSeconds * 1000
        let time = ms < 1 ? String(localized: "<1 ms") : String(format: "%.0f ms", ms)
        return String(localized: "\(rows.count) files") + " · " + time
    }

    private func rowView(_ row: Row, largest: UInt64) -> some View {
        let isOn = Binding(get: { selected.contains(row.id) },
                           set: { if $0 { selected.insert(row.id) } else { selected.remove(row.id) } })
        return HStack(spacing: 10) {
            Toggle("", isOn: isOn).toggleStyle(.checkbox).labelsHidden()
            Image(nsImage: BiggestIcons.icon(for: row.url))
                .resizable().frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name).lineLimit(1).truncationMode(.middle)
                Text(row.folder).appFont(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            }
            Spacer(minLength: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.kindTitle(row.kind)).appFont(.caption)
                Text(dateText(row)).appFont(.caption).foregroundStyle(.secondary)
            }
            .frame(width: 150, alignment: .leading)
            VStack(alignment: .trailing, spacing: 4) {
                Text(Format.storage(row.bytes)).monospacedDigit().fontWeight(.medium)
                UsageBar(fraction: Double(row.bytes) / Double(largest), tint: .orange).frame(width: 90)
            }
            .frame(width: 100, alignment: .trailing)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture { if selected.contains(row.id) { selected.remove(row.id) } else { selected.insert(row.id) } }
        .contextMenu {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([row.url]) }
            Button("Quick Look") { BiggestIcons.quickLook(row.url) }
            Divider()
            Button("Move to Trash…", role: .destructive) { askTrash([row]) }
        }
    }

    private func dateText(_ row: Row) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        if text.contains("opened:"), let accessed = row.accessed {
            return String(localized: "opened \(formatter.localizedString(for: accessed, relativeTo: Date()))")
        }
        return String(localized: "modified \(formatter.localizedString(for: row.modified, relativeTo: Date()))")
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !rows.isEmpty {
                HStack {
                    if selected.isEmpty {
                        Text("Select files to move them to the Trash.").appFont(.callout).foregroundStyle(.secondary)
                    } else {
                        Text("\(selected.count) selected · \(Format.storage(selectedBytes))").appFont(.callout)
                    }
                    Spacer()
                    if !selected.isEmpty {
                        Button("Clear selection") { selected = [] }
                    }
                    Button("Move \(selected.count) items (\(Format.storage(selectedBytes))) to Trash…") { askTrash(selectedRows) }
                        .buttonStyle(.borderedProminent)
                        .disabled(selected.isEmpty)
                }
            }
            if let message { Text(message).appFont(.callout).foregroundStyle(.green) }
            ForEach(failures, id: \.self) { Text($0).appFont(.caption).foregroundStyle(.red) }
        }
        .padding(.top, 4)
    }

    // MARK: - Actions

    private func askTrash(_ items: [Row]) {
        guard !items.isEmpty else { return }
        pendingTrash = items
        confirmTrash = true
    }

    private func trash(_ items: [Row]) {
        defer { pendingTrash = [] }
        let result = model.trash(items.map(\.url))
        selected = []
        message = String(localized: "Moved \(Format.storage(result.freed)) to the Trash")
        failures = result.failures.sorted { $0.key < $1.key }.map { "\(($0.key as NSString).lastPathComponent): \($0.value)" }
        // `generation` changes, which re-runs the query.
    }

    // MARK: - Query

    private struct QueryKey: Equatable {
        let text: String
        let generation: Int
        let ready: Bool
    }

    private func runQuery() async {
        guard let index = model.index else { rows = []; return }
        let query = text
        if !query.isEmpty {
            try? await Task.sleep(for: .milliseconds(150))
            if Task.isCancelled { return }
        }
        searching = true
        let result = await Task.detached(priority: .userInitiated) { () -> ([Row], Double) in
            let start = ContinuousClock.now
            let parsed = FileQuery.parse(query)
            let nodes = index.files(matching: parsed, limit: parsed.isEmpty ? 100 : 300)
            let rows = nodes.map { node -> Row in
                let url = index.url(of: node.id)
                return Row(id: node.id, name: node.name, folder: (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath,
                           url: url, kind: node.kind, bytes: node.bytes, modified: node.modified, accessed: node.accessed)
            }
            let d = ContinuousClock.now - start
            return (rows, Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18)
        }.value
        if Task.isCancelled { return }
        rows = result.0
        matchSeconds = result.1
        searching = false
        selected = selected.intersection(Set(result.0.map(\.id)))
    }

    private static func kindTitle(_ kind: FileKind) -> String {
        switch kind {
        case .video: String(localized: "Video")
        case .image: String(localized: "Image")
        case .audio: String(localized: "Audio")
        case .archive: String(localized: "Archive")
        case .code: String(localized: "Code")
        case .document: String(localized: "Document")
        case .app: String(localized: "App")
        case .dataCache: String(localized: "Data")
        case .other: String(localized: "Other")
        }
    }
}

/// Icons are looked up per path; NSWorkspace is slow enough that 300 rows should not ask twice.
@MainActor
private enum BiggestIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(for url: URL) -> NSImage {
        // Same extension → same icon, so cache by extension instead of by path.
        let key = url.pathExtension.lowercased()
        if let hit = cache[key] { return hit }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        cache[key] = image
        return image
    }

    static func quickLook(_ url: URL) {
        // qlmanage opens the same preview as the space bar in Finder; it only reads the file.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/qlmanage")
        process.arguments = ["-p", url.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }
}
