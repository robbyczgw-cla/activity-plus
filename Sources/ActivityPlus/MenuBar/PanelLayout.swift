import ActivityCore
import SwiftUI

/// The tiles of the menu bar panel's overview tab, chosen and ordered in Settings → Panel.
enum PanelTile: String, CaseIterable, Identifiable {
    case cpu, memory, network, diskFree, gpu, battery, temperature, power, fans, swap, uptime
    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu: "CPU"
        case .memory: "Memory"
        case .network: "Network"
        case .diskFree: "Disk free"
        case .gpu: "GPU"
        case .battery: "Battery"
        case .temperature: "CPU temperature"
        case .power: "Power draw"
        case .fans: "Fans"
        case .swap: "Swap"
        case .uptime: "Uptime"
        }
    }

    var tint: Color {
        switch self {
        case .cpu: Metric.cpu.tint
        case .memory, .swap: Metric.memory.tint
        case .network: Metric.network.tint
        case .diskFree: Metric.disk.tint
        case .gpu: Metric.gpu.tint
        case .battery, .power: .green
        case .temperature: .red
        case .fans: .blue
        case .uptime: .secondary
        }
    }

    /// The panel tab a tap on the tile opens.
    var tab: MenuBarPanel.Tab? {
        switch self {
        case .cpu, .temperature, .fans: .cpu
        case .memory, .swap: .memory
        case .network: .network
        case .diskFree: .disk
        case .gpu: .gpu
        case .battery, .power: .battery
        case .uptime: nil
        }
    }

    @MainActor func value(_ monitor: Monitor, _ services: AppServices) -> String {
        let s = monitor.snapshot
        switch self {
        case .cpu: return Format.percent(s.cpu.total)
        case .memory: return Format.memory(s.memory.used)
        case .network: return Format.networkRate(s.network.inRate)
        case .diskFree: return Format.storage(s.disk.free)
        case .gpu: return Format.percent(s.gpu?.utilization ?? 0)
        case .battery: return s.battery.map { Format.percent($0.percent) } ?? services.accessories.first.map { "\($0.lowest)%" } ?? "–"
        case .temperature: return s.sensors.cpuTemperature.map { Format.temperature($0) } ?? "–"
        case .power: return Format.watts(s.battery?.systemPower ?? s.apps.reduce(0) { $0 + $1.powerWatts })
        case .fans: return s.sensors.fans.max(by: { $0.rpm < $1.rpm }).map { "\(Int($0.rpm)) rpm" } ?? "–"
        case .swap: return Format.memory(s.memory.swapUsed)
        case .uptime: return Format.duration(s.uptime)
        }
    }

    static let defaultOrder: [PanelTile] = [.cpu, .memory, .network, .diskFree, .gpu, .battery]

    static func load() -> [PanelTile] {
        guard let stored = UserDefaults.standard.string(forKey: "panelTiles") else { return defaultOrder }
        let tiles = stored.split(separator: ",").compactMap { PanelTile(rawValue: String($0)) }
        return tiles.isEmpty ? defaultOrder : tiles
    }

    static func save(_ tiles: [PanelTile]) {
        UserDefaults.standard.set(tiles.map(\.rawValue).joined(separator: ","), forKey: "panelTiles")
    }
}

/// Looks for the panel.
enum PanelTheme: String, CaseIterable, Identifiable {
    case system, graphite, midnight, accent
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: "Match macOS"
        case .graphite: "Graphite"
        case .midnight: "Midnight"
        case .accent: "Tinted with the accent color"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .graphite, .midnight: .dark
        case .system, .accent: nil
        }
    }

    @ViewBuilder func background(accent: Color?) -> some View {
        switch self {
        case .system: Color.clear
        case .graphite: Color(white: 0.16)
        case .midnight: LinearGradient(colors: [Color(red: 0.07, green: 0.08, blue: 0.2), Color(red: 0.12, green: 0.08, blue: 0.24)], startPoint: .top, endPoint: .bottom)
        case .accent: (accent ?? .accentColor).opacity(0.12)
        }
    }
}

/// Settings → Panel.
struct PanelSettings: View {
    @State private var tiles = PanelTile.load()
    @AppStorage("panelBusyCount") private var busyCount = 5
    @AppStorage("panelTheme") private var theme = PanelTheme.system.rawValue
    @AppStorage("hiddenPanelTabs") private var hiddenTabs = ""

    var body: some View {
        Form {
            Section("Overview tiles (drag to reorder)") {
                List {
                    ForEach(tiles) { tile in
                        HStack {
                            Circle().fill(tile.tint).frame(width: 8, height: 8)
                            Text(tile.title)
                            Spacer()
                            Button { tiles.removeAll { $0 == tile }; PanelTile.save(tiles) } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless).disabled(tiles.count <= 1)
                        }
                    }
                    .onMove { from, to in
                        tiles.move(fromOffsets: from, toOffset: to)
                        PanelTile.save(tiles)
                    }
                }
                .frame(minHeight: 220)
                HStack {
                    Menu("Add Tile") {
                        ForEach(PanelTile.allCases.filter { !tiles.contains($0) }) { tile in
                            Button(tile.title) { tiles.append(tile); PanelTile.save(tiles) }
                        }
                    }
                    .fixedSize()
                    Spacer()
                    Button("Reset") { tiles = PanelTile.defaultOrder; PanelTile.save(tiles) }
                }
            }
            Section("Below the tiles") {
                Picker("Busiest apps", selection: $busyCount) {
                    Text("Hidden").tag(0)
                    Text("3").tag(3)
                    Text("5").tag(5)
                    Text("8").tag(8)
                }
            }
            Section("Look") {
                Picker("Theme", selection: $theme) {
                    ForEach(PanelTheme.allCases) { Text($0.title).tag($0.rawValue) }
                }
            }
            Section("Tabs") {
                ForEach(MenuBarPanel.Tab.allCases) { tab in
                    Toggle(isOn: Binding(
                        get: { !hiddenTabs.split(separator: ",").map(String.init).contains(tab.rawValue) },
                        set: { visible in
                            var hidden = Set(hiddenTabs.split(separator: ",").map(String.init))
                            if visible { hidden.remove(tab.rawValue) } else { hidden.insert(tab.rawValue) }
                            hiddenTabs = hidden.sorted().joined(separator: ",")
                        })) {
                        Label(tab.title, systemImage: tab.systemImage)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
