import ActivityCore
import SwiftUI

struct StartupItemsView: View {
    @Environment(AppServices.self) private var services
    @AppStorage("startupShowApple") private var showApple = false
    @State private var search = ""
    @State private var pendingDisable: StartupItem?
    @State private var errorMessage: String?

    private var groups: [(owner: String, bundle: String?, items: [StartupItem])] {
        let items = services.startupItems.filter { (showApple || !$0.isApple) && matches($0) }
        let grouped = Dictionary(grouping: items) { $0.ownerName }
        return grouped.map { ($0.key, $0.value.first?.ownerBundlePath, $0.value.sorted { $0.label < $1.label }) }
            .sorted { $0.owner.localizedCaseInsensitiveCompare($1.owner) == .orderedAscending }
    }

    var body: some View {
        let visible = services.startupItems.filter { showApple || !$0.isApple }
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(visible.count) items start automatically").font(.title2.weight(.semibold))
                        Text("\(visible.filter(\.isRunning).count) are running now. Turning one off stops it and keeps it from starting at login.")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("Show Apple items", isOn: $showApple).toggleStyle(.checkbox)
                    Button("Login Items…") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
                    }
                    .help("Apps that open at login are managed in System Settings")
                }
                if services.startupScannedAt == nil {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 160)
                }
                ForEach(groups, id: \.owner) { group in
                    Card {
                        HStack(spacing: 10) {
                            if let bundle = group.bundle {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: bundle)).resizable().frame(width: 24, height: 24)
                            } else {
                                Image(systemName: "gearshape.2").frame(width: 24, height: 24).foregroundStyle(.secondary)
                            }
                            Text(group.owner).font(.headline)
                            Spacer()
                        }
                        ForEach(group.items) { item in
                            StartupRow(item: item) { enabled in toggle(item, enabled: enabled) }
                        }
                    }
                }
            }
            .padding(20)
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Search startup items")
        .navigationTitle("Startup Items")
        .toolbar { Button("Rescan", systemImage: "arrow.clockwise") { services.scanStartupItems() } }
        .onAppear { if services.startupScannedAt == nil { services.scanStartupItems() } }
        .confirmationDialog("Turn off \(pendingDisable?.label ?? "")?", isPresented: Binding(get: { pendingDisable != nil }, set: { if !$0 { pendingDisable = nil } }), presenting: pendingDisable) { item in
            Button("Turn Off", role: .destructive) { apply(item, enabled: false) }
            Button("Cancel", role: .cancel) {}
        } message: { item in
            Text("It stops now and does not start at login. \(item.ownerName) may lose a background feature (updates, sync, helpers). You can turn it back on here.")
        }
        .alert("Could not change it", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") {}
        } message: { Text(errorMessage ?? "") }
    }

    private func matches(_ item: StartupItem) -> Bool {
        search.isEmpty || item.label.localizedCaseInsensitiveContains(search) || item.ownerName.localizedCaseInsensitiveContains(search)
    }

    private func toggle(_ item: StartupItem, enabled: Bool) {
        if enabled { apply(item, enabled: true) } else { pendingDisable = item }
    }

    private func apply(_ item: StartupItem, enabled: Bool) {
        do {
            try StartupItemsScanner.setEnabled(enabled, item: item)
        } catch {
            errorMessage = error.localizedDescription
        }
        services.scanStartupItems()
    }
}

private struct StartupRow: View {
    let item: StartupItem
    let toggle: (Bool) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle().fill(item.isRunning ? Color.green : Color.secondary.opacity(0.3)).frame(width: 8, height: 8).padding(.top, 6)
                .help(item.isRunning ? "Running (pid \(item.pid ?? 0))" : "Not running")
            VStack(alignment: .leading, spacing: 2) {
                Text(item.label).fontWeight(.medium).lineLimit(1)
                Text(item.program ?? item.plistPath ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 6) {
                    badge(scopeText)
                    if item.runAtLoad { badge("At login") }
                    if item.keepAlive { badge("Restarts itself") }
                }
            }
            Spacer()
            if item.canToggle {
                Toggle("", isOn: Binding(get: { !item.isDisabled }, set: toggle))
                    .toggleStyle(.switch).labelsHidden()
            } else {
                Menu("Admin") {
                    Button("Copy Terminal command to turn off") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("sudo " + StartupItemsScanner.adminCommand(toDisable: item), forType: .string)
                    }
                    if let plist = item.plistPath { Button("Show in Finder") { ProcessActions.reveal(plist) } }
                }
                .fixedSize()
                .help("System-wide items need an administrator. Copy the command and run it in Terminal.")
            }
        }
        .padding(.vertical, 3)
        .opacity(item.isDisabled ? 0.55 : 1)
    }

    private var scopeText: String {
        switch item.scope {
        case .userAgent: "Your account"
        case .globalAgent: "All users"
        case .globalDaemon: "System daemon"
        case .loginItem: "Login item"
        }
    }

    private func badge(_ text: String) -> some View {
        Text(text).font(.caption2).padding(.horizontal, 6).padding(.vertical, 1)
            .background(.quaternary, in: Capsule())
    }
}
