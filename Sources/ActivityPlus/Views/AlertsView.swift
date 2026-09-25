import ActivityCore
import SwiftUI

struct AlertsView: View {
    @Environment(AppServices.self) private var services

    var body: some View {
        @Bindable var services = services
        HSplitView {
            List {
                if services.alerts.isEmpty {
                    ContentUnavailableView("No alerts", systemImage: "bell.slash",
                                           description: Text("You get a notification when an app hogs the CPU, keeps growing in memory, or hammers the disk or network."))
                }
                ForEach(services.alerts) { alert in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: symbol(alert.kind)).foregroundStyle(.orange).frame(width: 20)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(alert.title).fontWeight(.medium)
                            Text(alert.detail).font(.callout).foregroundStyle(.secondary)
                            Text(alert.date, format: .relative(presentation: .named)).font(.caption).foregroundStyle(.tertiary)
                        }
                        Spacer()
                        if let id = alert.appID {
                            Button("Ignore app") { services.ignore(appID: id) }
                                .buttonStyle(.borderless).font(.caption)
                                .disabled(services.alertSettings.ignoredApps.contains(id))
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .frame(minWidth: 380)

            Form {
                Section {
                    Toggle("Alerts", isOn: $services.alertSettings.enabled)
                }
                Section("CPU") {
                    Stepper("Above \(Int(services.alertSettings.cpuPercent)) %", value: $services.alertSettings.cpuPercent, in: 20...400, step: 10)
                    Stepper("For \(services.alertSettings.cpuMinutes) minutes", value: $services.alertSettings.cpuMinutes, in: 2...60)
                }
                Section("Memory") {
                    Stepper(String(format: "Grows by %.1f GB", services.alertSettings.memoryGrowthGB), value: $services.alertSettings.memoryGrowthGB, in: 0.25...8, step: 0.25)
                    Stepper("Within \(services.alertSettings.memoryWindowMinutes) minutes", value: $services.alertSettings.memoryWindowMinutes, in: 10...180, step: 10)
                }
                Section("Disk and network") {
                    Stepper("Disk above \(Int(services.alertSettings.diskMBps)) MB/s", value: $services.alertSettings.diskMBps, in: 5...1000, step: 5)
                    Stepper("Network above \(Int(services.alertSettings.networkMBps)) MB/s", value: $services.alertSettings.networkMBps, in: 1...500, step: 1)
                    Stepper("For \(services.alertSettings.ioMinutes) minutes", value: $services.alertSettings.ioMinutes, in: 1...60)
                }
                Section("System") {
                    Toggle("Low memory, full disk, overheating", isOn: $services.alertSettings.systemAlerts)
                    Stepper("Repeat at most every \(services.alertSettings.cooldownMinutes) min", value: $services.alertSettings.cooldownMinutes, in: 10...720, step: 10)
                }
                if !services.alertSettings.ignoredApps.isEmpty {
                    Section("Ignored apps") {
                        ForEach(Array(services.alertSettings.ignoredApps).sorted(), id: \.self) { id in
                            HStack {
                                Text(Self.displayName(id)).lineLimit(1)
                                Spacer()
                                Button("Remove") { services.alertSettings.ignoredApps.remove(id) }.buttonStyle(.borderless)
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .frame(minWidth: 300, idealWidth: 340)
        }
        .navigationTitle("Alerts")
        .toolbar {
            Button("Clear", systemImage: "trash") { services.clearAlerts() }.disabled(services.alerts.isEmpty)
        }
    }

    private func symbol(_ kind: AppAlert.Kind) -> String {
        switch kind {
        case .cpu: "cpu"
        case .memoryGrowth, .memoryPressure: "memorychip"
        case .disk, .diskFull: "internaldrive"
        case .network: "network"
        case .thermal: "thermometer.high"
        case .accessory: "battery.25percent"
        case .unusual: "sparkle.magnifyingglass"
        case .leak: "drop.triangle"
        case .hang: "hourglass"
        case .automation: "wand.and.stars"
        case .weekly: "calendar"
        }
    }

    static func displayName(_ id: String) -> String {
        if id.hasPrefix("tool:") { return String(id.dropFirst(5)) }
        return FileManager.default.displayName(atPath: id).replacingOccurrences(of: ".app", with: "")
    }
}
