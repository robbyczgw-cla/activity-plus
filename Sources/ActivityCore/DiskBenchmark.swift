import Darwin
import Foundation

/// Sequential read/write speed of the startup disk, like Sensei's and Blackmagic's disk tests.
/// Writes one test file with the page cache disabled (F_NOCACHE), so the figures are the SSD's,
/// not memory's. The file is removed afterwards, also when the test is cancelled or fails.
public final class DiskBenchmark: @unchecked Sendable {
    public struct Result: Codable, Sendable, Hashable {
        public let date: Date
        public let bytes: UInt64
        public let writeMBps: Double
        public let readMBps: Double
    }

    public enum Failure: LocalizedError {
        case notEnoughSpace(needed: UInt64, free: UInt64)
        case io(String)
        case cancelled
        public var errorDescription: String? {
            switch self {
            case .notEnoughSpace(let needed, let free):
                "The test needs \(Format.storage(needed * 3)) free; the disk has \(Format.storage(free))."
            case .io(let message): "The test could not write to the disk: \(message)"
            case .cancelled: "The test was stopped."
            }
        }
    }

    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    public func cancel() { lock.withLock { cancelled = true } }
    private var isCancelled: Bool { lock.withLock { cancelled } }

    /// Runs on the calling thread (call it off the main thread). `progress` gets 0…1 and the phase.
    public func run(bytes: UInt64 = 1 << 30, progress: @escaping @Sendable (Double, String) -> Void) throws -> Result {
        lock.withLock { cancelled = false }
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Activity+", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("speedtest-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: url) }

        // Keep a generous margin: never push a nearly full disk over the edge.
        let free = UInt64((try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? 0)
        guard free > bytes * 3 else { throw Failure.notEnoughSpace(needed: bytes, free: free) }

        let blockSize = 8 << 20
        let blocks = Int(bytes / UInt64(blockSize))
        // Random data, so compression or deduplication in the controller cannot flatter the result.
        var buffer = [UInt8](repeating: 0, count: blockSize)
        buffer.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, blockSize) }

        // Write
        let writeFD = open(url.path, O_CREAT | O_WRONLY | O_TRUNC, 0o600)
        guard writeFD >= 0 else { throw Failure.io(String(cString: strerror(errno))) }
        _ = fcntl(writeFD, F_NOCACHE, 1)
        let writeStart = DispatchTime.now().uptimeNanoseconds
        for index in 0..<blocks {
            if isCancelled { close(writeFD); throw Failure.cancelled }
            let written = buffer.withUnsafeBytes { write(writeFD, $0.baseAddress, blockSize) }
            guard written == blockSize else { close(writeFD); throw Failure.io(String(cString: strerror(errno))) }
            progress(Double(index + 1) / Double(blocks) * 0.5, "Writing")
        }
        _ = fcntl(writeFD, F_FULLFSYNC)   // make sure the data really reached the SSD before stopping the clock
        let writeSeconds = Double(DispatchTime.now().uptimeNanoseconds - writeStart) / 1e9
        close(writeFD)

        // Read
        let readFD = open(url.path, O_RDONLY)
        guard readFD >= 0 else { throw Failure.io(String(cString: strerror(errno))) }
        _ = fcntl(readFD, F_NOCACHE, 1)
        let readStart = DispatchTime.now().uptimeNanoseconds
        for index in 0..<blocks {
            if isCancelled { close(readFD); throw Failure.cancelled }
            let read = buffer.withUnsafeMutableBytes { Darwin.read(readFD, $0.baseAddress, blockSize) }
            guard read == blockSize else { close(readFD); throw Failure.io(String(cString: strerror(errno))) }
            progress(0.5 + Double(index + 1) / Double(blocks) * 0.5, "Reading")
        }
        let readSeconds = Double(DispatchTime.now().uptimeNanoseconds - readStart) / 1e9
        close(readFD)

        let megabytes = Double(UInt64(blocks) * UInt64(blockSize)) / 1_000_000
        return Result(date: Date(), bytes: UInt64(blocks * blockSize),
                      writeMBps: megabytes / max(writeSeconds, 0.001), readMBps: megabytes / max(readSeconds, 0.001))
    }
}
