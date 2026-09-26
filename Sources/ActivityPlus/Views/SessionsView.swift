import ActivityCore
import AppKit
import Charts
import SwiftUI
import UniformTypeIdentifiers

/// Record a build, a render or a slowdown at full rate, compare it with another one, export it.
struct SessionsView: View {
    @Environment(AppServices.self) private var services
    @State private var sessions: [RecordingSession] = []
    @State private var selected: Int64?
    @State private var compare: Int64?
    @State private var newName = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                RecorderCard(newName: $newName)
                if sessions.isEmpty {
                    Card {
                        Text("Start a recording before a build, a render, an export or whatever makes your Mac slow. Activity+ measures every second while it runs, even with this window closed, and keeps the result so you can compare it with the next one or export it as CSV or JSON.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Card {
                        CardHeader(title: "Recorded sessions", systemImage: "list.bullet.rectangle", tint: .red)
                        ForEach(sessions) { session in
                            SessionRow(session: session, selected: selected == session.id, comparing: compare == session.id,
                                       select: { selected = session.id; if compare == session.id { compare = nil } },
                                       toggleCompare: { compare = compare == session.id ? nil : session.id })
                        }
                        Text("Click a session to see it; tick a second one to compare.").font(.caption).foregroundStyle(.tertiary)
                    }
                }
                if let session = sessions.first(where: { $0.id == selected }) {
                    SessionDetail(session: session, other: sessions.first { $0.id == compare && $0.id != session.id })
                        .id("\(session.id)-\(compare ?? 0)-\(services.sessionsRevision)")
                }
            }
            .padding(20)
        }
        .navigationTitle("Sessions")
        .task(id: services.sessionsRevision) { reload() }
    }

    private func reload() {
        sessions = services.history.sessions()
        if selected == nil || !sessions.contains(where: { $0.id == selected }) {
            selected = sessions.first(where: { $0.ended != nil })?.id ?? sessions.first?.id
        }
        if let compare, !sessions.contains(where: { $0.id == compare }) { self.compare = nil }
    }
}

private struct RecorderCard: View {
    @Environment(AppServices.self) private var services
    @Environment(Monitor.self) private var monitor
    @Binding var newName: String

    var body: some View {
        Card {
            if let recording = services.recording {
                HStack(spacing: 12) {
                    Circle().fill(.red).frame(width: 12, height: 12)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(recording.name).font(.headline)
                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            Text("Recording · \(Format.elapsed(recording.duration)) · CPU \(Format.percent(monitor.snapshot.cpu.total)) · memory \(Format.memory(monitor.snapshot.memory.used))")
                                .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                    Spacer()
                    Button("Stop Recording", systemImage: "stop.fill") { services.stopRecording() }
                        .buttonStyle(.borderedProminent).tint(.red)
                }
            } else {
                HStack(spacing: 12) {
                    Image(systemName: "record.circle").font(.title2).foregroundStyle(.red)
                    TextField("Name, e.g. \"Xcode clean build\"", text: $newName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(start)
                    Button("Start Recording", systemImage: "record.circle.fill", action: start)
                        .buttonStyle(.borderedProminent).tint(.red)
                }
                Text("Measures every \(Format.elapsed(monitor.interval)) until you stop it. You can also start and stop from the menu bar (right-click).")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func start() {
        services.startRecording(name: newName)
        newName = ""
    }
}

private struct SessionRow: View {
    let session: RecordingSession
    let selected: Bool
    let comparing: Bool
    let select: () -> Void
    let toggleCompare: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Toggle("", isOn: Binding(get: { comparing }, set: { _ in toggleCompare() }))
                .toggleStyle(.checkbox).labelsHidden().disabled(selected || session.ended == nil)
                .help("Compare with the selected session")
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    if session.ended == nil { Circle().fill(.red).frame(width: 7, height: 7) }
                    Text(session.name).fontWeight(selected ? .semibold : .regular).lineLimit(1)
                }
                Text("\(session.started.formatted(date: .abbreviated, time: .shortened)) · \(Format.elapsed(session.duration))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Group {
                Text("⌀ \(Format.percent(session.averageCPU))").frame(width: 80, alignment: .trailing)
                Text(Format.memory(UInt64(session.peakMemory))).frame(width: 80, alignment: .trailing)
                Text(session.energyWh > 0 ? String(format: "%.1f Wh", session.energyWh) : "–").frame(width: 70, alignment: .trailing)
            }
            .font(.callout).monospacedDigit().foregroundStyle(.secondary)
        }
        .padding(.vertical, 5).padding(.horizontal, 8)
        .background(selected ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
    }
}

private struct SessionDetail: View {
    @Environment(AppServices.self) private var services
    let session: RecordingSession
    let other: RecordingSession?
    @State private var samples: [SessionSample] = []
    @State private var otherSamples: [SessionSample] = []
    @State private var apps: [SessionApp] = []
    @State private var confirmDelete = false
    @State private var renaming = false
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Card {
                HStack {
                    CardHeader(title: session.name, systemImage: "waveform.path.ecg", tint: .red,
                               trailing: session.started.formatted(date: .abbreviated, time: .standard))
                }
                HStack(alignment: .top, spacing: 24) {
                    summary(session, title: other == nil ? nil : "This session")
                    if let other { summary(other, title: "Compared with \"\(other.name)\"", reference: session) }
                }
                chart(title: "CPU", unit: "%", value: \.cpu)
                chart(title: "Memory", unit: "GB", value: \.memory, scale: 1 / 1_073_741_824)
                if samples.contains(where: { $0.power != nil }) {
                    chart(title: "Power", unit: "W", value: \.powerValue)
                }
                HStack {
                    Button("Export CSV…", systemImage: "tablecells") { export(csv: true) }
                    Button("Export JSON…", systemImage: "curlybraces") { export(csv: false) }
                    Spacer()
                    Button("Rename…") { name = session.name; renaming = true }
                    Button("Delete…", role: .destructive) { confirmDelete = true }
                }
                .disabled(session.ended == nil)
            }
            if !apps.isEmpty {
                Card {
                    CardHeader(title: "Apps during this session", systemImage: "square.stack.3d.up", tint: .blue)
                    HStack {
                        Text("App").frame(maxWidth: .infinity, alignment: .leading)
                        Text("⌀ CPU").frame(width: 70, alignment: .trailing)
                        Text("Peak CPU").frame(width: 80, alignment: .trailing)
                        Text("Peak memory").frame(width: 100, alignment: .trailing)
                        Text("Energy").frame(width: 70, alignment: .trailing)
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    ForEach(apps.prefix(12)) { app in
                        HStack {
                            VStack(alignment: .leading, spacing: 0) {
                                Text(app.name).lineLimit(1)
                                if let top = app.topProcess, top != app.name {
                                    Text("mostly \(top)").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Text(Format.percent(app.averageCPU)).frame(width: 70, alignment: .trailing)
                            Text(Format.percent(app.peakCPU)).frame(width: 80, alignment: .trailing)
                            Text(Format.memory(UInt64(app.peakMemory))).frame(width: 100, alignment: .trailing)
                            Text(app.energyWh > 0.005 ? String(format: "%.2f Wh", app.energyWh) : "–").frame(width: 70, alignment: .trailing)
                        }
                        .font(.callout).monospacedDigit()
                    }
                }
            }
        }
        .task {
            samples = services.history.sessionSamples(session.id)
            apps = services.history.sessionApps(session.id)
            if let other { otherSamples = services.history.sessionSamples(other.id) }
        }
        .confirmationDialog("Delete \"\(session.name)\"?", isPresented: $confirmDelete) {
            Button("Delete Session", role: .destructive) { services.deleteSession(session.id) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its measurements are removed from Activity+'s history. Export it first if you want to keep a copy.")
        }
        .alert("Rename session", isPresented: $renaming) {
            TextField("Name", text: $name)
            Button("Rename") { if !name.trimmingCharacters(in: .whitespaces).isEmpty { services.renameSession(session.id, to: name) } }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func summary(_ s: RecordingSession, title: String?, reference: RecordingSession? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let title { Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
            line("Duration", Format.elapsed(s.duration), reference.map { delta(s.duration, $0.duration, format: Format.duration) })
            line("Average CPU", Format.percent(s.averageCPU), reference.map { delta(s.averageCPU, $0.averageCPU) { Format.percent($0) } })
            line("Peak CPU", Format.percent(s.peakCPU), nil)
            line("Peak memory", Format.memory(UInt64(s.peakMemory)), reference.map { delta(s.peakMemory, $0.peakMemory) { Format.memory(UInt64($0)) } })
            if s.energyWh > 0 { line("Energy", String(format: "%.1f Wh", s.energyWh), reference.map { delta(s.energyWh, $0.energyWh) { String(format: "%.1f Wh", $0) } }) }
            line("Disk", Format.storage(UInt64(s.diskBytes)), nil)
            line("Network", Format.storage(UInt64(s.networkBytes)), nil)
        }
        .frame(width: 300, alignment: .leading)
    }

    private func line(_ label: String, _ value: String, _ change: Text?) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
            if let change { change.font(.caption).monospacedDigit() }
        }
        .font(.callout)
    }

    /// How the compared session differs: "+12 %" style, green when it is lower (less time, less load).
    private func delta(_ value: Double, _ base: Double, format: (Double) -> String) -> Text {
        guard base > 0 else { return Text("") }
        let change = (value - base) / base * 100
        let sign = change >= 0 ? "+" : "−"
        return Text("\(sign)\(Int(abs(change).rounded())) %").foregroundStyle(change <= 0 ? .green : .orange)
    }

    private func chart(title: String, unit: String, value: KeyPath<SessionSample, Double>, scale: Double = 1) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(title) (\(unit))").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Chart {
                ForEach(Array(samples.enumerated()), id: \.offset) { _, s in
                    LineMark(x: .value("Seconds", s.date.timeIntervalSince(session.started)), y: .value(title, s[keyPath: value] * scale),
                             series: .value("Session", "this"))
                        .foregroundStyle(.red)
                }
                if let other {
                    ForEach(Array(otherSamples.enumerated()), id: \.offset) { _, s in
                        LineMark(x: .value("Seconds", s.date.timeIntervalSince(other.started)), y: .value(title, s[keyPath: value] * scale),
                                 series: .value("Session", "other"))
                            .foregroundStyle(.gray.opacity(0.7))
                    }
                }
            }
            .chartXAxisLabel("seconds since start")
            .frame(height: 110)
        }
    }

    private func export(csv: Bool) {
        let panel = NSSavePanel()
        let base = session.name.replacingOccurrences(of: "/", with: "-")
        panel.nameFieldStringValue = "\(base).\(csv ? "csv" : "json")"
        panel.allowedContentTypes = [csv ? .commaSeparatedText : .json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let data = csv ? Data(SessionExport.csv(samples, started: session.started).utf8)
                       : SessionExport.json(session, samples: samples, apps: apps)
        try? data.write(to: url, options: .atomic)
    }
}

private extension SessionSample {
    var powerValue: Double { power ?? 0 }
}
