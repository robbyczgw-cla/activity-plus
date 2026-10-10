import ActivityCore
import SwiftUI

/// On-demand throughput, responsiveness and latency test using Apple's built-in networkQuality tool.
struct NetworkQualityCard: View {
    @State private var runner: NetworkQualityRun?
    @State private var history: [NetworkQualityResult] = NetworkQualityCard.load()
    @State private var message: String?

    private static let storageKey = "networkQuality.history"

    var body: some View {
        Card {
            HStack {
                CardHeader(title: "Network quality", systemImage: "gauge.with.dots.needle.50percent", tint: .teal)
                Spacer()
                if runner != nil {
                    ProgressView().controlSize(.small)
                    Text("Testing…").font(.caption).foregroundStyle(.secondary)
                    Button("Stop") { runner?.cancel() }
                } else {
                    Button("Run network test") { start() }
                }
            }
            Text("Runs only when you click. It sends test traffic to Apple's servers.")
                .font(.caption).foregroundStyle(.secondary)

            if let latest = history.first {
                HStack(alignment: .top, spacing: 34) {
                    figure("Download", String(format: "%.0f", latest.downloadMbps), "Mbit/s")
                    figure("Upload", String(format: "%.0f", latest.uploadMbps), "Mbit/s")
                    figure("Responsiveness",
                           latest.responsivenessRPM.map { String(format: "%.0f", $0) } ?? "–",
                           latest.rating.map { "RPM · \($0.label)" } ?? "RPM")
                    figure("Idle latency", latest.idleLatencyMs.map { String(format: "%.0f", $0) } ?? "–", "ms")
                    Spacer()
                    Text("Measured \(latest.date.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let down = latest.downloadRPM, let up = latest.uploadRPM {
                    Text(String(format: "Responsiveness while downloading %.0f RPM, while uploading %.0f RPM", down, up))
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }

            if let message {
                Text(message).font(.callout).foregroundStyle(.secondary)
            }

            if history.count > 1 {
                Divider()
                Text("Earlier results").font(.caption).foregroundStyle(.secondary)
                ForEach(history.dropFirst()) { result in
                    HStack(spacing: 18) {
                        Text(result.date.formatted(date: .abbreviated, time: .shortened))
                            .frame(width: 150, alignment: .leading)
                        Text(String(format: "↓ %.0f Mbit/s", result.downloadMbps)).frame(width: 110, alignment: .leading)
                        Text(String(format: "↑ %.0f Mbit/s", result.uploadMbps)).frame(width: 110, alignment: .leading)
                        Text(result.responsivenessRPM.map { String(format: "%.0f RPM", $0) } ?? "–")
                            .frame(width: 80, alignment: .leading)
                        Text(result.rating?.label ?? "").foregroundStyle(.secondary)
                        Spacer()
                    }
                    .font(.caption).monospacedDigit()
                }
            }
        }
    }

    private func figure(_ title: String, _ value: String, _ unit: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 26, weight: .semibold)).monospacedDigit()
            Text(unit).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func start() {
        let run = NetworkQualityRun()
        runner = run
        message = nil
        Task {
            let result = await run.run()
            runner = nil
            if let result {
                history = NetworkQuality.history(adding: result, to: history)
                save()
            } else {
                message = run.isCancelled ? "Test stopped." : "The test did not finish. Try again."
            }
        }
    }

    private static func load() -> [NetworkQualityResult] {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return [] }
        return (try? JSONDecoder().decode([NetworkQualityResult].self, from: data)) ?? []
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(history) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
}
