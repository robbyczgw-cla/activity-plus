import ActivityCore
import SwiftUI

/// Which servers each app is talking to right now (read-only; nothing is blocked).
struct ConnectionsView: View {
    @Environment(Monitor.self) private var monitor
    @State private var byApp: [(app: AppGroup, connections: [Connection])] = []
    @State private var hosts: [String: String] = [:]
    @State private var expanded: Set<String> = []
    @State private var updated: Date?
    @AppStorage("resolveHostNames") private var resolveHosts = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Open connections to other computers, grouped by app. Local traffic is left out.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Toggle("Host names", isOn: $resolveHosts).toggleStyle(.switch).controlSize(.small)
                        .help("Looks up names for the addresses (sends DNS queries). Off by default.")
                    Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                }
                if byApp.isEmpty {
                    ContentUnavailableView(updated == nil ? "Looking…" : "No open connections", systemImage: "point.3.connected.trianglepath.dotted")
                        .frame(maxWidth: .infinity, minHeight: 240)
                }
                Card {
                    ForEach(byApp, id: \.app.id) { entry in
                        let remotes = Dictionary(grouping: entry.connections) { hostOnly(hosts[$0.remote] ?? $0.remote) }
                        HStack(spacing: 10) {
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                                .rotationEffect(.degrees(expanded.contains(entry.app.id) ? 90 : 0))
                            AppIconView(app: entry.app, size: 22)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(entry.app.name).fontWeight(.medium)
                                Text("\(remotes.count) destination\(remotes.count == 1 ? "" : "s") · \(entry.connections.count) connection\(entry.connections.count == 1 ? "" : "s")")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(Format.networkRate(entry.app.netInRate + entry.app.netOutRate)).monospacedDigit().foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if expanded.contains(entry.app.id) { expanded.remove(entry.app.id) } else { expanded.insert(entry.app.id) }
                        }
                        if expanded.contains(entry.app.id) {
                            ForEach(remotes.sorted { $0.value.count > $1.value.count }, id: \.key) { host, connections in
                                HStack {
                                    Spacer().frame(width: 44)
                                    Text(host).font(.callout).textSelection(.enabled)
                                    Spacer()
                                    Text(Set(connections.map(\.proto)).sorted().joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                                    Text("\(connections.count)×").font(.caption).monospacedDigit().foregroundStyle(.tertiary)
                                }
                            }
                        }
                        Divider().opacity(0.4)
                    }
                }
            }
            .padding(20)
        }
        .navigationTitle("Connections")
        .task {
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(10))
            }
        }
        .onChange(of: resolveHosts) { _, _ in Task { await load() } }
    }

    private func load() async {
        let all = await Task.detached(priority: .utility) { ProcessInspector.connectionsByPID() }.value
        let apps = monitor.snapshot.apps
        var result: [(AppGroup, [Connection])] = []
        for app in apps {
            let connections = app.processes.flatMap { all[$0.pid] ?? [] }.filter { !Self.isLocal($0.remote) }
            if !connections.isEmpty { result.append((app, connections)) }
        }
        byApp = result.sorted { $0.1.count > $1.1.count }.map { (app: $0.0, connections: $0.1) }
        updated = Date()
        if resolveHosts { hosts = await HostNames.resolve(byApp.flatMap { $0.connections.map(\.remote) }) }
    }

    private func hostOnly(_ endpoint: String) -> String {
        guard let colon = endpoint.lastIndex(of: ":") else { return endpoint }
        return String(endpoint[..<colon]).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    }

    static func isLocal(_ endpoint: String) -> Bool {
        endpoint.hasPrefix("127.") || endpoint.hasPrefix("[::1]") || endpoint.hasPrefix("::1") || endpoint.hasPrefix("localhost")
            || endpoint.hasPrefix("*") || endpoint.isEmpty
    }
}
