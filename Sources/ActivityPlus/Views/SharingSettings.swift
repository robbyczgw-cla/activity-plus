import ActivityCore
import SwiftUI

/// Settings → Sharing: let paired Macs read this Mac's summary on "Other Macs".
struct SharingSettings: View {
    @State private var server = ShareServer.shared
    @State private var removing: PairedViewer?

    var body: some View {
        @Bindable var server = server
        Form {
            Section {
                Toggle("Let other Macs see this Mac", isOn: $server.enabled)
                Text("Other Macs with Activity+ that you pair can then show this Mac's CPU, memory, disk, network, temperatures, battery and busiest apps. Read only: they cannot quit apps, change settings or see files.")
                    .font(.caption).foregroundStyle(.secondary)
                if server.enabled { statusLine }
                Text("Meant for your local network or a VPN like Tailscale. The first time sharing starts, macOS may ask whether Activity+ may find devices on your local network; allow it so your other Macs can find this one.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Pair a Mac") {
                if let pairing = server.pairing {
                    HStack(alignment: .center) {
                        Text(verbatim: Self.spaced(pairing.code))
                            .font(.system(size: 34, weight: .semibold, design: .monospaced))
                            .textSelection(.enabled)
                        Spacer()
                        VStack(alignment: .trailing, spacing: 4) {
                            Text(timerInterval: Date()...pairing.created.addingTimeInterval(PairingCode.lifetime), countsDown: true)
                                .monospacedDigit().foregroundStyle(.secondary)
                            Button("Cancel") { server.cancelPairing() }
                        }
                    }
                    Text("On the other Mac, open Other Macs in Activity+, click Pair… next to this Mac and enter this code. It works once.")
                        .font(.caption).foregroundStyle(.secondary)
                    if server.wrongCodeAt != nil {
                        Label("A wrong code was entered. After \(PairingCode.maxAttempts) wrong tries the code stops working.", systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                } else {
                    HStack {
                        Button("Pair a Mac…") { server.startPairing() }.disabled(!server.enabled || server.listeningPort == nil)
                        Spacer()
                    }
                    Text("Shows a 6-digit code for 5 minutes. Only a Mac that enters it can read this one.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Paired Macs") {
                if server.viewers.isEmpty {
                    Text("None yet.").foregroundStyle(.secondary)
                }
                ForEach(server.viewers) { viewer in
                    HStack {
                        Image(systemName: "desktopcomputer").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(viewer.name)
                            Text(detail(for: viewer)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Remove") { removing = viewer }
                    }
                }
                if !server.viewers.isEmpty {
                    Text("A removed Mac can no longer read this one, right away. To see this Mac there again, pair it again.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Remove \(removing?.name ?? "")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            presenting: removing) { viewer in
            Button("Remove", role: .destructive) { server.remove(viewer) }
        } message: { _ in
            Text("It stops seeing this Mac right away.")
        }
    }

    @ViewBuilder private var statusLine: some View {
        switch server.state {
        case .listening(let port):
            Label("Shared as “\(ThisMac.computerName)” on port \(String(port))", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .starting:
            Label("Starting…", systemImage: "hourglass").foregroundStyle(.secondary)
        case .failed(let reason):
            Label("Could not start sharing: \(reason)", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .stopped:
            EmptyView()
        }
    }

    private func detail(for viewer: PairedViewer) -> String {
        let paired = String(localized: "Paired \(viewer.pairedAt.formatted(date: .abbreviated, time: .omitted))")
        guard let read = server.lastRead[viewer.id] else { return paired }
        if Date().timeIntervalSince(read) < 30 { return paired + " · " + String(localized: "reading now") }
        return paired + " · " + String(localized: "last read \(read.formatted(.relative(presentation: .named)))")
    }

    static func spaced(_ code: String) -> String {
        code.count == 6 ? "\(code.prefix(3)) \(code.suffix(3))" : code
    }
}
