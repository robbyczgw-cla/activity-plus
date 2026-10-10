import ActivityCore
import AppKit
import SwiftUI

/// Storage → Explore: the home folder as a size map. Biggest folders as a list and a treemap,
/// click to go deeper, a breakdown by kind of file. The map comes from `DiskIndexModel` (cached on disk).
struct ExploreTab: View {
    @Environment(AppServices.self) private var services
    /// Folder on screen, as a path so it survives a new scan; nil = the scanned root.
    @State private var folderPath: String?
    @State private var showAll = false
    @State private var pendingTrash: DiskIndex.Node?
    @State private var result: String?
    @State private var width: CGFloat = 800
    @State private var totals: [FileKind: UInt64] = [:]

    private static let listLimit = 25
    private static let listLimitAll = 300

    var body: some View {
        let model = services.diskIndex
        VStack(alignment: .leading, spacing: 16) {
            ExploreRootPicker()
            if let index = model.index {
                content(index, model: model)
            } else {
                switch model.state {
                case .scanning(let fraction, let item): scanningCard(fraction: fraction, item: item, model: model)
                case .failed(let message): emptyCard(model: model, message: message)
                case .idle, .ready: emptyCard(model: model, message: nil)
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .onAppear { model.loadCachedIfNeeded() }
        .onChange(of: model.selection) { folderPath = nil; showAll = false; result = nil }
        .confirmationDialog(String(localized: "Move “\(pendingTrash?.name ?? "")” to the Trash?"),
                            isPresented: Binding(get: { pendingTrash != nil }, set: { if !$0 { pendingTrash = nil } }),
                            presenting: pendingTrash) { node in
            Button("Move to Trash", role: .destructive) { trash(node) }
            Button("Cancel", role: .cancel) {}
        } message: { node in
            Text("\(Format.storage(node.bytes)) moves to the Trash. You can put it back from the Trash until you empty it.")
        }
    }

    // MARK: States without a map

    private func emptyCard(model: DiskIndexModel, message: String?) -> some View {
        Card {
            CardHeader(title: "See what takes the space", systemImage: "square.grid.3x3.topleft.filled", tint: .blue)
            Text("Activity+ reads your home folder once and shows which folders and kinds of files take the most space; nothing is moved or removed without asking.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let message { Text(message).font(.callout).foregroundStyle(.red) }
            if model.selection == .home && !model.isCustomRoot {
                Button("Scan home folder") { model.scan() }
                    .buttonStyle(.borderedProminent)
            } else {
                Button("Scan “\(model.rootTitle)”") { model.scan() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private func scanningCard(fraction: Double, item: String, model: DiskIndexModel) -> some View {
        Card {
            if model.selection == .home && !model.isCustomRoot {
                CardHeader(title: "Reading your home folder", systemImage: "magnifyingglass", tint: .blue)
            } else {
                Label("Reading “\(model.rootTitle)”", systemImage: "magnifyingglass").font(.headline).foregroundStyle(.blue)
            }
            progressRow(fraction: fraction, item: item, model: model)
            Text("This takes a moment the first time. The map is kept, so it opens instantly next time.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func progressRow(fraction: Double, item: String, model: DiskIndexModel) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: fraction)
                // A folder name, not a sentence: shown as is.
                Text(verbatim: item.isEmpty ? " " : item).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Button("Stop") { model.cancel() }
        }
    }

    // MARK: The map

    @ViewBuilder
    private func content(_ index: DiskIndex, model: DiskIndexModel) -> some View {
        let _ = model.generation
        let folderID = folderPath.flatMap { index.id(of: URL(fileURLWithPath: $0)) } ?? index.rootID
        let folder = index.node(folderID) ?? index.node(index.rootID)
        if let folder {
            let children = index.children(of: folder.id, limit: showAll ? Self.listLimitAll : Self.listLimit)
            let childCount = index.childCount(of: folder.id)

            breadcrumb(index.ancestry(of: folder.id), index: index)
            summaryCard(folder, index: index, model: model)
                .task(id: "\(model.generation)-\(folder.id)-\(ObjectIdentifier(index).hashValue)") {
                    let id = folder.id
                    totals = await Task.detached(priority: .userInitiated) { index.kindTotals(under: id) }.value
                }

            if folder.id == index.rootID {
                WhatGrewCard(index: index, summaries: model.growth) { url in
                    showAll = false
                    result = nil
                    folderPath = url.path
                }
            }

            if let result {
                Label(result, systemImage: "trash").padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            }

            if children.isEmpty {
                Card {
                    Text(folder.isDirectory ? "This folder is empty or could not be read." : "This is a file.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            } else if width >= 900 {
                HStack(alignment: .top, spacing: 16) {
                    listCard(children, total: childCount, folder: folder, index: index, model: model)
                        .frame(minWidth: 0, maxWidth: .infinity)
                    mapCard(children, folder: folder, index: index, model: model)
                        .frame(width: max(360, min(520, width * 0.42)))
                }
            } else {
                // Narrow: the map (fixed height) first, the long list below it.
                mapCard(children, folder: folder, index: index, model: model)
                listCard(children, total: childCount, folder: folder, index: index, model: model)
            }
        }
    }

    private func breadcrumb(_ chain: [DiskIndex.Node], index: DiskIndex) -> some View {
        HStack(spacing: 4) {
            ForEach(Array(chain.enumerated()), id: \.element.id) { position, node in
                if position > 0 {
                    Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                }
                let isLast = position == chain.count - 1
                Button {
                    open(node, index: index)
                } label: {
                    if position == 0 {
                        Label(rootTitle(index), systemImage: services.diskIndex.symbol(for: services.diskIndex.selection))
                    } else {
                        Text(verbatim: node.name)
                    }
                }
                .buttonStyle(.plain)
                .font(.callout.weight(isLast ? .semibold : .regular))
                .foregroundStyle(isLast ? Color.primary : Color.accentColor)
                .lineLimit(1)
                .disabled(isLast)
            }
            Spacer(minLength: 0)
        }
    }

    private func rootTitle(_ index: DiskIndex) -> String {
        let model = services.diskIndex
        return model.selection == .home && !model.isCustomRoot ? String(localized: "Home") : model.rootTitle
    }

    private func summaryCard(_ folder: DiskIndex.Node, index: DiskIndex, model: DiskIndexModel) -> some View {
        Card {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: folder.id == index.rootID ? rootTitle(index) : folder.name)
                        .font(.headline).lineLimit(1).truncationMode(.middle)
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        BigNumber(text: Format.storage(folder.bytes), size: 26)
                        Text("\(folder.fileCount) files").foregroundStyle(.secondary)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    if case .scanning = model.state {} else {
                        Button("Scan again") { model.scan() }
                    }
                    Text("Scanned \(index.builtAt, format: .relative(presentation: .named))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if case .scanning(let fraction, let item) = model.state {
                progressRow(fraction: fraction, item: item, model: model)
            }
            KindBreakdown(totals: totals)
        }
    }

    // MARK: List

    private func listCard(_ children: [DiskIndex.Node], total: Int, folder: DiskIndex.Node, index: DiskIndex, model: DiskIndexModel) -> some View {
        Card {
            CardHeader(title: "Largest items", systemImage: "list.bullet", tint: .blue)
            let largest = max(children.first?.bytes ?? 1, 1)
            VStack(spacing: 0) {
                ForEach(children) { child in
                    ExploreRow(node: child, largest: largest, share: Double(child.bytes) / Double(max(folder.bytes, 1)),
                               url: index.url(of: child.id), isSkipped: isSkipped(child, index: index), isUnread: child.isUnread)
                        .contentShape(Rectangle())
                        .onTapGesture { if child.isDirectory { open(child, index: index) } }
                        .contextMenu { menu(for: child, index: index, model: model) }
                    if child.id != children.last?.id { Divider().opacity(0.4) }
                }
            }
            if total > children.count {
                Button(showAll ? "Show the \(children.count) largest of \(total)" : "Show more (\(total) items)") { showAll.toggle() }
                    .buttonStyle(.link).font(.callout)
            } else if showAll && total > Self.listLimit {
                Button("Show fewer") { showAll = false }.buttonStyle(.link).font(.callout)
            }
        }
    }

    private func isSkipped(_ node: DiskIndex.Node, index: DiskIndex) -> Bool {
        node.isDirectory && node.bytes == 0 && DiskIndex.skippedFolders.contains(index.url(of: node.id).standardizedFileURL.path)
    }

    @ViewBuilder
    private func menu(for node: DiskIndex.Node, index: DiskIndex, model: DiskIndexModel) -> some View {
        let url = index.url(of: node.id)
        if node.isDirectory {
            Button("Open") { open(node, index: index) }
        }
        Button("Show in Finder") { ProcessActions.reveal(url.path) }
        Divider()
        Button("Move to Trash…") { pendingTrash = node }
            .disabled(model.refusal(for: url) != nil)
    }

    // MARK: Map

    private func mapCard(_ children: [DiskIndex.Node], folder: DiskIndex.Node, index: DiskIndex, model: DiskIndexModel) -> some View {
        Card {
            CardHeader(title: "Map", systemImage: "square.grid.2x2", tint: .blue)
            TreemapView(items: tiles(folder: folder, index: index),
                        open: { id in if let node = index.node(id) { open(node, index: index) } },
                        menu: { id in
                            if let node = index.node(id) { menu(for: node, index: index, model: model) }
                        })
                .frame(height: 360)
            Text("Click a folder to look inside. Colors show the kind of files that take most of each folder.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Up to 60 tiles; big folders show their own largest children inside (one level).
    private func tiles(folder: DiskIndex.Node, index: DiskIndex) -> [TreemapItem] {
        let visible = index.children(of: folder.id, limit: 60).filter { $0.bytes > 0 }
        var items = visible.map { node -> TreemapItem in
            let inner = node.isDirectory && Double(node.bytes) / Double(max(folder.bytes, 1)) > 0.06
                ? index.children(of: node.id, limit: 24).filter { $0.bytes > 0 }.map { TreemapItem($0) }
                : []
            return TreemapItem(node, children: inner)
        }
        let shown = visible.reduce(UInt64(0)) { $0 + $1.bytes }
        if folder.bytes > shown, folder.bytes - shown > folder.bytes / 200 {
            items.append(TreemapItem(id: -1, name: String(localized: "Everything else"), bytes: folder.bytes - shown,
                                          fileCount: 0, kind: .other, isDirectory: false))
        }
        return items
    }

    // MARK: Actions

    private func open(_ node: DiskIndex.Node, index: DiskIndex) {
        guard node.isDirectory else { return }
        showAll = false
        result = nil
        folderPath = node.id == index.rootID ? nil : index.url(of: node.id).path
    }

    private func trash(_ node: DiskIndex.Node) {
        guard let index = services.diskIndex.index else { return }
        let url = index.url(of: node.id)
        let outcome = services.diskIndex.trash([url])
        if let failure = outcome.failures.values.first {
            result = String(localized: "“\(node.name)” could not be moved to the Trash: \(failure)")
        } else {
            result = String(localized: "Moved \(Format.storage(outcome.freed)) to the Trash. Empty the Trash to actually free the space.")
        }
    }
}

// MARK: - Pieces

/// Colour, name and symbol per kind of file, shared by the breakdown, the list and the treemap.
enum FileKindStyle {
    static func color(_ kind: FileKind) -> Color {
        switch kind {
        case .video: .purple
        case .image: .pink
        case .audio: .red
        case .archive: .brown
        case .code: .blue
        case .document: .teal
        case .app: .indigo
        case .dataCache: .orange
        case .other: .gray
        }
    }

    static func title(_ kind: FileKind) -> String {
        switch kind {
        case .video: String(localized: "Video")
        case .image: String(localized: "Images")
        case .audio: String(localized: "Audio")
        case .archive: String(localized: "Archives")
        case .code: String(localized: "Code")
        case .document: String(localized: "Documents")
        case .app: String(localized: "Apps")
        case .dataCache: String(localized: "Data & caches")
        case .other: String(localized: "Other")
        }
    }

    static func symbol(_ kind: FileKind) -> String {
        switch kind {
        case .video: "film"
        case .image: "photo"
        case .audio: "music.note"
        case .archive: "archivebox"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .document: "doc.text"
        case .app: "app.dashed"
        case .dataCache: "cylinder.split.1x2"
        case .other: "doc"
        }
    }
}

/// Stacked bar by kind with a legend.
private struct KindBreakdown: View {
    let totals: [FileKind: UInt64]

    var body: some View {
        let sorted = totals.filter { $0.value > 0 }.sorted { $0.value > $1.value }
        let sum = max(sorted.reduce(UInt64(0)) { $0 + $1.value }, 1)
        VStack(alignment: .leading, spacing: 10) {
            GeometryReader { proxy in
                HStack(spacing: 1.5) {
                    ForEach(sorted, id: \.key) { kind, bytes in
                        Rectangle().fill(FileKindStyle.color(kind).gradient)
                            .frame(width: max(2, (proxy.size.width - 1.5 * CGFloat(sorted.count - 1)) * CGFloat(bytes) / CGFloat(sum)))
                            .help("\(FileKindStyle.title(kind)): \(Format.storage(bytes))")
                    }
                    if sorted.isEmpty { Rectangle().fill(.quaternary) }
                }
            }
            .frame(height: 12)
            .clipShape(Capsule())

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 14, alignment: .leading)], alignment: .leading, spacing: 6) {
                ForEach(sorted, id: \.key) { kind, bytes in
                    HStack(spacing: 6) {
                        Circle().fill(FileKindStyle.color(kind)).frame(width: 8, height: 8)
                        Text(FileKindStyle.title(kind)).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(Format.storage(bytes)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
            }
        }
    }
}

private struct ExploreRow: View {
    let node: DiskIndex.Node
    let largest: UInt64
    let share: Double
    let url: URL
    let isSkipped: Bool
    var isUnread = false
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: node.isDirectory ? "folder.fill" : FileKindStyle.symbol(node.kind))
                .foregroundStyle(FileKindStyle.color(node.kind))
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: node.name).lineLimit(1).truncationMode(.middle)
                Group {
                    if isSkipped {
                        Text("Not read: macOS protects other apps' data")
                    } else if isUnread {
                        Text("Not read: Activity+ may not open this folder")
                    } else if node.isDirectory {
                        Text("\(node.fileCount) files")
                    } else {
                        Text("Modified \(node.modified, format: .dateTime.day().month().year())")
                    }
                }
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            UsageBar(fraction: Double(node.bytes) / Double(largest), tint: FileKindStyle.color(node.kind))
                .frame(width: 70)
                .help(String(localized: "\(Format.percent(share * 100)) of this folder"))
            Text(Format.storage(node.bytes)).monospacedDigit().frame(width: 76, alignment: .trailing)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                .opacity(node.isDirectory ? 1 : 0)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 6)
        .background(hovering ? Color.primary.opacity(0.05) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .onHover { hovering = $0 }
        .help(url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
    }
}

/// A tile. `id` < 0 for the "everything else" tile, which has no node behind it.
struct TreemapItem: Identifiable {
    let id: DiskIndex.NodeID
    let name: String
    let bytes: UInt64
    let fileCount: Int
    let kind: FileKind
    let isDirectory: Bool
    var children: [TreemapItem] = []

    init(_ node: DiskIndex.Node, children: [TreemapItem] = []) {
        self.init(id: node.id, name: node.name, bytes: node.bytes, fileCount: node.fileCount, kind: node.kind,
                  isDirectory: node.isDirectory, children: children)
    }

    init(id: DiskIndex.NodeID, name: String, bytes: UInt64, fileCount: Int, kind: FileKind, isDirectory: Bool, children: [TreemapItem] = []) {
        self.id = id
        self.name = name
        self.bytes = bytes
        self.fileCount = fileCount
        self.kind = kind
        self.isDirectory = isDirectory
        self.children = children
    }
}

/// Squarified treemap of one folder's children, coloured by kind.
struct TreemapView<Menu: View>: View {
    typealias Item = TreemapItem

    let items: [Item]
    let open: (DiskIndex.NodeID) -> Void
    @ViewBuilder let menu: (DiskIndex.NodeID) -> Menu
    @State private var hovered: DiskIndex.NodeID?

    var body: some View {
        GeometryReader { proxy in
            let rects = Treemap.layout(items.map { Double($0.bytes) }, in: CGRect(origin: .zero, size: proxy.size))
            ZStack(alignment: .topLeading) {
                ForEach(Array(items.enumerated()), id: \.element.id) { position, item in
                    tile(item, rect: rects[position])
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    @ViewBuilder
    private func tile(_ item: Item, rect: CGRect) -> some View {
        let color = FileKindStyle.color(item.kind)
        let inset = rect.insetBy(dx: 1, dy: 1)
        let showsInner = !item.children.isEmpty && inset.width > 110 && inset.height > 80
        let labelHeight: CGFloat = 30
        if inset.width > 0, inset.height > 0 {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(color.opacity(showsInner ? 0.55 : (hovered == item.id ? 1 : 0.82)).gradient)
                if showsInner {
                    let innerBounds = CGRect(x: 3, y: labelHeight, width: inset.width - 6, height: inset.height - labelHeight - 3)
                    let innerRects = Treemap.layout(item.children.map { Double($0.bytes) }, in: innerBounds)
                    ForEach(Array(item.children.enumerated()), id: \.element.id) { position, child in
                        let r = innerRects[position].insetBy(dx: 0.75, dy: 0.75)
                        if r.width > 0, r.height > 0 {
                            innerTile(child, rect: r)
                        }
                    }
                }
                if inset.width > 54, inset.height > 28 {
                    label(item, compact: inset.height < 44)
                        .padding(.horizontal, 6).padding(.vertical, 4)
                        .frame(width: inset.width, alignment: .leading)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: inset.width, height: inset.height)
            .contentShape(Rectangle())
            .offset(x: inset.minX, y: inset.minY)
            .onHover { inside in hovered = inside ? item.id : (hovered == item.id ? nil : hovered) }
            .onTapGesture { if item.isDirectory { open(item.id) } }
            .help(tooltip(item))
            .contextMenu { if item.id >= 0 { menu(item.id) } }
        }
    }

    private func innerTile(_ item: Item, rect: CGRect) -> some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(FileKindStyle.color(item.kind).opacity(hovered == item.id ? 1 : 0.85).gradient)
            .overlay(alignment: .topLeading) {
                if rect.width > 60, rect.height > 30 {
                    label(item, compact: true).padding(4).allowsHitTesting(false)
                }
            }
            .frame(width: rect.width, height: rect.height)
            .contentShape(Rectangle())
            .offset(x: rect.minX, y: rect.minY)
            .onHover { inside in hovered = inside ? item.id : (hovered == item.id ? nil : hovered) }
            .onTapGesture { if item.isDirectory { open(item.id) } }
            .help(tooltip(item))
            .contextMenu { menu(item.id) }
    }

    private func label(_ node: Item, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: node.name).font(.caption.weight(.semibold)).lineLimit(1).truncationMode(.middle)
            if !compact {
                Text(Format.storage(node.bytes)).font(.caption2).monospacedDigit().opacity(0.9)
            } else {
                Text(Format.storage(node.bytes)).font(.caption2).monospacedDigit().opacity(0.85).lineLimit(1)
            }
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.35), radius: 1, y: 0.5)
    }

    private func tooltip(_ node: Item) -> String {
        if node.id < 0 { return "\(node.name): \(Format.storage(node.bytes))" }
        return node.isDirectory
            ? String(localized: "\(node.name): \(Format.storage(node.bytes)) in \(node.fileCount) files")
            : "\(node.name): \(Format.storage(node.bytes))"
    }
}
