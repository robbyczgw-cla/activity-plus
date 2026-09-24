import ActivityCore
import SwiftUI

/// Apps sorted by one metric; each expands into its processes. Quit and force quit always ask first.
struct AppListView: View {
    @Environment(Monitor.self) private var monitor
    let metric: Metric
    var searchText: String = ""
    var limit: Int?

    @AppStorage("showSystemProcesses") private var showSystem = true
    @State private var expanded: Set<String> = []
    @State private var pendingQuit: QuitRequest?
    @State private var errorMessage: String?

    struct QuitRequest: Identifiable {
        enum Target { case app(AppGroup), process(ProcessSample) }
        let target: Target
        let force: Bool
        var id: String {
            switch target {
            case .app(let app): "app-\(app.id)-\(force)"
            case .process(let process): "pid-\(process.pid)-\(force)"
            }
        }
        var title: String {
            let verb = force ? "Force quit" : "Quit"
            switch target {
            case .app(let app): return "\(verb) \(app.name)?"
            case .process(let process): return "\(verb) \(process.name)?"
            }
        }
        var message: String {
            switch target {
            case .app(let app):
                let count = app.processes.count
                let base = count == 1 ? "1 process will close." : "\(count) processes will close."
                return force ? base + " Unsaved changes will be lost." : base
            case .process(let process):
                return "Process \(process.pid) will close." + (force ? " Unsaved changes will be lost." : "")
            }
        }
    }

    private var apps: [AppGroup] {
        var list = monitor.snapshot.apps
        if !showSystem { list.removeAll { $0.kind == .system } }
        if !searchText.isEmpty {
            list = list.filter { app in
                app.name.localizedCaseInsensitiveContains(searchText)
                    || app.processes.contains { $0.name.localizedCaseInsensitiveContains(searchText) || "\($0.pid)" == searchText }
            }
        }
        list.sort { metric.value($0) > metric.value($1) }
        if let limit { return Array(list.prefix(limit)) }
        return list
    }

    var body: some View {
        let scale = metric.scale(in: monitor.snapshot)
        LazyVStack(spacing: 0) {
            ForEach(apps) { app in
                AppRow(app: app, metric: metric, scale: scale, isExpanded: expanded.contains(app.id)) {
                    withAnimation(.snappy) {
                        if expanded.contains(app.id) { expanded.remove(app.id) } else { expanded.insert(app.id) }
                    }
                } onQuit: { force in
                    pendingQuit = QuitRequest(target: .app(app), force: force)
                }
                if expanded.contains(app.id) {
                    ForEach(app.processes.sorted { metric.value($0) > metric.value($1) }) { process in
                        ProcessRow(process: process, metric: metric, scale: scale) { force in
                            pendingQuit = QuitRequest(target: .process(process), force: force)
                        }
                    }
                }
                Divider().opacity(0.4)
            }
        }
        .confirmationDialog(pendingQuit?.title ?? "", isPresented: Binding(
            get: { pendingQuit != nil }, set: { if !$0 { pendingQuit = nil } }
        ), presenting: pendingQuit) { request in
            Button(request.force ? "Force Quit" : "Quit", role: .destructive) { perform(request) }
            Button("Cancel", role: .cancel) {}
        } message: { request in
            Text(request.message)
        }
        .alert("Could not quit", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func perform(_ request: QuitRequest) {
        let outcome: ProcessActions.Outcome
        switch request.target {
        case .app(let app): outcome = ProcessActions.quit(app, force: request.force)
        case .process(let process): outcome = ProcessActions.quit(process, force: request.force)
        }
        if case .denied(let message) = outcome { errorMessage = message }
    }
}

private struct AppRow: View {
    let app: AppGroup
    let metric: Metric
    let scale: Double
    let isExpanded: Bool
    let toggle: () -> Void
    let onQuit: (Bool) -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .frame(width: 12)
            AppIconView(app: app, size: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(app.name).fontWeight(.medium).lineLimit(1)
                Text(app.processes.count == 1 ? "1 process" : "\(app.processes.count) processes")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            if hovering {
                Button { onQuit(false) } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Quit \(app.name)…")
            }
            UsageBar(fraction: metric.value(app) / scale, tint: metric.tint)
                .frame(width: 90)
            Text(metric.format(metric.value(app)))
                .monospacedDigit()
                .frame(width: 84, alignment: .trailing)
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 10)
        .contentShape(Rectangle())
        .background(hovering ? Color.primary.opacity(0.04) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .onHover { hovering = $0 }
        .onTapGesture(perform: toggle)
        .contextMenu {
            Button("Quit \(app.name)…") { onQuit(false) }
            Button("Force Quit \(app.name)…") { onQuit(true) }
            Divider()
            if let path = app.bundlePath ?? app.processes.first?.path {
                Button("Show in Finder") { ProcessActions.reveal(path) }
            }
            Button("Copy Name") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(app.name, forType: .string)
            }
        }
    }
}

private struct ProcessRow: View {
    let process: ProcessSample
    let metric: Metric
    let scale: Double
    let onQuit: (Bool) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Spacer().frame(width: 46)
            VStack(alignment: .leading, spacing: 1) {
                Text(process.name).lineLimit(1).truncationMode(.middle)
                Text("pid \(process.pid)" + (process.hasDetails ? "" : " · limited details"))
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 12)
            UsageBar(fraction: metric.value(process) / scale, tint: metric.tint.opacity(0.7))
                .frame(width: 90)
            Text(metric.format(metric.value(process)))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 84, alignment: .trailing)
        }
        .font(.callout)
        .padding(.vertical, 4)
        .padding(.horizontal, 10)
        .contextMenu {
            Button("Quit Process…") { onQuit(false) }
            Button("Force Quit Process…") { onQuit(true) }
            if let path = process.path {
                Divider()
                Button("Show in Finder") { ProcessActions.reveal(path) }
                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(path, forType: .string)
                }
            }
        }
    }
}
