import ActivityCore
import SwiftUI

/// Large and old files the user may no longer need: installers, forgotten downloads, huge files.
/// Nothing is selected by default; everything goes to the Trash after a confirmation.
struct CleanupCandidatesCard: View {
    @State private var candidates: [CleanupCandidate] = []
    @State private var selected: Set<String> = []
    @State private var progress: (Double, String)?
    @State private var scanner: LargeFilesScanner?
    @State private var scanned = false
    @State private var confirm = false
    @State private var message: String?

    private var selectedBytes: UInt64 {
        candidates.filter { selected.contains($0.id) }.reduce(0) { $0 + $1.bytes }
    }

    var body: some View {
        Card {
            HStack {
                CardHeader(title: "Large and old files", systemImage: "doc.badge.clock", tint: .orange)
                Spacer()
                if let progress {
                    ProgressView(value: progress.0).frame(width: 140)
                    Button("Stop") { scanner?.cancel() }
                } else {
                    Button(scanned ? "Scan Again" : "Find Large Files") { scan() }
                }
            }
            if !scanned && progress == nil {
                Text("Looks through Downloads, Desktop, Documents and Movies for installers you already used, downloads you never opened again and very large files. Nothing is selected or removed unless you choose it.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let progress {
                Text(progress.1).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            if scanned && candidates.isEmpty && progress == nil {
                Text("Nothing large or forgotten found.").foregroundStyle(.secondary)
            }
            ForEach(CleanupCandidate.Kind.allCases, id: \.self) { kind in
                let items = candidates.filter { $0.kind == kind }
                if !items.isEmpty {
                    Text("\(Self.title(kind)) (\(Format.storage(items.reduce(0) { $0 + $1.bytes })))")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 6)
                    ForEach(items.prefix(25)) { item in row(item) }
                }
            }
            if !selected.isEmpty {
                HStack {
                    Spacer()
                    Button("Move \(Format.storage(selectedBytes)) to Trash…") { confirm = true }
                        .buttonStyle(.borderedProminent)
                }
            }
            if let message { Text(message).font(.callout).foregroundStyle(.green) }
        }
        .confirmationDialog("Move \(selected.count) items to the Trash?", isPresented: $confirm) {
            Button("Move to Trash", role: .destructive, action: trash)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(Format.storage(selectedBytes)) moves to the Trash. You can put everything back from the Trash until you empty it.")
        }
    }

    private func row(_ item: CleanupCandidate) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { selected.contains(item.id) }, set: { on in
                if on { selected.insert(item.id) } else { selected.remove(item.id) }
            }))
            .toggleStyle(.checkbox).labelsHidden()
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path)).resizable().frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                Text(detail(item)).font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Button { ProcessActions.reveal(item.url.path) } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(.borderless).help("Show in Finder")
            Text(Format.storage(item.bytes)).monospacedDigit().foregroundStyle(.secondary).frame(width: 80, alignment: .trailing)
        }
        .font(.callout)
    }

    private func detail(_ item: CleanupCandidate) -> String {
        let folder = item.url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        if let opened = item.lastOpened { return "\(folder) · last opened \(opened.formatted(.relative(presentation: .named)))" }
        return folder
    }

    static func title(_ kind: CleanupCandidate.Kind) -> String {
        switch kind {
        case .installer: "Installers (.dmg, .pkg)"
        case .oldDownload: "Downloads not opened for 90 days"
        case .largeFile: "Large files"
        case .xcodeArchive: "Xcode archives"
        case .iosBackup: "iPhone and iPad backups"
        case .oldDiskImageMount: "Mounted disk images"
        }
    }

    private func scan() {
        let scanner = LargeFilesScanner()
        self.scanner = scanner
        progress = (0, "")
        message = nil
        Task.detached(priority: .utility) {
            let found = scanner.scan { fraction, item in
                Task { @MainActor in if progress != nil { progress = (fraction, item) } }
            }
            await MainActor.run {
                candidates = found
                selected = []
                progress = nil
                scanned = true
            }
        }
    }

    private func trash() {
        var freed: UInt64 = 0
        var failed = 0
        for item in candidates where selected.contains(item.id) {
            do {
                try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
                freed += item.bytes
            } catch {
                failed += 1
            }
        }
        candidates.removeAll { selected.contains($0.id) && FileManager.default.fileExists(atPath: $0.url.path) == false }
        selected = []
        message = "Moved \(Format.storage(freed)) to the Trash." + (failed > 0 ? " \(failed) item(s) could not be moved." : "")
    }
}
