import ActivityCore
import SwiftUI

/// Everything about one process: command line, folder, who started it, who signed it, open files and connections.
struct ProcessInspectorView: View {
    let pid: Int32
    let name: String
    @Environment(\.dismiss) private var dismiss
    @State private var details: ProcessDetails?
    @State private var hosts: [String: String] = [:]
    @AppStorage("resolveHostNames") private var resolveHosts = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(name).font(.title3.weight(.semibold))
                Text("pid \(pid)").foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
            Divider()
            if let d = details {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        section("Identity") {
                            row("Executable", d.executable ?? "–", selectable: true)
                            row("User", d.user)
                            if let start = d.startTime { row("Started", start.formatted(date: .abbreviated, time: .standard)) }
                            if let cwd = d.workingDirectory { row("Folder", cwd, selectable: true) }
                            if !d.arguments.isEmpty {
                                row("Command line", d.arguments.joined(separator: " "), selectable: true)
                            }
                        }
                        if let signature = d.signature {
                            section("Signature") {
                                row("Signed by", signature.authority ?? (signature.isApple ? "Apple" : "Unknown"))
                                if let team = signature.teamID { row("Team ID", team) }
                                if let identifier = signature.identifier { row("Identifier", identifier) }
                                row("Valid", signature.isValid ? "Yes" : "No — the code was changed after signing")
                                if let notarized = signature.isNotarized { row("Notarized", signature.isApple ? "Part of macOS" : (notarized ? "Yes" : "No")) }
                            }
                        }
                        if !d.parentChain.isEmpty {
                            section("Started by") {
                                Text(d.parentChain.map { "\($0.name) (\($0.pid))" }.joined(separator: "  ›  "))
                                    .font(.callout).textSelection(.enabled)
                            }
                        }
                        section("Network connections (\(d.connections.count))") {
                            Toggle("Look up host names (sends DNS queries)", isOn: $resolveHosts).toggleStyle(.checkbox).font(.caption)
                            if d.connections.isEmpty { Text("None right now.").foregroundStyle(.secondary).font(.callout) }
                            ForEach(d.connections) { connection in
                                HStack {
                                    Text(connection.proto).font(.caption.monospaced()).frame(width: 34, alignment: .leading)
                                    Text(hosts[connection.remote] ?? connection.remote).lineLimit(1).textSelection(.enabled)
                                    Spacer()
                                    Text(connection.state).font(.caption).foregroundStyle(.secondary)
                                }
                                .font(.callout)
                            }
                        }
                        section("Open files (\(d.openFiles.count))") {
                            if d.openFiles.isEmpty { Text("None visible (other users' processes hide this).").foregroundStyle(.secondary).font(.callout) }
                            ForEach(d.openFiles.prefix(200), id: \.self) { file in
                                Text(file.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                    .font(.caption.monospaced()).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                            }
                        }
                    }
                    .padding(16)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 620, height: 560)
        .task {
            let pid = pid
            details = await Task.detached(priority: .userInitiated) { ProcessInspector.details(pid: pid) }.value
            await resolve()
        }
        .onChange(of: resolveHosts) { _, _ in Task { await resolve() } }
    }

    private func resolve() async {
        guard resolveHosts, let connections = details?.connections else { return }
        hosts = await HostNames.resolve(connections.map(\.remote))
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            content()
        }
    }

    private func row(_ label: String, _ value: String, selectable: Bool = false) -> some View {
        HStack(alignment: .top) {
            Text(label).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
            Text(value).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
    }
}

/// Reverse DNS for "1.2.3.4:443" style addresses. Opt-in: it sends DNS queries.
enum HostNames {
    private static var cache: [String: String] = [:]
    private static let lock = NSLock()

    static func resolve(_ endpoints: [String]) async -> [String: String] {
        await withTaskGroup(of: (String, String?).self) { group in
            for endpoint in Set(endpoints) {
                group.addTask { (endpoint, lookup(endpoint)) }
            }
            var result: [String: String] = [:]
            for await (endpoint, name) in group { if let name { result[endpoint] = name } }
            return result
        }
    }

    private static func lookup(_ endpoint: String) -> String? {
        lock.lock(); if let hit = cache[endpoint] { lock.unlock(); return hit }; lock.unlock()
        // "[2a00::1]:443" or "1.2.3.4:443"
        var host = endpoint
        var port = ""
        if let colon = endpoint.lastIndex(of: ":") {
            host = String(endpoint[..<colon]).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            port = String(endpoint[endpoint.index(after: colon)...])
        }
        var hints = addrinfo(ai_flags: AI_NUMERICHOST, ai_family: AF_UNSPEC, ai_socktype: 0, ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &info) == 0, let info else { return nil }
        defer { freeaddrinfo(info) }
        var name = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(info.pointee.ai_addr, info.pointee.ai_addrlen, &name, socklen_t(name.count), nil, 0, NI_NAMEREQD) == 0 else { return nil }
        let resolved = String(cString: name) + (port.isEmpty ? "" : ":\(port)")
        lock.lock(); cache[endpoint] = resolved; lock.unlock()
        return resolved
    }
}
