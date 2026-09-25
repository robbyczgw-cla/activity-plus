import ActivityCore
import SwiftUI

/// One page per metric: the headline figures, a live chart and every app sorted by that metric.
struct MetricDetailView: View {
    @Environment(Monitor.self) private var monitor
    let metric: Metric
    @State private var search = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                Card {
                    HStack {
                        Text("Apps").font(.headline)
                        Spacer()
                        SystemToggle()
                    }
                    AppListView(metric: metric, searchText: search)
                }
            }
            .padding(20)
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Search apps and processes")
        .navigationTitle(metric.title)
    }

    @ViewBuilder private var header: some View {
        let s = monitor.snapshot
        let h = monitor.history
        let interval = monitor.interval
        switch metric {
        case .cpu:
            HStack(alignment: .top, spacing: 14) {
                Card {
                    CardHeader(title: "CPU", systemImage: "cpu", tint: metric.tint, trailing: SystemSampler.chipName)
                    BigNumber(text: Format.percent(s.cpu.total), size: 36)
                    StatLine(label: "User", value: Format.percent(s.cpu.user), tint: .blue)
                    StatLine(label: "System", value: Format.percent(s.cpu.system), tint: .red)
                    StatLine(label: "Idle", value: Format.percent(s.cpu.idle))
                    StatLine(label: "Load average", value: String(format: "%.2f  %.2f  %.2f", s.cpu.loadAverage.0, s.cpu.loadAverage.1, s.cpu.loadAverage.2))
                    StatLine(label: "Thermal state", value: s.thermal.rawValue)
                    if let e = s.chip.efficiencyMHz { StatLine(label: "E-cores clock", value: Self.clock(e)) }
                    if let p = s.chip.performanceMHz { StatLine(label: "P-cores clock", value: Self.clock(p)) }
                    if let w = s.chip.cpuWatts { StatLine(label: "CPU power", value: Format.watts(w)) }
                }
                .frame(width: 280)
                Card {
                    LiveChart(lines: [
                        .init(name: "User", values: h.cpuUser.values, color: .blue),
                        .init(name: "System", values: h.cpuSystem.values, color: .red),
                    ], format: { Format.percent($0) }, maxValue: 100, interval: interval)
                    .frame(height: 150)
                    CoreGrid(cores: s.cpu.perCore, efficiencyCores: s.cpu.efficiencyCores)
                }
            }
        case .memory:
            HStack(alignment: .top, spacing: 14) {
                Card {
                    CardHeader(title: "Memory", systemImage: "memorychip", tint: metric.tint, trailing: "of \(Format.memory(s.memory.total))")
                    HStack { BigNumber(text: Format.memory(s.memory.used), size: 36); Spacer(); PressureBadge(pressure: s.memory.pressure) }
                    MemoryBar(stats: s.memory)
                    StatLine(label: "App memory", value: Format.memory(s.memory.app), tint: .purple)
                    StatLine(label: "Wired", value: Format.memory(s.memory.wired), tint: .orange)
                    StatLine(label: "Compressed", value: Format.memory(s.memory.compressed), tint: .pink)
                    StatLine(label: "Cached files", value: Format.memory(s.memory.cachedFiles), tint: .gray)
                    StatLine(label: "Swap used", value: Format.memory(s.memory.swapUsed))
                }
                .frame(width: 280)
                Card {
                    LiveChart(lines: [.init(name: "Used", values: h.memory.values, color: metric.tint)],
                              format: { Format.memory(UInt64($0)) }, maxValue: Double(s.memory.total), interval: interval)
                    .frame(height: 220)
                }
            }
        case .gpu:
            HStack(alignment: .top, spacing: 14) {
                Card {
                    CardHeader(title: "GPU", systemImage: "square.stack.3d.up", tint: metric.tint, trailing: s.gpu?.name)
                    BigNumber(text: Format.percent(s.gpu?.utilization ?? 0), size: 36)
                    StatLine(label: "Memory in use", value: Format.memory(s.gpu?.memoryInUse ?? 0))
                    if let mhz = s.chip.gpuMHz { StatLine(label: "Clock", value: Self.clock(mhz)) }
                    if let w = s.chip.gpuWatts { StatLine(label: "Power", value: Format.watts(w)) }
                    if let t = s.sensors.gpuTemperature { StatLine(label: "Temperature", value: Format.temperature(t)) }
                    StatLine(label: "Average", value: Format.percent(h.gpu.average))
                    StatLine(label: "Peak", value: Format.percent(h.gpu.peak))
                }
                .frame(width: 280)
                Card {
                    LiveChart(lines: [.init(name: "GPU", values: h.gpu.values, color: metric.tint)],
                              format: { Format.percent($0) }, maxValue: 100, interval: interval)
                    .frame(height: 150)
                }
            }
        case .disk:
            HStack(alignment: .top, spacing: 14) {
                Card {
                    CardHeader(title: s.disk.volumeName, systemImage: "internaldrive", tint: metric.tint, trailing: "free")
                    BigNumber(text: Format.storage(s.disk.free), size: 36)
                    UsageBar(fraction: 1 - Double(s.disk.free) / Double(max(1, s.disk.total)), tint: metric.tint)
                    StatLine(label: "Reading", value: Format.rate(s.disk.readRate), tint: .orange)
                    StatLine(label: "Writing", value: Format.rate(s.disk.writeRate), tint: .brown)
                    StatLine(label: "Read since launch", value: Format.storage(s.disk.readSinceLaunch))
                    StatLine(label: "Written since launch", value: Format.storage(s.disk.writtenSinceLaunch))
                }
                .frame(width: 280)
                Card {
                    LiveChart(lines: [
                        .init(name: "Read", values: h.diskRead.values, color: .orange),
                        .init(name: "Write", values: h.diskWrite.values, color: .brown),
                    ], format: Format.rate, interval: interval)
                    .frame(height: 170)
                }
            }
            DrivesCard(drives: s.drives)
            SpeedTestCard()
        case .network:
            HStack(alignment: .top, spacing: 14) {
                Card {
                    CardHeader(title: "Network", systemImage: "network", tint: metric.tint)
                    BigNumber(text: Format.networkRate(s.network.inRate), size: 36)
                    StatLine(label: "Downloading", value: Format.networkRate(s.network.inRate), tint: .teal)
                    StatLine(label: "Uploading", value: Format.networkRate(s.network.outRate), tint: .indigo)
                    StatLine(label: "Received since launch", value: Format.storage(s.network.receivedSinceLaunch))
                    StatLine(label: "Sent since launch", value: Format.storage(s.network.sentSinceLaunch))
                }
                .frame(width: 280)
                NetworkDetailsCard()
                Card {
                    LiveChart(lines: [
                        .init(name: "Down", values: h.netIn.values, color: .teal),
                        .init(name: "Up", values: h.netOut.values, color: .indigo),
                    ], format: Format.rate, interval: interval)
                    .frame(height: 150)
                }
            }
        case .energy:
            Card {
                CardHeader(title: "Energy", systemImage: "bolt", tint: metric.tint)
                HStack(spacing: 30) {
                    VStack(alignment: .leading) {
                        Text("Apps now").font(.caption).foregroundStyle(.secondary)
                        BigNumber(text: Format.watts(s.apps.reduce(0) { $0 + $1.powerWatts }), size: 32)
                    }
                    if let system = s.battery?.systemPower {
                        VStack(alignment: .leading) {
                            Text("Whole Mac").font(.caption).foregroundStyle(.secondary)
                            BigNumber(text: Format.watts(system), size: 32)
                        }
                    }
                }
                Text("Measured by the kernel's per-process energy counters, not estimated. Processes owned by macOS are not included.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

extension MetricDetailView {
    static func clock(_ mhz: Double) -> String {
        mhz >= 1000 ? String(format: "%.2f GHz", mhz / 1000) : String(format: "%.0f MHz", mhz)
    }
}

/// Interfaces, addresses and Wi-Fi. The public IP is only fetched when asked for (it is a network request).
/// Every drive, like the Stats app's disk module, plus NVMe health where the drive reports it.
struct DrivesCard: View {
    let drives: [DriveInfo]

    var body: some View {
        if !drives.isEmpty {
            Card {
                CardHeader(title: "Drives", systemImage: "externaldrive.connected.to.line.below", tint: .orange)
                ForEach(drives) { drive in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Image(systemName: drive.isInternal ? "internaldrive" : "externaldrive").foregroundStyle(.orange)
                            Text(drive.name).fontWeight(.medium)
                            if let model = drive.model { Text(model).font(.caption).foregroundStyle(.secondary) }
                            Spacer()
                            if let smart = drive.smartStatus {
                                Label(smart, systemImage: smart == "Verified" ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                                    .font(.caption).foregroundStyle(smart == "Verified" ? .green : .red)
                            }
                        }
                        UsageBar(fraction: 1 - Double(drive.free) / Double(max(drive.total, 1)), tint: .orange)
                        HStack(spacing: 18) {
                            Text("\(Format.storage(drive.free)) free of \(Format.storage(drive.total))")
                            Text("R \(Format.rate(drive.readRate))  W \(Format.rate(drive.writeRate))").monospacedDigit()
                            if let health = drive.nvmeHealth {
                                if let used = health.percentageUsed { Text("Wear \(used) %") }
                                if let t = health.temperatureC { Text(Format.temperature(t)) }
                                if let hours = health.powerOnHours { Text("\(hours) h powered on") }
                                if let tb = health.dataWrittenTB { Text(String(format: "%.1f TB written", tb)) }
                            }
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }
}

struct NetworkDetailsCard: View {
    @Environment(Monitor.self) private var monitor
    @State private var publicIP: String?
    @State private var fetching = false

    var body: some View {
        let s = monitor.snapshot
        Card {
            CardHeader(title: "Connection", systemImage: "wifi", tint: .teal)
            ForEach(s.interfaces) { interface in
                HStack {
                    Image(systemName: symbol(interface.kind)).frame(width: 18).foregroundStyle(.teal)
                    Text(interface.displayName + (interface.isPrimary ? " (primary)" : ""))
                    Spacer()
                    Text(interface.ipv4.first ?? interface.ipv6.first ?? "–").monospacedDigit().textSelection(.enabled)
                }
                .font(.callout)
            }
            if let wifi = s.wifi {
                Divider()
                StatLine(label: "Wi-Fi network", value: wifi.ssid ?? "Hidden by macOS (needs Location access)")
                if let rssi = wifi.rssi { StatLine(label: "Signal", value: "\(rssi) dBm · \(quality(rssi))") }
                if let channel = wifi.channel { StatLine(label: "Channel", value: "\(channel)\(wifi.band.map { " · " + $0 } ?? "")") }
                if let rate = wifi.transmitRateMbps { StatLine(label: "Link speed", value: String(format: "%.0f Mbit/s", rate)) }
            }
            if let gateway = s.gateway { StatLine(label: "Router", value: gateway) }
            HStack {
                Text("Public IP").foregroundStyle(.secondary)
                Spacer()
                if let publicIP {
                    Text(publicIP).monospacedDigit().textSelection(.enabled)
                } else {
                    Button(fetching ? "Asking…" : "Look up") {
                        fetching = true
                        Task {
                            publicIP = await NetworkInfo.publicIP() ?? "Not available"
                            fetching = false
                        }
                    }
                    .buttonStyle(.link)
                    .disabled(fetching)
                    .help("Asks api.ipify.org once. Activity+ never does this on its own.")
                }
            }
            .font(.callout)
        }
        .frame(width: 280)
    }

    private func symbol(_ kind: NetworkInterfaceInfo.Kind) -> String {
        switch kind {
        case .wifi: "wifi"
        case .ethernet: "cable.connector"
        case .cellular: "antenna.radiowaves.left.and.right"
        case .vpn: "lock.shield"
        case .other: "network"
        }
    }

    private func quality(_ rssi: Int) -> String {
        rssi >= -55 ? "excellent" : rssi >= -67 ? "good" : rssi >= -75 ? "fair" : "weak"
    }
}

struct SystemToggle: View {
    @AppStorage("showSystemProcesses") private var showSystem = true
    var body: some View {
        Toggle("Include macOS", isOn: $showSystem)
            .toggleStyle(.switch)
            .controlSize(.mini)
            .font(.caption)
    }
}

struct CoreGrid: View {
    let cores: [Double]
    let efficiencyCores: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Cores").font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: min(max(cores.count, 1), 12)), spacing: 6) {
                ForEach(Array(cores.enumerated()), id: \.offset) { index, value in
                    VStack(spacing: 3) {
                        GeometryReader { proxy in
                            ZStack(alignment: .bottom) {
                                RoundedRectangle(cornerRadius: 3).fill(.quaternary)
                                RoundedRectangle(cornerRadius: 3)
                                    .fill((index < efficiencyCores ? Color.teal : Color.blue).gradient)
                                    .frame(height: proxy.size.height * value / 100)
                            }
                        }
                        .frame(height: 40)
                        Text(index < efficiencyCores ? "E" : "P").font(.system(size: 9)).foregroundStyle(.tertiary)
                    }
                    .help("Core \(index + 1): \(Format.percent(value))")
                }
            }
            .animation(.smooth, value: cores)
        }
    }
}

struct MemoryBar: View {
    let stats: MemoryStats

    var body: some View {
        GeometryReader { proxy in
            let total = Double(max(1, stats.total))
            HStack(spacing: 1) {
                Rectangle().fill(.purple).frame(width: proxy.size.width * Double(stats.app) / total)
                Rectangle().fill(.orange).frame(width: proxy.size.width * Double(stats.wired) / total)
                Rectangle().fill(.pink).frame(width: proxy.size.width * Double(stats.compressed) / total)
                Rectangle().fill(.quaternary)
            }
            .clipShape(Capsule())
        }
        .frame(height: 8)
    }
}
