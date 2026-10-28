import ActivityCore
import Foundation
import Network
import Observation
import UserNotifications

/// The machines on "Other Macs": paired Activity+ Macs and node_exporter servers. They are only contacted while
/// the page is open (every 5 s), or once a minute in the background when "Notify me when one goes offline" is on.
@MainActor @Observable
final class RemoteMachinesModel {
    static let shared = RemoteMachinesModel()
    static let machinesKey = "remoteMachines"
    static let notifyKey = "remoteNotifyOffline"
    static let pageInterval: TimeInterval = 5
    static let backgroundInterval: TimeInterval = 60

    struct Live: Equatable {
        var status: RemoteStatus?
        var online: Bool?
        var lastSeen: Date?
        var error: String?
        /// The Mac no longer accepts our token (removed there): pair again.
        var needsPairing = false
        var failures = 0
    }

    /// An Activity+ Mac seen on the network through Bonjour.
    struct Discovered: Identifiable, Hashable {
        let name: String
        var id: String { name }
    }

    private(set) var machines: [RemoteMachine] = []
    private(set) var live: [UUID: Live] = [:]
    private(set) var discovered: [Discovered] = []
    private(set) var browsing = false
    var notifyOffline: Bool {
        didSet {
            UserDefaults.standard.set(notifyOffline, forKey: Self.notifyKey)
            scheduleBackground()
        }
    }

    @ObservationIgnored private var previous: [UUID: (reading: NodeExporterReading, at: Date)] = [:]
    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private var pageTask: Task<Void, Never>?
    @ObservationIgnored private var backgroundTimer: Timer?
    @ObservationIgnored private var pageVisible = false
    @ObservationIgnored private var refreshing = false
    @ObservationIgnored private var notifiedOffline: Set<UUID> = []

    private init() {
        let stored = Self.testFile.flatMap { try? Data(contentsOf: $0) } ?? UserDefaults.standard.data(forKey: Self.machinesKey)
        machines = stored.flatMap { try? JSONDecoder().decode([RemoteMachine].self, from: $0) } ?? []
        notifyOffline = UserDefaults.standard.bool(forKey: Self.notifyKey)
    }

    /// Called once at launch: only the background watch, when it is on.
    func start() { scheduleBackground() }

    // MARK: Page visibility

    func pageAppeared() {
        pageVisible = true
        startBrowsing()
        pageTask?.cancel()
        pageTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshAll()
                try? await Task.sleep(for: .seconds(Self.pageInterval))
            }
        }
    }

    func pageDisappeared() {
        pageVisible = false
        pageTask?.cancel()
        pageTask = nil
        stopBrowsing()
    }

    private func scheduleBackground() {
        backgroundTimer?.invalidate()
        backgroundTimer = nil
        guard notifyOffline, !machines.isEmpty else { return }
        backgroundTimer = Timer.scheduledTimer(withTimeInterval: Self.backgroundInterval, repeats: true) { _ in
            MainActor.assumeIsolated {
                let model = RemoteMachinesModel.shared
                guard !model.pageVisible else { return }
                Task { await model.refreshAll() }
            }
        }
    }

    // MARK: Bonjour

    /// Browsing is what may make macOS ask for local network access; it only runs while the page is open.
    /// Snapshot runs skip it, so they never trigger that prompt.
    private func startBrowsing() {
        guard browser == nil, !SnapshotRunner.isActive else { return }
        let browser = NWBrowser(for: .bonjour(type: RemoteMachine.bonjourType, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { results, _ in
            let names = results.compactMap { result -> String? in
                if case .service(let name, _, _, _) = result.endpoint { return name }
                return nil
            }
            Task { @MainActor in RemoteMachinesModel.shared.discoveredChanged(names) }
        }
        browser.stateUpdateHandler = { state in
            Task { @MainActor in
                switch state {
                case .ready: RemoteMachinesModel.shared.browsing = true
                case .failed, .cancelled: RemoteMachinesModel.shared.browsing = false
                default: break
                }
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    private func stopBrowsing() {
        browser?.cancel()
        browser = nil
        browsing = false
    }

    private func discoveredChanged(_ names: [String]) {
        let own = ShareServer.shared.enabled ? ThisMac.computerName : nil
        let added = Set(machines.compactMap(\.serviceName))
        discovered = Set(names).subtracting(added).filter { $0 != own }.sorted().map(Discovered.init)
    }

    // MARK: Fetching

    private static func endpoint(for machine: RemoteMachine) -> (NWEndpoint, String)? {
        if let host = machine.host {
            let port = machine.port ?? (machine.kind == .mac ? RemoteMachine.sharePort : RemoteMachine.nodeExporterPort)
            guard let nwPort = NWEndpoint.Port(rawValue: port) else { return nil }
            return (.hostPort(host: NWEndpoint.Host(host), port: nwPort), host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)")
        }
        if let service = machine.serviceName {
            return (.service(name: service, type: RemoteMachine.bonjourType, domain: "local.", interface: nil), "\(service).local")
        }
        return nil
    }

    private static func bonjourEndpoint(_ name: String) -> NWEndpoint {
        .service(name: name, type: RemoteMachine.bonjourType, domain: "local.", interface: nil)
    }

    func refreshAll() async {
        guard !refreshing, !machines.isEmpty else { return }
        refreshing = true
        defer { refreshing = false }
        await withTaskGroup(of: Void.self) { group in
            for machine in machines {
                group.addTask { await self.refresh(machine) }
            }
        }
    }

    func refresh(_ machine: RemoteMachine) async {
        var entry = live[machine.id] ?? Live()
        do {
            let status = try await fetch(machine)
            entry.status = status
            entry.online = true
            entry.lastSeen = Date()
            entry.error = nil
            entry.needsPairing = false
            entry.failures = 0
            if notifiedOffline.remove(machine.id) != nil { notifyBack(machine) }
        } catch let failure as FetchFailure where failure == .notPaired {
            entry.online = true
            entry.lastSeen = Date()
            entry.needsPairing = true
            entry.error = failure.localizedDescription
        } catch is CancellationError {
            return
        } catch {
            entry.online = false
            entry.failures += 1
            entry.error = error.localizedDescription
            previous[machine.id] = nil
            if entry.failures >= 2, notifyOffline, !notifiedOffline.contains(machine.id) {
                notifiedOffline.insert(machine.id)
                notifyOffline(machine)
            }
        }
        // Removed while the request was running.
        guard machines.contains(where: { $0.id == machine.id }) else { return }
        live[machine.id] = entry
    }

    enum FetchFailure: LocalizedError, Equatable {
        case notPaired
        case status(Int)
        case notAMetricsPage
        case notActivityPlus
        case newerVersion

        var errorDescription: String? {
            switch self {
            case .notPaired: String(localized: "This Mac no longer accepts this Mac. Pair again.")
            case .status(let code): String(localized: "The server answered with error \(code).")
            case .notAMetricsPage: String(localized: "This address does not serve node_exporter metrics.")
            case .notActivityPlus: String(localized: "This is not an Activity+ Mac that shares.")
            case .newerVersion: String(localized: "This Mac runs a newer Activity+. Update Activity+ here to read it.")
            }
        }
    }

    private func fetch(_ machine: RemoteMachine) async throws -> RemoteStatus {
        guard let (endpoint, host) = Self.endpoint(for: machine) else { throw FetchFailure.notActivityPlus }
        switch machine.kind {
        case .mac:
            guard let token = Self.token(for: machine.id) else { throw FetchFailure.notPaired }
            let request = MiniHTTP.Request(method: "GET", path: "/v1/summary", headers: ["Authorization": "Bearer \(token)", "Accept": "application/json"])
            let response = try await MiniHTTPClient.send(request, to: endpoint, host: host)
            if response.status == 401 { throw FetchFailure.notPaired }
            guard response.status == 200 else { throw FetchFailure.status(response.status) }
            do { return RemoteStatus(summary: try RemoteSummary.decode(response.body)) } catch { throw FetchFailure.newerVersion }
        case .nodeExporter:
            let reading = try await Self.readNodeExporter(endpoint: endpoint, host: host, path: machine.path ?? "/metrics")
            let now = Date()
            var rates: NodeExporterRates?
            if let last = previous[machine.id] {
                let interval = (reading.serverTime ?? 0) > (last.reading.serverTime ?? 0) && last.reading.serverTime != nil
                    ? reading.serverTime! - last.reading.serverTime! : now.timeIntervalSince(last.at)
                rates = NodeExporterRates(previous: last.reading, current: reading, interval: interval)
            }
            previous[machine.id] = (reading, now)
            return RemoteStatus(reading: reading, rates: rates)
        }
    }

    private static func readNodeExporter(endpoint: NWEndpoint, host: String, path: String) async throws -> NodeExporterReading {
        // Plain text, no gzip: the client does not decompress.
        let request = MiniHTTP.Request(method: "GET", path: path, headers: ["Accept": "text/plain"])
        let response = try await MiniHTTPClient.send(request, to: endpoint, host: host, timeout: 10)
        guard response.status == 200 else { throw FetchFailure.status(response.status) }
        let reading = NodeExporterReading(text: String(decoding: response.body, as: UTF8.self))
        guard reading.cpuTotalSeconds != nil || reading.memoryTotal != nil else { throw FetchFailure.notAMetricsPage }
        return reading
    }

    // MARK: Adding, pairing, removing

    enum PairFailure: LocalizedError {
        case wrongCode
        case closed
        case unreachable(String)

        var errorDescription: String? {
            switch self {
            case .wrongCode: String(localized: "That code is not right. Check the code on the other Mac and try again.")
            case .closed: String(localized: "Pairing is not open on the other Mac. Click Pair a Mac in its Settings → Sharing to get a new code.")
            case .unreachable(let reason): reason
            }
        }
    }

    /// Trades the code shown on the other Mac for a token, then adds that Mac (or updates it, when pairing again).
    func pair(serviceName: String?, host: String?, port: UInt16?, code: String, replacing existing: RemoteMachine? = nil) async throws {
        var machine = existing ?? RemoteMachine(kind: .mac, name: serviceName ?? host ?? "Mac", serviceName: serviceName, host: host, port: port)
        guard let (endpoint, hostHeader) = Self.endpoint(for: machine) else { throw PairFailure.unreachable(FetchFailure.notActivityPlus.localizedDescription) }
        let body = try JSONEncoder().encode(ShareResponder.PairRequest(code: code, name: ThisMac.computerName))
        let request = MiniHTTP.Request(method: "POST", path: "/v1/pair", headers: ["Content-Type": "application/json"], body: body)
        let response: MiniHTTP.Response
        do {
            response = try await MiniHTTPClient.send(request, to: endpoint, host: hostHeader)
        } catch {
            throw PairFailure.unreachable(error.localizedDescription)
        }
        guard response.status == 200, let answer = try? JSONDecoder().decode(ShareResponder.PairResponse.self, from: response.body) else {
            let message = (try? JSONSerialization.jsonObject(with: response.body) as? [String: String])?["error"] ?? ""
            throw message == "wrong code" ? PairFailure.wrongCode : (response.status == 403 ? PairFailure.closed : PairFailure.unreachable(FetchFailure.status(response.status).localizedDescription))
        }
        if existing == nil { machine.name = answer.name }
        SecretStore.write(Data(answer.token.utf8), service: SecretStore.tokensService, account: machine.id.uuidString)
        if let index = machines.firstIndex(where: { $0.id == machine.id }) { machines[index] = machine } else { machines.append(machine) }
        live[machine.id]?.needsPairing = false
        save()
        discovered.removeAll { $0.name == serviceName }
        await refresh(machine)
    }

    /// Checks the address once before adding, so a typo shows up right away.
    func addServer(address: String, name: String, force: Bool = false) async throws {
        let parsed = try RemoteMachine.parseAddress(address)
        var machine = RemoteMachine(kind: .nodeExporter, name: name, host: parsed.host, port: parsed.port, path: parsed.path)
        if !force {
            guard let (endpoint, host) = Self.endpoint(for: machine) else { throw RemoteMachine.AddressError.invalid }
            let reading = try await Self.readNodeExporter(endpoint: endpoint, host: host, path: parsed.path)
            if machine.name.trimmingCharacters(in: .whitespaces).isEmpty { machine.name = reading.hostName ?? parsed.host }
        }
        if machine.name.trimmingCharacters(in: .whitespaces).isEmpty { machine.name = parsed.host }
        machines.append(machine)
        save()
        await refresh(machine)
    }

    func rename(_ machine: RemoteMachine, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = machines.firstIndex(where: { $0.id == machine.id }) else { return }
        machines[index].name = trimmed
        save()
    }

    func remove(_ machine: RemoteMachine) {
        machines.removeAll { $0.id == machine.id }
        live[machine.id] = nil
        previous[machine.id] = nil
        notifiedOffline.remove(machine.id)
        SecretStore.write(nil, service: SecretStore.tokensService, account: machine.id.uuidString)
        save()
    }

    private static func token(for id: UUID) -> String? {
        SecretStore.read(service: SecretStore.tokensService, account: id.uuidString).map { String(decoding: $0, as: UTF8.self) }
    }

    /// With `ACTIVITYPLUS_SECRETS_DIR` (tests) the list goes next to the secrets, not into the shared defaults.
    private static var testFile: URL? {
        ProcessInfo.processInfo.environment["ACTIVITYPLUS_SECRETS_DIR"].map { URL(fileURLWithPath: $0).appendingPathComponent("machines.json") }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(machines) {
            if let file = Self.testFile { try? data.write(to: file, options: .atomic) } else { UserDefaults.standard.set(data, forKey: Self.machinesKey) }
        }
        scheduleBackground()
    }

    // MARK: Notifications

    private func notifyOffline(_ machine: RemoteMachine) {
        post(id: "remote-offline-\(machine.id)", title: String(localized: "\(machine.name) is offline"),
             body: String(localized: "Activity+ could not reach it twice in a row."))
    }

    private func notifyBack(_ machine: RemoteMachine) {
        post(id: "remote-offline-\(machine.id)", title: String(localized: "\(machine.name) is back online"), body: "")
    }

    private func post(id: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.threadIdentifier = "remote"
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }
}
