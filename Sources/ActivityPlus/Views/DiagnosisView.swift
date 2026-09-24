import ActivityCore
import SwiftUI

struct DiagnosisView: View {
    @Environment(Monitor.self) private var monitor
    @Environment(AppServices.self) private var services
    @Binding var selection: SidebarItem?
    @State private var diagnosis: Diagnosis?
    @State private var pendingQuit: AppGroup?
    @State private var confirmRestart = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let diagnosis {
                    verdict(diagnosis)
                    ForEach(diagnosis.findings) { finding in
                        FindingCard(finding: finding) { perform($0) }
                    }
                } else {
                    ProgressView("Looking at your Mac…").frame(maxWidth: .infinity, minHeight: 200)
                }
            }
            .padding(20)
        }
        .navigationTitle("Why is my Mac slow?")
        .task {
            if services.startupScannedAt == nil { services.scanStartupItems() }
            // The first samples have no history yet; give it a moment before the first verdict.
            if monitor.history.cpu.values.count < 3 { try? await Task.sleep(for: .seconds(4)) }
            run()
        }
        .confirmationDialog("Quit \(pendingQuit?.name ?? "")?", isPresented: Binding(get: { pendingQuit != nil }, set: { if !$0 { pendingQuit = nil } }), presenting: pendingQuit) { app in
            Button("Quit", role: .destructive) {
                ProcessActions.quit(app, force: false)
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { run() }
            }
            Button("Cancel", role: .cancel) {}
        } message: { app in
            Text("\(app.processes.count) processes will close. The app can ask you to save first.")
        }
        .confirmationDialog("Restart your Mac?", isPresented: $confirmRestart) {
            Button("Restart", role: .destructive) {
                NSAppleScript(source: "tell application \"System Events\" to restart")?.executeAndReturnError(nil)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Apps are asked to quit first, so you can save open documents.")
        }
    }

    private func verdict(_ d: Diagnosis) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: Self.symbol(d.severity))
                .font(.system(size: 44))
                .foregroundStyle(Self.color(d.severity))
            VStack(alignment: .leading, spacing: 6) {
                Text(d.headline).font(.title2.weight(.semibold))
                Text(d.summary).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text("Checked \(d.date.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(.tertiary)
                    Button("Check again", action: run).buttonStyle(.link).font(.caption)
                }
            }
            Spacer()
        }
        .padding(20)
        .background(Self.color(d.severity).opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
    }

    private func run() {
        var input = DiagnosisInput(
            snapshot: monitor.snapshot,
            recentCPU: monitor.history.cpu.values,
            recentAppCPU: monitor.history.appCPU.mapValues(\.values)
        )
        if services.startupScannedAt != nil {
            input.startupItemCount = services.startupItems.filter { !$0.isApple }.count
        }
        let idle = services.projects.projects.flatMap(\.servers).filter { $0.isIdle() }
        input.idleServers = (idle.count, idle.reduce(0) { $0 + $1.memory })
        withAnimation(.snappy) { diagnosis = Diagnostician.diagnose(input) }
    }

    private func perform(_ action: Diagnosis.Action) {
        switch action {
        case .quitApp(let id, _):
            pendingQuit = monitor.snapshot.apps.first { $0.id == id }
        case .openStorage: selection = .storage
        case .openStartupItems: selection = .startup
        case .openProjects: selection = .projects
        case .restartMac: confirmRestart = true
        case .openBatterySettings:
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension")!)
        }
    }

    static func symbol(_ severity: Diagnosis.Severity) -> String {
        switch severity {
        case .ok: "checkmark.seal.fill"
        case .info: "info.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .critical: "exclamationmark.octagon.fill"
        }
    }

    static func color(_ severity: Diagnosis.Severity) -> Color {
        switch severity {
        case .ok: .green
        case .info: .blue
        case .warning: .orange
        case .critical: .red
        }
    }
}

private struct FindingCard: View {
    let finding: Diagnosis.Finding
    let perform: (Diagnosis.Action) -> Void

    var body: some View {
        Card {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: DiagnosisView.symbol(finding.severity))
                    .foregroundStyle(DiagnosisView.color(finding.severity))
                    .font(.title3)
                VStack(alignment: .leading, spacing: 6) {
                    Text(finding.title).font(.headline)
                    Text(finding.detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if !finding.evidence.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(finding.evidence, id: \.self) { line in
                                Text("· " + line).font(.callout).monospacedDigit()
                            }
                        }
                        .padding(.top, 2)
                    }
                }
                Spacer()
                if let action = finding.action {
                    Button(title(action)) { perform(action) }
                }
            }
        }
    }

    private func title(_ action: Diagnosis.Action) -> String {
        switch action {
        case .quitApp(_, let name): "Quit \(name)…"
        case .openStorage: "Free up space"
        case .openStartupItems: "Review"
        case .openProjects: "Show servers"
        case .restartMac: "Restart…"
        case .openBatterySettings: "Battery settings"
        }
    }
}
