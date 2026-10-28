import ActivityCore
import Foundation
import Observation

/// "Let other Macs see this Mac" (Settings → Sharing): a read-only summary over HTTP for Macs that paired
/// with a code, advertised with Bonjour. Off by default; nothing listens until the switch is turned on.
@MainActor @Observable
final class ShareServer {
    static let shared = ShareServer()
    static let enabledKey = "shareThisMac"

    var enabled: Bool {
        didSet {
            guard enabled != oldValue else { return }
            UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
            apply()
        }
    }

    private(set) var state: MiniHTTPServer.State = .stopped
    private(set) var viewers: [PairedViewer] = []
    /// The code shown in Settings while another Mac pairs; nil when pairing is closed.
    private(set) var pairing: PairingCode?
    /// When a paired Mac last read the summary (kept in memory: writing the Keychain every few seconds would be wasteful).
    private(set) var lastRead: [UUID: Date] = [:]
    /// A wrong code was entered for the open pairing.
    private(set) var wrongCodeAt: Date?

    @ObservationIgnored private var server: MiniHTTPServer?
    @ObservationIgnored private var expiryTimer: Timer?
    @ObservationIgnored private var triedFallbackPort = false

    private static let environment = ProcessInfo.processInfo.environment
    /// Test hooks: `ACTIVITYPLUS_SHARE=1` turns sharing on without touching the setting, `ACTIVITYPLUS_SHARE_PORT`
    /// picks the port, `ACTIVITYPLUS_SHARE_LOOPBACK=1` listens on 127.0.0.1 only and skips Bonjour (no local-network prompt).
    private static var forcedOn: Bool { environment["ACTIVITYPLUS_SHARE"] == "1" }
    private static var loopbackOnly: Bool { environment["ACTIVITYPLUS_SHARE_LOOPBACK"] == "1" }
    static var preferredPort: UInt16 { environment["ACTIVITYPLUS_SHARE_PORT"].flatMap { UInt16($0) } ?? RemoteMachine.sharePort }

    private init() {
        enabled = Self.forcedOn || UserDefaults.standard.bool(forKey: Self.enabledKey)
        viewers = Self.loadViewers()
    }

    /// Called once at launch.
    func start() {
        apply()
        // Test runs (ACTIVITYPLUS_SHARE=1 with snapshots): open pairing and log the code so a script can pair.
        if Self.forcedOn, SnapshotRunner.isActive {
            startPairing()
            NSLog("share test: pairing code %@", pairing?.code ?? "-")
        }
    }

    var listeningPort: UInt16? {
        if case .listening(let port) = state { return port }
        return nil
    }

    private func apply() {
        if enabled {
            guard server == nil else { return }
            triedFallbackPort = false
            listen(on: Self.preferredPort)
        } else {
            server?.stop()
            server = nil
            state = .stopped
            cancelPairing()
        }
    }

    private func listen(on port: UInt16) {
        let server = MiniHTTPServer { request, reply in
            Task { @MainActor in reply(ShareServer.shared.handle(request)) }
        }
        self.server = server
        let bonjour = Self.loopbackOnly ? nil : MiniHTTPServer.Bonjour(type: RemoteMachine.bonjourType, txt: ["v": String(RemoteSummary.schema)])
        server.start(port: port, loopbackOnly: Self.loopbackOnly, bonjour: bonjour) { state in
            Task { @MainActor in ShareServer.shared.listenerChanged(state, server: server) }
        }
    }

    private func listenerChanged(_ newState: MiniHTTPServer.State, server: MiniHTTPServer) {
        guard server === self.server else { return }
        // The usual port is taken (another copy of Activity+?): any free port still works through Bonjour.
        if case .failed = newState, !triedFallbackPort, enabled {
            triedFallbackPort = true
            server.stop()
            listen(on: 0)
            return
        }
        state = newState
    }

    // MARK: Requests

    private func handle(_ request: MiniHTTP.Request) -> MiniHTTP.Response {
        guard enabled else { return .error(503, "sharing is off") }
        var responder = ShareResponder(name: ThisMac.computerName, appVersion: ThisMac.appVersion, viewers: viewers, pairing: pairing)
        let (response, event) = responder.respond(to: request) { Self.summaryData() }
        pairing = responder.pairing.flatMap { $0.isActive() ? $0 : nil }
        switch event {
        case .paired(let viewer):
            viewers.append(viewer)
            lastRead[viewer.id] = Date()
            saveViewers()
            pairing = nil
            expiryTimer?.invalidate()
        case .seen(let id):
            lastRead[id] = Date()
        case .wrongCode:
            wrongCodeAt = Date()
        case .none:
            break
        }
        return response
    }

    private static func summaryData() -> Data? {
        let monitor = Monitor.shared
        guard monitor.sampleCount > 0 else { return nil }
        let summary = RemoteSummary(snapshot: monitor.snapshot, name: ThisMac.computerName, model: ShareCard.macModel, appVersion: ThisMac.appVersion)
        return try? summary.encoded()
    }

    // MARK: Pairing

    func startPairing() {
        pairing = .random()
        wrongCodeAt = nil
        expiryTimer?.invalidate()
        expiryTimer = Timer.scheduledTimer(withTimeInterval: PairingCode.lifetime, repeats: false) { _ in
            MainActor.assumeIsolated { ShareServer.shared.pairing = nil }
        }
    }

    func cancelPairing() {
        pairing = nil
        expiryTimer?.invalidate()
        expiryTimer = nil
    }

    /// The Mac's token stops working right away.
    func remove(_ viewer: PairedViewer) {
        viewers.removeAll { $0.id == viewer.id }
        lastRead[viewer.id] = nil
        saveViewers()
    }

    private static func loadViewers() -> [PairedViewer] {
        guard let data = SecretStore.read(service: SecretStore.viewersService, account: "viewers") else { return [] }
        return (try? JSONDecoder().decode([PairedViewer].self, from: data)) ?? []
    }

    private func saveViewers() {
        SecretStore.write(try? JSONEncoder().encode(viewers), service: SecretStore.viewersService, account: "viewers")
    }
}
