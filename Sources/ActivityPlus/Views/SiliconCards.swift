import ActivityCore
import SwiftUI

/// Where each busy app runs: performance or efficiency cores, and how much work it gets done per clock cycle.
struct CoreTypeCard: View {
    let apps: [AppGroup]

    /// Only on a performance + efficiency chip is the kernel's P-core time known to mean what the bar says.
    /// With super or unknown clusters the split is hidden and only IPC is shown.
    private let attributed = CoreTopology.current.isClassic

    private var busy: [AppGroup] {
        apps.filter { (attributed ? $0.pCoreShare != nil : $0.ipc != nil) && $0.cpuPercent >= 1 }.sorted { $0.cpuPercent > $1.cpuPercent }.prefix(8).map { $0 }
    }

    var body: some View {
        Card {
            CardHeader(title: attributed ? "Performance and efficiency cores" : "Instructions per cycle", systemImage: "cpu.fill", tint: .blue)
            if attributed {
            Text("Performance cores are fast and draw more power; efficiency cores are slower and frugal. IPC is how many instructions an app gets through per clock cycle.")
                .appFont(.caption).foregroundStyle(.secondary)
            } else {
                Text("IPC is how many instructions an app gets through per clock cycle. This chip has more than two kinds of cores, so the split by core type is not shown.")
                    .appFont(.caption).foregroundStyle(.secondary)
            }
            if busy.isEmpty {
                Text("No app is busy right now.").foregroundStyle(.secondary)
            }
            ForEach(busy) { app in
                let share = app.pCoreShare ?? 0
                HStack(spacing: 10) {
                    Image(nsImage: IconCache.icon(for: app)).resizable().frame(width: 18, height: 18)
                    Text(app.name).lineLimit(1).textColumn(width: 170, alignment: .leading)
                    if attributed {
                    GeometryReader { geo in
                        HStack(spacing: 0) {
                            Rectangle().fill(Color.blue).frame(width: geo.size.width * share)
                            Rectangle().fill(Color.teal.opacity(0.7))
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                    .frame(height: 8)
                    Text("P \(Int((share * 100).rounded())) %").monospacedDigit().textColumn(width: 56, alignment: .trailing)
                    } else {
                        Spacer()
                    }
                    Text(app.ipc.map { String(format: String(localized: "IPC %.2f"), $0) } ?? "–").monospacedDigit().foregroundStyle(.secondary)
                        .textColumn(width: 70, alignment: .trailing)
                }
                .appFont(.callout)
                .help(attributed ? String(localized: "\(Format.percent(app.cpuPercent)) CPU · \(Int((share * 100).rounded())) % on performance cores") : Format.percent(app.cpuPercent))
            }
            HStack(spacing: 14) {
                if attributed {
                    Label("Performance cores", systemImage: "square.fill").foregroundStyle(.blue)
                    Label("Efficiency cores", systemImage: "square.fill").foregroundStyle(.teal)
                }
                Spacer()
                Text("Only your own processes; system processes need the helper.").foregroundStyle(.tertiary)
            }
            .appFont(.caption2)
        }
    }
}

/// Memory apps hold for the Neural Engine: Core ML and local models, which a GPU meter never shows.
struct NeuralEngineCard: View {
    let apps: [AppGroup]
    /// Neural Engine power from IOReport; nil or 0 where the energy channel reads nothing (M1 Max on macOS 27).
    var watts: Double? = nil

    private var users: [AppGroup] {
        apps.filter { $0.neuralMemory > 0 }.sorted { $0.neuralMemory > $1.neuralMemory }
    }

    var body: some View {
        Card {
            CardHeader(title: "Neural Engine", systemImage: "brain", tint: .pink,
                       trailing: users.isEmpty ? nil : Format.memory(users.reduce(0) { $0 + $1.neuralMemory }))
            if let watts, watts > 0.005 {
                StatLine(label: "Power", value: Format.watts(watts))
            }
            if users.isEmpty {
                Text("No app holds Neural Engine memory right now. Apps that run Core ML or local models show up here.")
                    .appFont(.callout).foregroundStyle(.secondary)
            }
            ForEach(users.prefix(8)) { app in
                HStack(spacing: 10) {
                    Image(nsImage: IconCache.icon(for: app)).resizable().frame(width: 18, height: 18)
                    Text(app.name).lineLimit(1)
                    Spacer()
                    Text(Format.memory(app.neuralMemory)).monospacedDigit().foregroundStyle(.secondary)
                }
                .appFont(.callout)
            }
        }
    }
}
