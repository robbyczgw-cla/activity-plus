import ActivityCore
import SwiftUI

/// The Mac check-up at the top of the Weekly Report: everything it found, each with a button to the page that handles it.
/// It only reports; nothing is ticked or changed from here.
struct CheckUpCard: View {
    @Environment(\.density) private var density
    @Environment(AppServices.self) private var services
    @State private var service = CheckUpService.shared
    @AppStorage(CheckUpService.frequencyKey) private var frequencyRaw = CheckUpFrequency.weekly.rawValue

    var body: some View {
        Card {
            CardHeader(title: "Mac check-up", systemImage: "checklist.checked", tint: .teal)
            if service.running {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Looking at your Mac…").appFont(.callout).foregroundStyle(.secondary)
                }
            } else if let report = service.report {
                if report.findings.isEmpty {
                    Label("Nothing needs your attention.", systemImage: "checkmark.circle.fill")
                        .appFont(.callout).foregroundStyle(.green)
                } else {
                    VStack(spacing: 0) {
                        ForEach(report.findings) { finding in
                            row(finding)
                            if finding.id != report.findings.last?.id { Divider().opacity(0.4) }
                        }
                    }
                }
                ForEach(report.notChecked, id: \.self) { note in
                    Label { Text(verbatim: note) } icon: { Image(systemName: "info.circle") }
                        .appFont(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("No check-up yet.").appFont(.callout).foregroundStyle(.secondary)
            }
            footer
        }
    }

    private func row(_ finding: CheckUpFinding) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: Self.symbol(finding.kind)).foregroundStyle(Self.tint(finding.kind)).frame(width: 20).padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: finding.title).appFont(.callout, weight: .medium)
                Text(verbatim: finding.detail).appFont(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button { Self.open(finding.destination, services: services) } label: { Text(verbatim: finding.destination.buttonTitle) }
                .controlSize(.small)
        }
        .padding(.vertical, density.space(7))
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Group {
                if let report = service.report {
                    Text("Checked \(report.date.formatted(date: .abbreviated, time: .shortened)).")
                } else {
                    Text("Nothing is cleaned, quit or changed by a check-up.")
                }
                if let next = nextRun { Text("Next: \(next.formatted(date: .abbreviated, time: .shortened))") }
                else if frequencyRaw == CheckUpFrequency.off.rawValue { Text("Scheduled check-ups are off (Settings, General).") }
            }
            .appFont(.caption).foregroundStyle(.tertiary)
            Spacer()
            Button("Check now") { service.run() }
                .controlSize(.small).disabled(service.running)
        }
    }

    private var nextRun: Date? {
        CheckUpSchedule(frequency: CheckUpFrequency(rawValue: frequencyRaw) ?? .weekly, minuteOfDay: CheckUpService.schedule.minuteOfDay)
            .nextRun(lastRun: CheckUpService.lastRun, now: Date())
    }

    /// Opens the page that handles a finding. Clean up is a tab of Storage, so the tab is asked for once the page is up.
    @MainActor static func open(_ destination: CheckUpFinding.Destination, services: AppServices) {
        services.requestedPage = destination.pageKey
        if destination == .cleanUp {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                NotificationCenter.default.post(name: .storageShowCleanup, object: nil)
            }
        }
    }

    static func symbol(_ kind: CheckUpFinding.Kind) -> String {
        switch kind {
        case .backup: "externaldrive.badge.timemachine"
        case .security: "lock.shield"
        case .crashes: "exclamationmark.triangle"
        case .ssd: "internaldrive"
        case .trash: "trash"
        case .growth: "chart.line.uptrend.xyaxis"
        case .largeFiles: "doc.badge.clock"
        case .startup: "power"
        case .uptime: "clock.arrow.circlepath"
        }
    }

    static func tint(_ kind: CheckUpFinding.Kind) -> Color {
        switch kind {
        case .backup, .security, .crashes: .orange
        case .ssd: .brown
        case .trash, .largeFiles: .blue
        case .growth: .purple
        case .startup, .uptime: .secondary
        }
    }
}

/// Settings → General → Check-up.
struct CheckUpSettingsSection: View {
    @AppStorage(CheckUpService.frequencyKey) private var frequencyRaw = CheckUpFrequency.weekly.rawValue
    @AppStorage(CheckUpService.timeKey) private var minuteOfDay = CheckUpSchedule.defaultMinuteOfDay

    private var frequency: CheckUpFrequency { CheckUpFrequency(rawValue: frequencyRaw) ?? .weekly }

    private var time: Binding<Date> {
        Binding {
            Calendar.current.date(bySettingHour: minuteOfDay / 60, minute: minuteOfDay % 60, second: 0, of: Date()) ?? Date()
        } set: { date in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
            minuteOfDay = (parts.hour ?? 9) * 60 + (parts.minute ?? 0)
        }
    }

    var body: some View {
        Section("Check-up") {
            Picker("Check my Mac", selection: $frequencyRaw) {
                ForEach(CheckUpFrequency.allCases, id: \.rawValue) { Text(verbatim: $0.title).tag($0.rawValue) }
            }
            if frequency != .off {
                DatePicker("At", selection: time, displayedComponents: .hourAndMinute)
                if let next = CheckUpSchedule(frequency: frequency, minuteOfDay: minuteOfDay).nextRun(lastRun: CheckUpService.lastRun, now: Date()) {
                    Text("Next check-up: \(next.formatted(date: .complete, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("On Mondays (the first Monday of the month for Monthly). If the Mac is off then, the check-up runs the next time Activity+ is open. It only looks and reports: one notification, and the findings at the top of the Weekly Report. Nothing is cleaned, quit or changed.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
