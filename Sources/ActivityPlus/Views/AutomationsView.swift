import ActivityCore
import SwiftUI

struct AutomationsView: View {
    @Environment(AppServices.self) private var services
    @Environment(Monitor.self) private var monitor
    @State private var editing: AutomationRule?
    @State private var confirmAutomatic: AutomationRule?

    var body: some View {
        @Bindable var services = services
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Rules that act for you. Each rule either asks first with a notification button, or — only if you switch it to automatic — acts on its own.")
                    .foregroundStyle(.secondary)

                if !services.pendingAutomations.isEmpty {
                    Card {
                        CardHeader(title: "Waiting for your OK", systemImage: "hand.raised", tint: .orange)
                        ForEach(services.pendingAutomations) { match in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(match.rule.summary).fontWeight(.medium)
                                    Text(match.reason).font(.callout).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Not now") { services.dismiss(match.id) }
                                Button("Do it") { services.approve(match.id) }.buttonStyle(.borderedProminent)
                            }
                        }
                    }
                }

                Card {
                    HStack {
                        Text("Rules").font(.headline)
                        Spacer()
                        Menu("Add Rule") {
                            Button("Stop dev servers idle for a day") { add(.init(trigger: .devServerIdle(hours: 24), action: .stopDevServer)) }
                            Button("Warn when the battery drops below 20 %") { add(.init(trigger: .batteryBelow(percent: 20), action: .notify)) }
                            Button("Warn when memory stays critical") { add(.init(trigger: .memoryPressureCritical(minutes: 3), action: .notify)) }
                            Divider()
                            Menu("Quit an app that uses too much memory") {
                                ForEach(topApps) { app in
                                    Button(app.name) { add(.init(trigger: .appMemoryAbove(appID: app.id, appName: app.name, gigabytes: 4), action: .quitTriggeringApp)) }
                                }
                            }
                            Menu("Quit an app that stays busy") {
                                ForEach(topApps) { app in
                                    Button(app.name) { add(.init(trigger: .appCPUAbove(appID: app.id, appName: app.name, percent: 90, minutes: 10), action: .quitTriggeringApp)) }
                                }
                            }
                        }
                        .fixedSize()
                    }
                    if services.automationRules.isEmpty {
                        Text("No rules yet. Add one to let Activity+ take care of the usual suspects.").foregroundStyle(.secondary)
                    }
                    ForEach($services.automationRules) { $rule in
                        RuleRow(rule: $rule, onAutomatic: { confirmAutomatic = rule }) {
                            services.automationRules.removeAll { $0.id == rule.id }
                        }
                        Divider().opacity(0.4)
                    }
                }

                if !services.automationLog.isEmpty {
                    Card {
                        CardHeader(title: "Recently", systemImage: "clock", tint: .secondary)
                        ForEach(Array(services.automationLog.prefix(20).enumerated()), id: \.offset) { _, entry in
                            HStack(alignment: .top) {
                                Text(entry.date, format: .dateTime.hour().minute()).monospacedDigit().foregroundStyle(.secondary)
                                Text(entry.text)
                            }
                            .font(.callout)
                        }
                    }
                }
            }
            .padding(20)
        }
        .navigationTitle("Automations")
        .confirmationDialog("Let this rule act without asking?", isPresented: Binding(get: { confirmAutomatic != nil }, set: { if !$0 { confirmAutomatic = nil } }), presenting: confirmAutomatic) { rule in
            Button("Run Automatically", role: .destructive) {
                if let index = services.automationRules.firstIndex(where: { $0.id == rule.id }) {
                    services.automationRules[index].mode = .automatic
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { rule in
            Text("“\(rule.summary)” will then happen without a confirmation. Apps are asked to quit normally, so they can still ask you to save. You get a notification every time it runs.")
        }
    }

    private var topApps: [AppGroup] {
        Array(monitor.snapshot.apps.filter { $0.kind == .app }.sorted { $0.memory > $1.memory }.prefix(15))
    }

    private func add(_ rule: AutomationRule) { services.automationRules.append(rule) }
}

private struct RuleRow: View {
    @Binding var rule: AutomationRule
    let onAutomatic: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Toggle("", isOn: $rule.enabled).toggleStyle(.switch).labelsHidden().controlSize(.small)
            VStack(alignment: .leading, spacing: 6) {
                Text(rule.summary).fontWeight(.medium)
                HStack(spacing: 14) {
                    thresholdEditor
                    if rule.action != .notify {
                        Picker("", selection: Binding(
                            get: { rule.mode },
                            set: { mode in if mode == .automatic { onAutomatic() } else { rule.mode = .ask } })) {
                            Text("Ask first").tag(AutomationRule.Mode.ask)
                            Text("Automatically").tag(AutomationRule.Mode.automatic)
                        }
                        .labelsHidden().fixedSize()
                    }
                }
                .font(.callout)
            }
            Spacer()
            Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }.buttonStyle(.borderless)
        }
        .opacity(rule.enabled ? 1 : 0.5)
    }

    @ViewBuilder private var thresholdEditor: some View {
        switch rule.trigger {
        case .devServerIdle(let hours):
            Stepper("Idle for \(AutomationRuleHours.text(hours))", value: Binding(get: { hours }, set: { rule.trigger = .devServerIdle(hours: $0) }), in: 1...168, step: hours >= 24 ? 24 : 1)
        case .batteryBelow(let percent):
            Stepper("Below \(Int(percent)) %", value: Binding(get: { percent }, set: { rule.trigger = .batteryBelow(percent: $0) }), in: 5...80, step: 5)
        case .appMemoryAbove(let id, let name, let gb):
            Stepper(String(format: "Above %g GB", gb), value: Binding(get: { gb }, set: { rule.trigger = .appMemoryAbove(appID: id, appName: name, gigabytes: $0) }), in: 0.5...64, step: 0.5)
        case .appCPUAbove(let id, let name, let percent, let minutes):
            Stepper("Above \(Int(percent)) %", value: Binding(get: { percent }, set: { rule.trigger = .appCPUAbove(appID: id, appName: name, percent: $0, minutes: minutes) }), in: 20...800, step: 10)
            Stepper("for \(minutes) min", value: Binding(get: { minutes }, set: { rule.trigger = .appCPUAbove(appID: id, appName: name, percent: percent, minutes: $0) }), in: 1...120)
        case .memoryPressureCritical(let minutes):
            Stepper("for \(minutes) min", value: Binding(get: { minutes }, set: { rule.trigger = .memoryPressureCritical(minutes: $0) }), in: 1...60)
        }
    }
}

enum AutomationRuleHours {
    static func text(_ hours: Double) -> String {
        hours >= 24 && hours.truncatingRemainder(dividingBy: 24) == 0 ? "\(Int(hours / 24)) d" : "\(Int(hours)) h"
    }
}
