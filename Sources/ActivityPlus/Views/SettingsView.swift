import ActivityCore
import ServiceManagement
import SwiftUI

/// Settings, one tab per area. Almost every look and behavior can be changed here.
struct SettingsView: View {
    @AppStorage("settingsTab") private var tab = "general"

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }.tag("general")
            MenuBarSettings().tabItem { Label("Menu Bar", systemImage: "menubar.rectangle") }.tag("menuBar")
            WindowSettings().tabItem { Label("Window", systemImage: "macwindow") }.tag("window")
            UnitsSettings().tabItem { Label("Units", systemImage: "ruler") }.tag("units")
            UpdatesSettings().tabItem { Label("Updates", systemImage: "arrow.down.circle") }.tag("updates")
        }
        .frame(width: 640)
        .frame(minHeight: 460)
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @Environment(Monitor.self) private var monitor
    @AppStorage("showDockIcon") private var showDockIcon = true
    @AppStorage("openWindowAtLaunch") private var openWindowAtLaunch = true
    @AppStorage("accentColor") private var accent = "system"
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        @Bindable var monitor = monitor
        Form {
            Section("Measuring") {
                Picker("Refresh every", selection: $monitor.interval) {
                    Text("1 second").tag(1.0)
                    Text("2 seconds").tag(2.0)
                    Text("3 seconds").tag(3.0)
                    Text("5 seconds").tag(5.0)
                    Text("10 seconds").tag(10.0)
                }
                Text("With no window or panel open, Activity+ measures at most every 5 seconds to save energy.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Startup") {
                Toggle("Open at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                Toggle("Open the window at launch", isOn: $openWindowAtLaunch)
                Toggle("Show in Dock", isOn: $showDockIcon)
                    .onChange(of: showDockIcon) { _, show in NSApp.setActivationPolicy(show ? .regular : .accessory) }
            }
            Section("Look") {
                Picker("Accent color", selection: $accent) {
                    ForEach(AccentChoice.allCases) { choice in
                        HStack {
                            Circle().fill(choice.color ?? .accentColor).frame(width: 10, height: 10)
                            Text(choice.title)
                        }
                        .tag(choice.rawValue)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

enum AccentChoice: String, CaseIterable, Identifiable {
    case system, blue, purple, pink, red, orange, green, teal, graphite
    var id: String { rawValue }
    var title: String { rawValue == "system" ? "System" : rawValue.capitalized }
    var color: Color? {
        switch self {
        case .system: nil
        case .blue: .blue
        case .purple: .purple
        case .pink: .pink
        case .red: .red
        case .orange: .orange
        case .green: .green
        case .teal: .teal
        case .graphite: .gray
        }
    }

    static func color(_ raw: String) -> Color? { AccentChoice(rawValue: raw)?.color }
}

// MARK: - Menu bar

private struct MenuBarSettings: View {
    @Environment(Monitor.self) private var monitor
    @Environment(AppServices.self) private var services
    @State private var items = MenuBarItemStore.load()
    @State private var selection: UUID?
    @AppStorage("menuBarWarnWhenStrained") private var warn = true
    @AppStorage("hiddenPanelTabs") private var hiddenTabs = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Live preview of the whole menu bar, in the order it appears (left to right).
            HStack(spacing: 10) {
                Spacer()
                ForEach(items) { item in
                    MenuBarWidget(config: item, reading: ModuleReading.read(item, monitor: monitor, services: services), ink: .primary)
                        .padding(.horizontal, 5).padding(.vertical, 3)
                        .background(selection == item.id ? Color.accentColor.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 5))
                        .onTapGesture { selection = item.id }
                }
            }
            .padding(8)
            .background(.bar, in: RoundedRectangle(cornerRadius: 8))

            HSplitView {
                VStack(spacing: 0) {
                    List(selection: $selection) {
                        ForEach(items) { item in
                            Label(item.module.title + " · " + item.style.title, systemImage: item.module.systemImage).tag(item.id)
                        }
                        .onMove { from, to in
                            items.move(fromOffsets: from, toOffset: to)
                            save()
                        }
                    }
                    HStack {
                        Menu {
                            ForEach(MenuBarItemConfig.Module.allCases) { module in
                                Button(module.title) {
                                    let item = MenuBarItemConfig(module: module, style: module.styles[0])
                                    items.append(item)
                                    selection = item.id
                                    save()
                                }
                            }
                        } label: { Image(systemName: "plus") }
                        .menuStyle(.borderlessButton).fixedSize()
                        Button {
                            items.removeAll { $0.id == selection }
                            selection = items.first?.id
                            save()
                        } label: { Image(systemName: "minus") }
                        .buttonStyle(.borderless)
                        .disabled(selection == nil || items.count <= 1)
                        .help(items.count <= 1 ? "Keep at least one item so Activity+ stays reachable" : "Remove item")
                        Spacer()
                        Text("Drag to reorder").font(.caption).foregroundStyle(.tertiary)
                    }
                    .padding(6)
                }
                .frame(minWidth: 200, idealWidth: 220)

                Group {
                    if let index = items.firstIndex(where: { $0.id == selection }) {
                        ItemEditor(item: $items[index]).onChange(of: items[index]) { _, _ in save() }
                    } else {
                        Text("Select an item to change how it looks.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(minWidth: 320)
            }
            .frame(minHeight: 260)

            Toggle("Turn the first item into a warning sign while the Mac is under strain", isOn: $warn)
            HStack {
                Text("Panel tabs:")
                ForEach(MenuBarPanel.Tab.allCases) { tab in
                    Toggle(isOn: Binding(
                        get: { !hiddenTabs.split(separator: ",").map(String.init).contains(tab.rawValue) },
                        set: { visible in
                            var hidden = Set(hiddenTabs.split(separator: ",").map(String.init))
                            if visible { hidden.remove(tab.rawValue) } else { hidden.insert(tab.rawValue) }
                            hiddenTabs = hidden.sorted().joined(separator: ",")
                        })) {
                        Image(systemName: tab.systemImage)
                    }
                    .toggleStyle(.button)
                    .help(tab.title)
                }
            }
        }
        .padding(16)
        .onAppear { selection = selection ?? items.first?.id }
    }

    private func save() { MenuBarItemStore.save(items) }
}

private struct ItemEditor: View {
    @Binding var item: MenuBarItemConfig

    var body: some View {
        Form {
            Picker("Shows", selection: $item.module) {
                ForEach(MenuBarItemConfig.Module.allCases) { Label($0.title, systemImage: $0.systemImage).tag($0) }
            }
            .onChange(of: item.module) { _, module in
                if !module.styles.contains(item.style) { item.style = module.styles[0] }
            }
            Picker("Style", selection: $item.style) {
                ForEach(item.module.styles) { Text($0.title).tag($0) }
            }
            if item.module == .memory {
                Picker("Figure", selection: $item.memoryFigure) {
                    ForEach(MenuBarItemConfig.MemoryFigure.allCases) { Text($0.title).tag($0) }
                }
            }
            if item.module == .disk {
                Picker("Figure", selection: $item.diskFigure) {
                    ForEach(MenuBarItemConfig.DiskFigure.allCases) { Text($0.title).tag($0) }
                }
            }
            if item.module == .clock {
                Toggle("Seconds", isOn: $item.clockShowsSeconds)
                TextField("Time zones", text: Binding(
                    get: { item.timeZones.joined(separator: ", ") },
                    set: { item.timeZones = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { TimeZone(identifier: $0) != nil } }),
                    prompt: Text("e.g. America/New_York, Asia/Tokyo"))
            }
            if item.module != .status && item.module != .clock {
                Toggle(item.style == .text || item.style == .labeled ? "Show label" : "Show the value next to it", isOn: $item.showLabel)
                TextField("Label", text: $item.customLabel, prompt: Text(item.module.shortLabel))
                Toggle("Decimals", isOn: $item.showDecimals)
            }
            Picker("Color", selection: $item.colorMode) {
                ForEach(MenuBarItemConfig.ColorMode.allCases) { Text($0.title).tag($0) }
            }
            if item.colorMode == .fixed {
                ColorPicker("Color", selection: Binding(get: { Color(hex: item.fixedColor) }, set: { item.fixedColor = $0.hexString }), supportsOpacity: false)
            }
            if [.cpu, .memory, .gpu, .network, .temperature, .fans, .power].contains(item.module) {
                Picker("Only show when above", selection: $item.hideBelowPercent) {
                    Text("Always show").tag(0.0)
                    Text("25 %").tag(25.0)
                    Text("50 %").tag(50.0)
                    Text("75 %").tag(75.0)
                }
                .help("Keeps the menu bar clean: the item appears only while the value is high.")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Window

private struct WindowSettings: View {
    @AppStorage("hiddenPages") private var hiddenPages = ""
    @AppStorage("overviewCards") private var cardOrder = OverviewCard.defaultOrder
    @AppStorage("hiddenOverviewCards") private var hiddenCards = ""

    var body: some View {
        Form {
            Section("Sidebar") {
                ForEach(SidebarItem.customizable, id: \.key) { page in
                    Toggle(page.title, isOn: toggle(key: page.key, in: $hiddenPages))
                }
            }
            Section("Overview cards (drag to reorder)") {
                List {
                    ForEach(OverviewCard.ordered(cardOrder)) { card in
                        Toggle(card.title, isOn: toggle(key: card.rawValue, in: $hiddenCards))
                    }
                    .onMove { from, to in
                        var order = OverviewCard.ordered(cardOrder)
                        order.move(fromOffsets: from, toOffset: to)
                        cardOrder = order.map(\.rawValue).joined(separator: ",")
                    }
                }
                .frame(minHeight: 230)
                Button("Reset order") { cardOrder = OverviewCard.defaultOrder }
            }
        }
        .formStyle(.grouped)
    }

    /// A toggle that is on when `key` is NOT in the comma-separated hidden list.
    private func toggle(key: String, in list: Binding<String>) -> Binding<Bool> {
        Binding(
            get: { !list.wrappedValue.split(separator: ",").map(String.init).contains(key) },
            set: { visible in
                var hidden = Set(list.wrappedValue.split(separator: ",").map(String.init))
                if visible { hidden.remove(key) } else { hidden.insert(key) }
                list.wrappedValue = hidden.sorted().joined(separator: ",")
            })
    }
}

// MARK: - Units

private struct UnitsSettings: View {
    @AppStorage("temperatureUnit") private var temperature = Format.TemperatureUnit.celsius.rawValue
    @AppStorage("networkInBits") private var bits = false

    var body: some View {
        Form {
            Picker("Temperature", selection: $temperature) {
                Text("Celsius (°C)").tag(Format.TemperatureUnit.celsius.rawValue)
                Text("Fahrenheit (°F)").tag(Format.TemperatureUnit.fahrenheit.rawValue)
            }
            Picker("Network speed", selection: $bits) {
                Text("Bytes (MB/s)").tag(false)
                Text("Bits (Mbit/s), like internet plans").tag(true)
            }
        }
        .formStyle(.grouped)
        .onChange(of: temperature) { _, _ in UnitPreferences.apply() }
        .onChange(of: bits) { _, _ in UnitPreferences.apply() }
    }
}

enum UnitPreferences {
    static func apply() {
        let defaults = UserDefaults.standard
        Format.temperatureUnit = Format.TemperatureUnit(rawValue: defaults.string(forKey: "temperatureUnit") ?? "") ?? .celsius
        Format.networkInBits = defaults.bool(forKey: "networkInBits")
    }
}

// MARK: - Updates & privacy

private struct UpdatesSettings: View {
    var body: some View {
        Form {
            Section("Updates") {
                Toggle("Check for updates automatically", isOn: Binding(
                    get: { Updates.shared.updater.automaticallyChecksForUpdates },
                    set: { Updates.shared.updater.automaticallyChecksForUpdates = $0 }))
                CheckForUpdatesButton()
            }
            Section("Privacy") {
                Text("Activity+ keeps everything on this Mac. It has no account and no analytics. Its only network request is the daily update check, which you can turn off above.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
