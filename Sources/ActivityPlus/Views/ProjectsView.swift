import ActivityCore
import SwiftUI

struct ProjectsView: View {
    @Environment(\.density) private var density
    @Environment(AppServices.self) private var services
    @State private var pendingStop: DevServer?
    @State private var toast: String?
    @State private var showOtherPorts = false

    var body: some View {
        let projects = services.projects.projects
        let servers = projects.flatMap(\.servers)
        let idle = servers.filter { $0.isIdle() }.count
        ScrollView {
            VStack(alignment: .leading, spacing: density.stack) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(servers.count == 1 ? "1 dev server" : "\(servers.count) dev servers")
                            .appFont(.title2, weight: .semibold)
                        Text(idle == 0 ? "All of them are doing something." : "\(idle) idle for a while — they still hold memory and ports.")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { services.scanProjects() } label: { Label("Rescan", systemImage: "arrow.clockwise") }
                }

                if let toast {
                    Label(toast, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                if projects.isEmpty {
                    ContentUnavailableView("No dev servers running", systemImage: "hammer",
                                           description: Text("Servers you start from a project folder (node, python, go, rails…) appear here with their ports."))
                        .frame(maxWidth: .infinity, minHeight: 240)
                }

                ForEach(projects) { project in
                    Card {
                        HStack {
                            Image(systemName: "folder.fill").foregroundStyle(.blue)
                            Text(project.name).appFont(.headline)
                            Text(project.root.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                .appFont(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button("Show in Finder") { ProcessActions.reveal(project.root) }.buttonStyle(.link).appFont(.caption)
                        }
                        ForEach(project.servers) { server in
                            ServerRow(server: server) { pendingStop = server }
                            if server.id != project.servers.last?.id { Divider().opacity(0.4) }
                        }
                    }
                }

                if !services.projects.otherPorts.isEmpty {
                    DisclosureGroup(isExpanded: $showOtherPorts) {
                        VStack(spacing: 4) {
                            ForEach(services.projects.otherPorts) { port in
                                HStack {
                                    Text(String(port.port)).monospacedDigit().fontWeight(.medium).textColumn(width: 60, alignment: .leading)
                                    Text(port.processName)
                                    Spacer()
                                    Text(port.address).foregroundStyle(.secondary).appFont(.caption)
                                }
                                .appFont(.callout)
                            }
                        }
                        .padding(.top, 6)
                    } label: {
                        Text("Other open ports (\(services.projects.otherPorts.count))").appFont(.headline)
                    }
                    .padding(16)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
                }
            }
            .padding(density.page)
            .animation(.snappy, value: toast)
        }
        .navigationTitle("Projects")
        .onAppear { services.scanProjects() }
        .confirmationDialog("Stop \(pendingStop?.command ?? "")?", isPresented: Binding(get: { pendingStop != nil }, set: { if !$0 { pendingStop = nil } }), presenting: pendingStop) { server in
            Button("Stop", role: .destructive) { stop(server) }
            Button("Cancel", role: .cancel) {}
        } message: { server in
            let ports = server.ports.map(String.init).joined(separator: ", ")
            Text("\(server.pids.count) processes will be asked to stop. Port \(ports) will be freed.")
        }
    }

    private func stop(_ server: DevServer) {
        let project = (server.directory.map { ($0 as NSString).lastPathComponent }) ?? server.name
        if ProjectScanner.stop(server) {
            let freedPorts = server.ports.map(String.init).joined(separator: ", ")
            toast = String(localized: "\(project) stopped. \(Format.memory(server.memory)) and port \(freedPorts) are free.")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { services.scanProjects() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { toast = nil }
        } else {
            toast = "macOS did not allow stopping \(server.name)."
        }
    }
}

private struct ServerRow: View {
    let server: DevServer
    let onStop: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(spacing: 3) {
                ForEach(server.ports.prefix(3), id: \.self) { port in
                    Link(String(port), destination: URL(string: "http://localhost:\(port)")!)
                        .appFont(.callout, weight: .semibold, design: .monospaced)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                        .help(String(localized: "Open http://localhost:\(port)"))
                }
            }
            .frame(width: 66)
            VStack(alignment: .leading, spacing: 2) {
                Text(server.command).fontWeight(.medium).lineLimit(1)
                Text(statusText).appFont(.caption).foregroundStyle(server.isIdle() ? .orange : .secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(Format.memory(server.memory)).monospacedDigit()
                Text(Format.percent(server.cpuPercent, decimals: 1) + String(localized: " CPU")).appFont(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Button("Stop…", action: onStop)
        }
        .padding(.vertical, 4)
    }

    private var statusText: String {
        let runtime = server.name
        switch server.activity() {
        case .working: return "\(runtime) · working"
        case .idle(let since): return "\(runtime) · idle \(Format.duration(since))"
        case .barelyUsed(let uptime): return "\(runtime) · up \(Format.duration(uptime)), barely used"
        }
    }
}
