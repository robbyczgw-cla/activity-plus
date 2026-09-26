import ActivityCore
import SwiftUI

/// Where each busy app runs: performance or efficiency cores, and how much work it gets done per clock cycle.
struct CoreTypeCard: View {
    let apps: [AppGroup]

    private var busy: [AppGroup] {
        apps.filter { $0.pCoreShare != nil && $0.cpuPercent >= 1 }.sorted { $0.cpuPercent > $1.cpuPercent }.prefix(8).map { $0 }
    }

    var body: some View {
        Card {
            CardHeader(title: "Performance and efficiency cores", systemImage: "cpu.fill", tint: .blue)
            Text("Performance cores are fast and draw more power; efficiency cores are slower and frugal. IPC is how many instructions an app gets through per clock cycle.")
                .font(.caption).foregroundStyle(.secondary)
            if busy.isEmpty {
                Text("No app is busy right now.").foregroundStyle(.secondary)
            }
            ForEach(busy) { app in
                let share = app.pCoreShare ?? 0
                HStack(spacing: 10) {
                    Image(nsImage: IconCache.icon(for: app)).resizable().frame(width: 18, height: 18)
                    Text(app.name).lineLimit(1).frame(width: 170, alignment: .leading)
                    GeometryReader { geo in
                        HStack(spacing: 0) {
                            Rectangle().fill(Color.blue).frame(width: geo.size.width * share)
                            Rectangle().fill(Color.teal.opacity(0.7))
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                    .frame(height: 8)
                    Text("P \(Int((share * 100).rounded())) %").monospacedDigit().frame(width: 56, alignment: .trailing)
                    Text(app.ipc.map { String(format: "IPC %.2f", $0) } ?? "–").monospacedDigit().foregroundStyle(.secondary)
                        .frame(width: 70, alignment: .trailing)
                }
                .font(.callout)
                .help("\(Format.percent(app.cpuPercent)) CPU · \(Int((share * 100).rounded())) % on performance cores")
            }
            HStack(spacing: 14) {
                Label("Performance cores", systemImage: "square.fill").foregroundStyle(.blue)
                Label("Efficiency cores", systemImage: "square.fill").foregroundStyle(.teal)
                Spacer()
                Text("Only your own processes; system processes need the helper.").foregroundStyle(.tertiary)
            }
            .font(.caption2)
        }
    }
}

/// Memory apps hold for the Neural Engine: Core ML and local models, which a GPU meter never shows.
struct NeuralEngineCard: View {
    let apps: [AppGroup]

    private var users: [AppGroup] {
        apps.filter { $0.neuralMemory > 0 }.sorted { $0.neuralMemory > $1.neuralMemory }
    }

    var body: some View {
        Card {
            CardHeader(title: "Neural Engine", systemImage: "brain", tint: .pink,
                       trailing: users.isEmpty ? nil : Format.memory(users.reduce(0) { $0 + $1.neuralMemory }))
            if users.isEmpty {
                Text("No app holds Neural Engine memory right now. Apps that run Core ML or local models show up here.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(users.prefix(8)) { app in
                HStack(spacing: 10) {
                    Image(nsImage: IconCache.icon(for: app)).resizable().frame(width: 18, height: 18)
                    Text(app.name).lineLimit(1)
                    Spacer()
                    Text(Format.memory(app.neuralMemory)).monospacedDigit().foregroundStyle(.secondary)
                }
                .font(.callout)
            }
        }
    }
}
