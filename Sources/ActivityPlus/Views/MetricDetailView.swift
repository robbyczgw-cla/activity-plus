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
        case .network:
            HStack(alignment: .top, spacing: 14) {
                Card {
                    CardHeader(title: "Network", systemImage: "network", tint: metric.tint)
                    BigNumber(text: Format.rate(s.network.inRate), size: 36)
                    StatLine(label: "Downloading", value: Format.rate(s.network.inRate), tint: .teal)
                    StatLine(label: "Uploading", value: Format.rate(s.network.outRate), tint: .indigo)
                    StatLine(label: "Received since launch", value: Format.storage(s.network.receivedSinceLaunch))
                    StatLine(label: "Sent since launch", value: Format.storage(s.network.sentSinceLaunch))
                }
                .frame(width: 280)
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
