import ActivityCore
import SwiftUI

/// Sequential read/write test of the startup disk (writes and removes one 1 GB file).
struct SpeedTestCard: View {
    @State private var running = false
    @State private var progress: (Double, String) = (0, "")
    @State private var results: [DiskBenchmark.Result] = SpeedTestCard.load()
    @State private var error: String?
    @State private var benchmark: DiskBenchmark?

    var body: some View {
        Card {
            HStack {
                CardHeader(title: "Speed test", systemImage: "speedometer", tint: .orange)
                Spacer()
                if running {
                    ProgressView(value: progress.0).frame(width: 140)
                    Text(progress.1).font(.caption).foregroundStyle(.secondary).frame(width: 60, alignment: .leading)
                    Button("Stop") { benchmark?.cancel() }
                } else {
                    Button("Run Test") { run() }
                        .help("Writes and reads one 1 GB file in your caches folder, then removes it.")
                }
            }
            if let latest = results.first {
                HStack(spacing: 40) {
                    figure("Write", latest.writeMBps)
                    figure("Read", latest.readMBps)
                    Spacer()
                    Text("Measured \(latest.date.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                }
                if results.count > 1 {
                    Text("Earlier: " + results.dropFirst().prefix(4).map { String(format: "%.0f / %.0f MB/s", $0.writeMBps, $0.readMBps) }.joined(separator: ", "))
                        .font(.caption).foregroundStyle(.tertiary)
                }
            } else if !running {
                Text("Measures how fast your SSD writes and reads large files. Takes a few seconds and writes 1 GB, which is removed afterwards.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let error { Text(error).font(.callout).foregroundStyle(.red) }
        }
    }

    private func figure(_ title: String, _ mbps: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            BigNumber(text: mbps >= 1000 ? String(format: "%.2f GB/s", mbps / 1000) : String(format: "%.0f MB/s", mbps), size: 26)
        }
    }

    private func run() {
        let test = DiskBenchmark()
        benchmark = test
        running = true
        error = nil
        Task.detached(priority: .userInitiated) {
            do {
                let result = try test.run { fraction, phase in
                    Task { @MainActor in progress = (fraction, phase) }
                }
                await MainActor.run {
                    results.insert(result, at: 0)
                    results = Array(results.prefix(10))
                    SpeedTestCard.save(results)
                    running = false
                }
            } catch {
                await MainActor.run {
                    self.error = error.localizedDescription
                    running = false
                }
            }
        }
    }

    static func load() -> [DiskBenchmark.Result] {
        guard let data = UserDefaults.standard.data(forKey: "speedTestResults") else { return [] }
        return (try? JSONDecoder().decode([DiskBenchmark.Result].self, from: data)) ?? []
    }

    static func save(_ results: [DiskBenchmark.Result]) {
        if let data = try? JSONEncoder().encode(results) { UserDefaults.standard.set(data, forKey: "speedTestResults") }
    }
}
