import Foundation

/// Runs one system tool and returns its output; used for the small read-only status commands.
public enum ToolRunner {
    public struct Result: Sendable {
        public let status: Int32
        public let output: String
        public var succeeded: Bool { status == 0 }
    }

    /// stdout and stderr are merged. A tool that does not finish within `timeout` seconds is stopped.
    public static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 8) -> Result {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return Result(status: -1, output: error.localizedDescription) }
        let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        killer.cancel()
        return Result(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }
}
