import ActivityCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Environment(Monitor.self) private var monitor
    @AppStorage("menuBarStyle") private var style = MenuBarStyle.figure.rawValue
    @AppStorage("menuBarFigure") private var figure = MenuBarFigure.cpu.rawValue
    @AppStorage("menuBarStacked") private var stacked = "cpu,memory"
    @AppStorage("showDockIcon") private var showDockIcon = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        @Bindable var monitor = monitor
        Form {
            Section("Menu bar") {
                Picker("Show", selection: $style) {
                    ForEach(MenuBarStyle.allCases) { Text($0.title).tag($0.rawValue) }
                }
                if style == MenuBarStyle.figure.rawValue || style == MenuBarStyle.graph.rawValue {
                    Picker("Figure", selection: $figure) {
                        ForEach(MenuBarFigure.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                }
                if style == MenuBarStyle.stacked.rawValue {
                    Picker("Top line", selection: stackedBinding(0)) {
                        ForEach(MenuBarFigure.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    Picker("Bottom line", selection: stackedBinding(1)) {
                        ForEach(MenuBarFigure.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                }
                Text("The item turns into a warning sign while the Mac is under strain.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("General") {
                Picker("Refresh every", selection: $monitor.interval) {
                    Text("1 second").tag(1.0)
                    Text("2 seconds").tag(2.0)
                    Text("5 seconds").tag(5.0)
                    Text("10 seconds").tag(10.0)
                }
                Toggle("Show in Dock", isOn: $showDockIcon)
                    .onChange(of: showDockIcon) { _, show in
                        NSApp.setActivationPolicy(show ? .regular : .accessory)
                    }
                Toggle("Open at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            }
            Section("Privacy") {
                Text("Activity+ keeps everything on this Mac. It has no account, no analytics and makes no network requests.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func stackedBinding(_ index: Int) -> Binding<String> {
        Binding {
            let parts = stacked.split(separator: ",").map(String.init)
            return index < parts.count ? parts[index] : "cpu"
        } set: { value in
            var parts = stacked.split(separator: ",").map(String.init)
            while parts.count < 2 { parts.append("memory") }
            parts[index] = value
            stacked = parts.joined(separator: ",")
        }
    }
}
