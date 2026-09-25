import ActivityCore
import SwiftUI

struct StorageView: View {
    @Environment(Monitor.self) private var monitor
    @Environment(AppServices.self) private var services
    @State private var selected: Set<String> = []
    @State private var expanded: Set<String> = []
    @State private var confirmTrash = false
    @State private var result: String?
    @State private var uninstalling: AppDiskUsage?

    private var selectedLocations: [StorageLocation] {
        services.storage.flatMap(\.locations).filter { selected.contains($0.path) }
    }

    var body: some View {
        let disk = monitor.snapshot.disk
        let cleanable = services.storage.reduce(UInt64(0)) { $0 + $1.cleanableBytes }
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Card {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(disk.volumeName).font(.headline)
                            BigNumber(text: Format.storage(disk.free) + " free", size: 26)
                        }
                        Spacer()
                        if let progress = services.storageProgress {
                            VStack(alignment: .trailing) {
                                ProgressView(value: progress.fraction).frame(width: 180)
                                Text(progress.item).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Button("Stop") { services.cancelStorageScan() }
                        } else {
                            Button(services.storageScannedAt == nil ? "Scan apps" : "Scan again") { services.scanStorage() }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                    UsageBar(fraction: 1 - Double(disk.free) / Double(max(1, disk.total)), tint: .orange)
                    if services.storageScannedAt != nil {
                        Text("Apps and their data use \(Format.storage(services.storage.reduce(0) { $0 + $1.totalBytes })). \(Format.storage(cleanable)) of it is caches and logs that apps rebuild on their own.")
                            .font(.callout).foregroundStyle(.secondary)
                    } else {
                        Text("Finds how much space each app takes with everything it stores in your Library, plus developer caches. Nothing is removed without asking; removed files go to the Trash.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }

                CleanupCandidatesCard()

                if let result {
                    Label(result, systemImage: "trash").padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                }

                if !services.storage.isEmpty {
                    HStack {
                        Button("Select all caches") {
                            selected = Set(services.storage.flatMap(\.locations).filter(\.isSafeToClean).map(\.path))
                        }
                        Button("Select none") { selected = [] }.disabled(selected.isEmpty)
                        Spacer()
                        Button("Move \(Format.storage(selectedLocations.reduce(0) { $0 + $1.bytes })) to Trash…") { confirmTrash = true }
                            .disabled(selected.isEmpty)
                    }
                    Card {
                        let top = services.storage.first?.totalBytes ?? 1
                        ForEach(services.storage) { app in
                            appRow(app, top: top)
                            if expanded.contains(app.id) {
                                ForEach(app.locations) { location in locationRow(location) }
                            }
                            Divider().opacity(0.4)
                        }
                    }
                }
            }
            .padding(20)
        }
        .navigationTitle("Storage")
        .confirmationDialog("Uninstall \(uninstalling?.name ?? "")?", isPresented: Binding(get: { uninstalling != nil }, set: { if !$0 { uninstalling = nil } }), presenting: uninstalling) { app in
            Button("Move to Trash", role: .destructive) { uninstall(app) }
            Button("Cancel", role: .cancel) {}
        } message: { app in
            let removed = Self.uninstallLocations(app, among: services.storage)
            let bytes = removed.reduce(UInt64(0)) { $0 + $1.bytes }
            let kept = app.locations.count - removed.count
            Text("\(app.name) and \(removed.count - 1) folders with its settings, caches and data (\(Format.storage(bytes))) move to the Trash."
                 + (kept > 0 ? " \(kept) shared folder(s) stay, because other apps use them too." : "")
                 + " If it is running, it is asked to quit first. You can put it back from the Trash until you empty it.")
        }
        .confirmationDialog("Move \(selectedLocations.count) items to the Trash?", isPresented: $confirmTrash) {
            Button("Move to Trash", role: .destructive, action: trash)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(Format.storage(selectedLocations.reduce(0) { $0 + $1.bytes })) moves to the Trash. Quit the apps first so they do not recreate their caches right away. Empty the Trash to actually free the space.")
        }
    }

    private func appRow(_ app: AppDiskUsage, top: UInt64) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                .rotationEffect(.degrees(expanded.contains(app.id) ? 90 : 0)).frame(width: 12)
            if let bundle = app.bundlePath {
                Image(nsImage: NSWorkspace.shared.icon(forFile: bundle)).resizable().frame(width: 24, height: 24)
            } else {
                Image(systemName: "shippingbox").frame(width: 24, height: 24).foregroundStyle(.brown)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(app.name).fontWeight(.medium)
                Text(app.cleanableBytes > 0 ? "\(Format.storage(app.cleanableBytes)) cleanable" : "\(app.locations.count) locations")
                    .font(.caption).foregroundStyle(app.cleanableBytes > 100_000_000 ? .green : .secondary)
            }
            Spacer()
            if Self.canUninstall(app) {
                Button("Uninstall…") { uninstalling = app }
                    .buttonStyle(.borderless).font(.callout)
                    .help("Moves \(app.name) and everything it keeps in your Library to the Trash")
            }
            UsageBar(fraction: Double(app.totalBytes) / Double(max(top, 1)), tint: .orange).frame(width: 120)
            Text(Format.storage(app.totalBytes)).monospacedDigit().frame(width: 80, alignment: .trailing)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.snappy) { if expanded.contains(app.id) { expanded.remove(app.id) } else { expanded.insert(app.id) } }
        }
    }

    private func locationRow(_ location: StorageLocation) -> some View {
        HStack(spacing: 10) {
            Spacer().frame(width: 22)
            if location.isSafeToClean {
                Toggle("", isOn: Binding(get: { selected.contains(location.path) }, set: { on in
                    if on { selected.insert(location.path) } else { selected.remove(location.path) }
                }))
                .toggleStyle(.checkbox).labelsHidden()
            } else {
                Image(systemName: "lock").foregroundStyle(.tertiary).frame(width: 14)
                    .help("App data or settings — not removed by Activity+")
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(kindText(location.kind)).font(.callout)
                Text(location.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Button { ProcessActions.reveal(location.path) } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(.borderless).help("Show in Finder")
            Text(Format.storage(location.bytes)).monospacedDigit().foregroundStyle(.secondary).frame(width: 80, alignment: .trailing)
        }
        .padding(.vertical, 2)
    }

    private func kindText(_ kind: StorageLocation.Kind) -> String {
        switch kind {
        case .bundle: "App"
        case .applicationSupport: "App data"
        case .caches: "Caches"
        case .containers: "Container"
        case .groupContainers: "Shared container"
        case .logs: "Logs"
        case .savedState: "Saved window state"
        case .preferences: "Settings"
        case .webData: "Web data"
        case .developer: "Developer cache"
        case .other: "Other"
        }
    }

    /// Only third-party apps in the Applications folders; never macOS apps or Activity+ itself.
    static func canUninstall(_ app: AppDiskUsage) -> Bool {
        guard let bundle = app.bundlePath, !bundle.hasPrefix("/System/") else { return false }
        if app.bundleID == Bundle.main.bundleIdentifier || app.bundleID?.hasPrefix("com.apple.") == true { return false }
        return bundle.hasPrefix("/Applications/") || bundle.hasPrefix(NSHomeDirectory() + "/Applications/")
    }

    /// What an uninstall removes. Shared group containers (used by other apps of the same developer)
    /// always stay; if another copy of the same app is installed, only this bundle goes.
    static func uninstallLocations(_ app: AppDiskUsage, among all: [AppDiskUsage]) -> [StorageLocation] {
        let bundleOnly = app.locations.filter { $0.kind == .bundle }
        let otherCopy = all.contains { $0.id != app.id && $0.bundleID != nil && $0.bundleID == app.bundleID }
        if otherCopy { return bundleOnly }
        return app.locations.filter { $0.kind != .groupContainers }
    }

    private func uninstall(_ app: AppDiskUsage) {
        if let bundleID = app.bundleID {
            for running in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) { running.terminate() }
        }
        // Give it a moment to quit, then move the bundle and its folders.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if let bundleID = app.bundleID, !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty {
                result = "\(app.name) is still running. Quit it and try again."
                return
            }
            let outcome = StorageScanner.moveToTrash(Self.uninstallLocations(app, among: services.storage))
            let moved = Set(app.locations.map(\.path)).subtracting(outcome.failures.keys)
            services.didTrash(moved)
            result = outcome.failures.isEmpty
                ? "Uninstalled \(app.name): \(Format.storage(outcome.freed)) moved to the Trash."
                : "\(app.name): \(Format.storage(outcome.freed)) moved to the Trash, \(outcome.failures.count) item(s) could not be moved (they may belong to another user or need an administrator)."
        }
    }

    private func trash() {
        let locations = selectedLocations
        let outcome = StorageScanner.moveToTrash(locations)
        let moved = Set(locations.map(\.path)).subtracting(outcome.failures.keys)
        services.didTrash(moved)
        selected.subtract(moved)
        result = "Moved \(Format.storage(outcome.freed)) to the Trash."
            + (outcome.failures.isEmpty ? "" : " \(outcome.failures.count) item(s) could not be moved.")
    }
}
