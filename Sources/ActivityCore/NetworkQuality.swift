import Darwin
import Foundation

/// One run of Apple's built-in `networkQuality` tool (`-c -s`: JSON output, sequential tests).
public struct NetworkQualityResult: Codable, Sendable, Identifiable, Equatable {
    /// Apple's three rating words for responsiveness.
    public enum Rating: String, Codable, Sendable, CaseIterable {
        case low, medium, high

        public var label: String {
            switch self {
            case .low: String(localized: "Low")
            case .medium: String(localized: "Medium")
            case .high: String(localized: "High")
            }
        }
    }

    public let id: UUID
    public let date: Date
    public let downloadMbps: Double
    public let uploadMbps: Double
    /// Round trips per minute while downloading (load-under-download responsiveness).
    public let downloadRPM: Double?
    /// Round trips per minute while uploading.
    public let uploadRPM: Double?
    /// Latency with no load, in milliseconds.
    public let idleLatencyMs: Double?
    public let interface: String?
    public let endpoint: String?

    /// One headline number: the slower of the two directions, so a bad direction is not hidden.
    public var responsivenessRPM: Double? { [downloadRPM, uploadRPM].compactMap { $0 }.min() }
    public var rating: Rating? { responsivenessRPM.map(NetworkQuality.rating(forRPM:)) }

    public init(id: UUID = UUID(), date: Date, downloadMbps: Double, uploadMbps: Double, downloadRPM: Double?,
                uploadRPM: Double?, idleLatencyMs: Double?, interface: String?, endpoint: String?) {
        self.id = id
        self.date = date
        self.downloadMbps = downloadMbps
        self.uploadMbps = uploadMbps
        self.downloadRPM = downloadRPM
        self.uploadRPM = uploadRPM
        self.idleLatencyMs = idleLatencyMs
        self.interface = interface
        self.endpoint = endpoint
    }
}

public enum NetworkQuality {
    public static let historyLimit = 10

    /// Apple's bands: below 300 RPM is low, up to 1000 medium, above that high.
    public static func rating(forRPM rpm: Double) -> NetworkQualityResult.Rating {
        if rpm < 300 { return .low }
        return rpm <= 1000 ? .medium : .high
    }

    /// Reads the JSON that `networkQuality -c -s` prints. Nil when the throughput figures are missing.
    /// Units in the tool's output: throughput in bits per second, latency and RPM as plain numbers.
    public static func parse(_ data: Data, date: Date = Date()) -> NetworkQualityResult? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let down = number(object["dl_throughput"]),
              let up = number(object["ul_throughput"])
        else { return nil }
        return NetworkQualityResult(
            date: date,
            downloadMbps: down / 1_000_000,
            uploadMbps: up / 1_000_000,
            downloadRPM: number(object["dl_responsiveness"]),
            uploadRPM: number(object["ul_responsiveness"]),
            idleLatencyMs: number(object["base_rtt"]),
            interface: object["interface_name"] as? String,
            endpoint: object["test_endpoint"] as? String
        )
    }

    /// Newest first, keeping only `historyLimit` entries.
    public static func history(adding result: NetworkQualityResult, to history: [NetworkQualityResult]) -> [NetworkQualityResult] {
        Array(([result] + history).prefix(historyLimit))
    }

    private static func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }
}

/// Runs `networkQuality -c -s` once, in the background. `cancel()` stops a running test.
public final class NetworkQualityRun: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    public init() {}

    public var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    public func cancel() {
        lock.lock()
        cancelled = true
        let running = process
        lock.unlock()
        if let running, running.isRunning { running.terminate() }
    }

    /// Takes about 20 to 30 seconds. Nil when the test failed or was cancelled.
    public func run() async -> NetworkQualityResult? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: self.runBlocking())
            }
        }
    }

    private func runBlocking() -> NetworkQualityResult? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/networkQuality")
        process.arguments = ["-c", "-s"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        lock.lock()
        if cancelled { lock.unlock(); return nil }
        do { try process.run() } catch { lock.unlock(); return nil }
        self.process = process
        lock.unlock()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard !isCancelled, process.terminationStatus == 0 else { return nil }
        return NetworkQuality.parse(data)
    }
}
