import ActivityCore
import Foundation
import HelperShared
import Observation
import ServiceManagement

/// Installs and talks to the privileged helper (a LaunchDaemon managed by SMAppService).
/// Optional: without it, other users' processes show CPU and resident memory only.
@MainActor @Observable
final class HelperClient {
    static let shared = HelperClient()

    enum State: Equatable {
        case notInstalled, needsApproval, running, unavailable(String)
    }

    private(set) var state: State = .notInstalled
    private(set) var lastError: String?

    @ObservationIgnored private let service = SMAppService.daemon(plistName: HelperConstants.plistName)
    @ObservationIgnored private let connectionBox = ConnectionBox()

    func refresh() {
        switch service.status {
        case .enabled: state = .running
        case .requiresApproval: state = .needsApproval
        case .notRegistered, .notFound: state = .notInstalled
        @unknown default: state = .unavailable("Unknown status")
        }
        connectionBox.enabled = state == .running
    }

    func install() {
        do {
            try service.register()
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
        if state == .needsApproval { SMAppService.openSystemSettingsLoginItems() }
    }

    func uninstall() {
        do { try service.unregister() } catch { lastError = error.localizedDescription }
        connectionBox.invalidate()
        refresh()
    }

    /// Hands the sampler a function it can call from its own queue.
    func attach(to monitor: Monitor) {
        refresh()
        let box = connectionBox
        monitor.setPrivilegedUsage { pids in box.usage(for: pids) }
    }
}

/// Thread-safe XPC access for the sampling queue. Calls are synchronous with a short timeout, so a
/// missing or stuck helper never stalls sampling: the app then simply falls back to `ps` figures.
final class ConnectionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var connection: NSXPCConnection?
    private var _enabled = false
    private var failures = 0

    var enabled: Bool {
        get { lock.withLock { _enabled } }
        set { lock.withLock { _enabled = newValue; failures = 0 } }
    }

    func invalidate() {
        lock.withLock {
            connection?.invalidate()
            connection = nil
        }
    }

    func usage(for pids: [Int32]) -> [Int32: PrivilegedUsage] {
        guard enabled, !pids.isEmpty else { return [:] }
        guard let proxy = proxy() else { return [:] }
        let done = DispatchSemaphore(value: 0)
        var data = Data()
        proxy.usage(for: pids.map { NSNumber(value: $0) }) { reply in
            data = reply
            done.signal()
        }
        guard done.wait(timeout: .now() + 0.5) == .success,
              let decoded = try? JSONDecoder().decode([HelperProcessUsage].self, from: data)
        else {
            noteFailure()
            return [:]
        }
        return Dictionary(decoded.map { usage in
            (usage.pid, PrivilegedUsage(
                startTime: Date(timeIntervalSince1970: TimeInterval(usage.startSeconds) + TimeInterval(usage.startMicroseconds) / 1_000_000),
                footprint: usage.footprint, cpuTicks: usage.cpuTicks, diskRead: usage.diskRead,
                diskWritten: usage.diskWritten, energyNJ: usage.energyNJ, path: usage.path))
        }, uniquingKeysWith: { a, _ in a })
    }

    private func proxy() -> ActivityPlusHelperProtocol? {
        lock.lock()
        defer { lock.unlock() }
        if connection == nil {
            let connection = NSXPCConnection(machServiceName: HelperConstants.machService, options: .privileged)
            connection.remoteObjectInterface = NSXPCInterface(with: ActivityPlusHelperProtocol.self)
            connection.invalidationHandler = { [weak self] in self?.lock.withLock { self?.connection = nil } }
            connection.resume()
            self.connection = connection
        }
        return connection?.remoteObjectProxyWithErrorHandler { [weak self] _ in self?.noteFailure() } as? ActivityPlusHelperProtocol
    }

    /// After repeated failures stop trying until the user reinstalls or relaunches.
    private func noteFailure() {
        lock.withLock {
            failures += 1
            if failures >= 5 { _enabled = false }
        }
    }
}
