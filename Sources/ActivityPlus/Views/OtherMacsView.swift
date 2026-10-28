import ActivityCore
import SwiftUI

/// "Other Macs": Activity+ on other Macs (paired with a code) and Linux or other servers running node_exporter.
/// Read only; the machines are contacted every 5 seconds while this page is open.
struct OtherMacsView: View {
    @Environment(\.density) private var density
    @State private var model = RemoteMachinesModel.shared
    @State private var sheet: SheetKind?
    @State private var removing: RemoteMachine?

    enum SheetKind: Identifiable {
        case pair(name: String, existing: RemoteMachine?)
        case addMac
        case addServer
        case rename(RemoteMachine)

        var id: String {
            switch self {
            case .pair(let name, let existing): "pair-\(existing?.id.uuidString ?? name)"
            case .addMac: "addMac"
            case .addServer: "addServer"
            case .rename(let machine): "rename-\(machine.id)"
            }
        }
    }

    var body: some View {
        @Bindable var model = model
        ScrollView {
            VStack(alignment: .leading, spacing: density.stack) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Your other Macs with Activity+, and Linux or other servers with node_exporter. Read only: nothing here can change them.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Menu {
                        Button("Add a Linux or other server…") { sheet = .addServer }
                        Button("Add a Mac by address…") { sheet = .addMac }
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                    .fixedSize()
                    .help("Add a server running node_exporter, or a Mac that Bonjour cannot find (over a VPN)")
                }
                if !model.discovered.isEmpty { discoveredCard }
                if model.machines.isEmpty && model.discovered.isEmpty {
                    emptyState
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 330), spacing: density.grid, alignment: .top)], alignment: .leading, spacing: density.grid) {
                    ForEach(model.machines) { machine in
                        MachineCard(machine: machine, live: model.live[machine.id]) { action in
                            switch action {
                            case .pairAgain: sheet = .pair(name: machine.name, existing: machine)
                            case .rename: sheet = .rename(machine)
                            case .remove: removing = machine
                            }
                        }
                    }
                }
                if !model.machines.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Toggle("Notify me when one goes offline", isOn: $model.notifyOffline)
                        Text("Checks once a minute while this page is closed.").appFont(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(density.page)
        }
        .navigationTitle("Other Macs")
        .onAppear { model.pageAppeared() }
        .onDisappear { model.pageDisappeared() }
        .sheet(item: $sheet) { kind in
            switch kind {
            case .pair(let name, let existing): PairSheet(name: name, existing: existing)
            case .addMac: PairSheet(name: nil, existing: nil)
            case .addServer: AddServerSheet()
            case .rename(let machine): RenameSheet(machine: machine)
            }
        }
        .confirmationDialog("Remove \(removing?.name ?? "")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            presenting: removing) { machine in
            Button("Remove", role: .destructive) { model.remove(machine) }
        } message: { machine in
            Text(machine.kind == .mac ? "This Mac forgets the pairing. To stop the other Mac from sharing, remove this Mac in its Settings → Sharing too." : "Activity+ stops reading this server. Nothing changes on the server.")
        }
    }

    private var discoveredCard: some View {
        Card {
            CardHeader(title: "Found on this network", systemImage: "dot.radiowaves.left.and.right")
            ForEach(model.discovered) { found in
                HStack(spacing: 10) {
                    Image(systemName: "desktopcomputer").foregroundStyle(.secondary)
                    Text(found.name).fontWeight(.medium)
                    Spacer()
                    Button("Pair…") { sheet = .pair(name: found.name, existing: nil) }
                }
                .appFont(.callout)
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No other machines yet", systemImage: "desktopcomputer")
        } description: {
            Text("On another Mac with Activity+, turn on Settings → Sharing; it then shows up here. Linux and other servers work with node_exporter: choose Add.")
        } actions: {
            Button("Add a Linux or other server…") { sheet = .addServer }
        }
        .frame(maxWidth: .infinity, minHeight: 260)
    }
}

// MARK: - Card

private struct MachineCard: View {
    enum Action { case pairAgain, rename, remove }

    let machine: RemoteMachine
    let live: RemoteMachinesModel.Live?
    let perform: (Action) -> Void
    @Environment(\.density) private var density

    private var status: RemoteStatus? { live?.status }
    private var online: Bool { live?.online == true }

    var body: some View {
        Card {
            header
            if live?.needsPairing == true {
                HStack {
                    Label("This Mac needs to be paired again.", systemImage: "key").foregroundStyle(.orange)
                    Spacer()
                    Button("Pair Again…") { perform(.pairAgain) }
                }
                .appFont(.callout)
            }
            if let status {
                meters(status).opacity(online ? 1 : 0.5)
                figures(status).opacity(online ? 1 : 0.5)
                if !status.topCPU.isEmpty || !status.topMemory.isEmpty {
                    Divider().opacity(0.5)
                    topApps(status).opacity(online ? 1 : 0.5)
                }
            } else if live == nil {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Connecting…").foregroundStyle(.secondary) }.appFont(.callout)
            }
            footer
        }
    }

    private var icon: String {
        guard machine.kind == .mac else { return "server.rack" }
        let model = status?.model ?? ""
        if model.hasPrefix("MacBook") { return "laptopcomputer" }
        if model == "Mac mini" { return "macmini" }
        if model == "Mac Studio" { return "macstudio" }
        if model == "Mac Pro" { return "macpro.gen3" }
        return "desktopcomputer"
    }

    private var subtitle: String {
        var parts: [String] = []
        if let model = status?.model, !model.isEmpty { parts.append(model) }
        if machine.kind == .mac, let version = status?.appVersion { parts.append("Activity+ \(version)") }
        if let host = machine.host {
            let shown = host.contains(":") ? "[\(host)]" : host
            let port = machine.port.map { ":\($0)" } ?? ""
            let path = machine.path.flatMap { $0 == "/metrics" ? nil : $0 } ?? ""
            parts.append(shown + port + path)
        }
        return parts.joined(separator: " · ")
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: icon).appFont(.title2).foregroundStyle(.secondary).frame(width: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(machine.name).appFont(.headline).lineLimit(1)
                if !subtitle.isEmpty {
                    Text(subtitle).appFont(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail).help(machine.address)
                }
            }
            Spacer(minLength: 4)
            OnlineBadge(online: live?.online)
            Menu {
                if machine.kind == .mac { Button("Pair Again…") { perform(.pairAgain) } }
                Button("Rename…") { perform(.rename) }
                Divider()
                Button("Remove…", role: .destructive) { perform(.remove) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    private func meters(_ status: RemoteStatus) -> some View {
        VStack(spacing: density.space(8)) {
            Meter(label: "CPU", fraction: status.cpu.map { $0 / 100 }, value: cpuText(status), tint: .blue)
            Meter(label: "Memory", fraction: status.memoryFraction, value: memoryText(status), tint: pressureTint(status.memoryPressure))
            Meter(label: "Disk", fraction: status.diskUsedFraction, value: diskText(status), tint: .orange)
        }
    }

    private func cpuText(_ status: RemoteStatus) -> String {
        guard let cpu = status.cpu else { return "–" }
        var text = Format.percent(cpu)
        if machine.kind == .nodeExporter, let load = status.load1 {
            text += " · " + String(localized: "load \(String(format: "%.2f", locale: Format.locale, load))")
        }
        return text
    }

    private func memoryText(_ status: RemoteStatus) -> String {
        guard let used = status.memoryUsed, let total = status.memoryTotal else { return "–" }
        return String(localized: "\(Format.memory(used)) of \(Format.memory(total))")
    }

    private func diskText(_ status: RemoteStatus) -> String {
        guard let free = status.diskFree, let total = status.diskTotal else { return "–" }
        return String(localized: "\(Format.storage(free)) free of \(Format.storage(total))")
    }

    private func pressureTint(_ pressure: String?) -> Color {
        switch pressure {
        case "warning": .yellow
        case "critical": .red
        default: .green
        }
    }

    /// One row when it fits the card, otherwise network and uptime on the first line, the rest below.
    private func figures(_ status: RemoteStatus) -> some View {
        let spacing = density.space(12)
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: spacing) {
                network(status)
                extras(status)
                Spacer(minLength: 0)
                uptime(status)
            }
            VStack(alignment: .leading, spacing: density.space(6)) {
                HStack(spacing: spacing) {
                    network(status)
                    Spacer(minLength: 0)
                    uptime(status)
                }
                HStack(spacing: spacing) { extras(status) }
            }
        }
    }

    @ViewBuilder private func network(_ status: RemoteStatus) -> some View {
        Figure(systemImage: "arrow.down", value: status.networkIn.map(Format.networkRate) ?? "–", help: "Received")
        Figure(systemImage: "arrow.up", value: status.networkOut.map(Format.networkRate) ?? "–", help: "Sent")
    }

    @ViewBuilder private func extras(_ status: RemoteStatus) -> some View {
        if let temperature = status.temperature {
            Figure(systemImage: "thermometer.medium", value: Format.temperature(temperature, unit: false), help: "Hottest sensor")
        }
        if let battery = status.battery {
            Figure(systemImage: battery.charging ? "battery.100percent.bolt" : "battery.75percent", value: Format.percent(battery.percent), help: "Battery")
        }
    }

    @ViewBuilder private func uptime(_ status: RemoteStatus) -> some View {
        if let uptime = status.uptime {
            Figure(systemImage: "clock", value: Format.duration(uptime), help: "Up for")
        }
    }

    private func topApps(_ status: RemoteStatus) -> some View {
        HStack(alignment: .top, spacing: density.space(16)) {
            AppColumn(title: "Busiest", rows: status.topCPU.prefix(3).map { ($0.name, Format.percent($0.cpu)) })
            AppColumn(title: "Most memory", rows: status.topMemory.prefix(3).map { ($0.name, Format.memory($0.memory)) })
        }
    }

    private var footer: some View {
        HStack(spacing: 4) {
            if let lastSeen = live?.lastSeen {
                if online {
                    Text("Updated \(lastSeen.formatted(date: .omitted, time: .standard))")
                } else {
                    Text("Offline since \(lastSeen.formatted(.relative(presentation: .named)))")
                }
            }
            if live?.online == false, let error = live?.error, live?.needsPairing != true {
                if live?.lastSeen != nil { Text(verbatim: "·") }
                Text(error).lineLimit(1).truncationMode(.tail).help(error)
            }
        }
        .appFont(.caption)
        .foregroundStyle(.secondary)
    }
}

private struct OnlineBadge: View {
    let online: Bool?

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label)
        }
        .appFont(.caption, weight: .medium)
        .foregroundStyle(.secondary)
    }

    private var color: Color {
        switch online {
        case true?: .green
        case false?: .red
        case nil: .gray
        }
    }

    private var label: LocalizedStringKey {
        switch online {
        case true?: "Online"
        case false?: "Offline"
        case nil: "Checking"
        }
    }
}

private struct Meter: View {
    let label: String
    let fraction: Double?
    let value: String
    let tint: Color

    var body: some View {
        VStack(spacing: 3) {
            HStack {
                Text(LocalizedStringKey(label)).foregroundStyle(.secondary)
                Spacer()
                Text(value).monospacedDigit().fontWeight(.medium)
            }
            .appFont(.callout)
            UsageBar(fraction: fraction ?? 0, tint: tint).opacity(fraction == nil ? 0.3 : 1)
        }
    }
}

private struct Figure: View {
    let systemImage: String
    let value: String
    let help: LocalizedStringKey

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: systemImage).foregroundStyle(.secondary)
            Text(value).monospacedDigit()
        }
        .lineLimit(1)
        .fixedSize()
        .appFont(.callout)
        .help(help)
    }
}

private struct AppColumn: View {
    let title: LocalizedStringKey
    let rows: [(String, String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).appFont(.caption, weight: .semibold).foregroundStyle(.secondary)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack {
                    Text(row.0).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 4)
                    Text(row.1).monospacedDigit().foregroundStyle(.secondary)
                }
                .appFont(.callout)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Sheets

/// Pairs with a Mac found through Bonjour (name given), or one added by address (name nil: asks for the address).
private struct PairSheet: View {
    let name: String?
    let existing: RemoteMachine?
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var code = ""
    @State private var error: String?
    @State private var working = false

    private var digits: String { code.filter(\.isNumber) }
    private var byAddress: Bool { name == nil || (existing?.host != nil) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(name.map { String(localized: "Pair with \($0)") } ?? String(localized: "Add a Mac by address"))
                .appFont(.title3, weight: .semibold)
            if name == nil {
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Address", text: $address, prompt: Text(verbatim: "studio.example.ts.net"))
                        .textFieldStyle(.roundedBorder)
                    Text("For a Mac that this Mac cannot find on its own, for example over a VPN like Tailscale. Activity+ uses port \(String(RemoteMachine.sharePort)) unless you add another one (name:port).")
                        .appFont(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Text("On \(name ?? String(localized: "the other Mac")), open Activity+ Settings → Sharing and click Pair a Mac. Enter the 6-digit code shown there.")
                .fixedSize(horizontal: false, vertical: true)
            TextField("Code", text: $code, prompt: Text(verbatim: "123456"))
                .appFont(size: 24, weight: .medium, design: .monospaced)
                // A rounded-border field keeps its height with a large font and clips the digits.
                .textFieldStyle(.plain)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.background))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(.separator))
                .onSubmit(pair)
            if let error {
                Text(error).foregroundStyle(.red).appFont(.callout).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if working { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Pair", action: pair)
                    .keyboardShortcut(.defaultAction)
                    .disabled(digits.count != 6 || working || (name == nil && address.trimmingCharacters(in: .whitespaces).isEmpty))
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func pair() {
        guard digits.count == 6, !working else { return }
        var host: String?
        var port: UInt16?
        if name == nil {
            do {
                let parsed = try RemoteMachine.parseAddress(address, defaultPort: RemoteMachine.sharePort, defaultPath: "/")
                host = parsed.host
                port = parsed.port
            } catch {
                self.error = error.localizedDescription
                return
            }
        }
        working = true
        error = nil
        Task {
            do {
                try await RemoteMachinesModel.shared.pair(serviceName: existing?.serviceName ?? (byAddress ? nil : name), host: existing?.host ?? host,
                                                          port: existing?.port ?? port, code: digits, replacing: existing)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            working = false
        }
    }
}

private struct AddServerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var name = ""
    @State private var error: String?
    @State private var canForce = false
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add a Linux or other server").appFont(.title3, weight: .semibold)
            Text("Activity+ reads Prometheus node_exporter, the usual monitoring agent for Linux. Install it on the server (on Debian and Ubuntu: prometheus-node-exporter) and enter its address.")
                .fixedSize(horizontal: false, vertical: true)
            Form {
                TextField("Address", text: $address, prompt: Text(verbatim: "http://server:9100/metrics"))
                TextField("Name", text: $name, prompt: Text("Optional"))
            }
            .formStyle(.columns)
            Text("node_exporter has no password: keep it on your local network or a VPN like Tailscale, not open to the internet.")
                .appFont(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error {
                Text(error).foregroundStyle(.red).appFont(.callout).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if working { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                if canForce { Button("Add Anyway") { add(force: true) } }
                Button("Add") { add(force: false) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty || working)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func add(force: Bool) {
        working = true
        error = nil
        canForce = false
        Task {
            do {
                try await RemoteMachinesModel.shared.addServer(address: address, name: name, force: force)
                dismiss()
            } catch let failure as RemoteMachine.AddressError {
                error = failure.localizedDescription
            } catch {
                self.error = String(localized: "Could not read it: \(error.localizedDescription)")
                // It may just be off right now.
                canForce = true
            }
            working = false
        }
    }
}

private struct RenameSheet: View {
    let machine: RemoteMachine
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename").appFont(.title3, weight: .semibold)
            TextField("Name", text: $name).textFieldStyle(.roundedBorder).onSubmit(save)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Rename", action: save).keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 340)
        .onAppear { name = machine.name }
    }

    private func save() {
        RemoteMachinesModel.shared.rename(machine, to: name)
        dismiss()
    }
}

// MARK: - Snapshots

extension OtherMacsView {
    /// The sheets, for snapshot runs (they only appear after a click otherwise).
    @MainActor static func renderSnapshots(to dir: String) {
        SnapshotRunner.snapshotHosted(AddServerSheet().background(Color(nsColor: .windowBackgroundColor)), size: nil, to: "\(dir)/othermacs-add-server.png")
        SnapshotRunner.snapshotHosted(PairSheet(name: "Studio", existing: nil).background(Color(nsColor: .windowBackgroundColor)), size: nil, to: "\(dir)/othermacs-pair.png")
        SnapshotRunner.snapshotHosted(PairSheet(name: nil, existing: nil).background(Color(nsColor: .windowBackgroundColor)), size: nil, to: "\(dir)/othermacs-add-mac.png")
    }
}
