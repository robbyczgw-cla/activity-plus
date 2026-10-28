import Foundation
import Network

/// A tiny HTTP server on Network.framework: one request per connection, answered by `handler`.
/// Used by "Let other Macs see this Mac"; it never runs unless that switch is on.
public final class MiniHTTPServer: @unchecked Sendable {
    public enum State: Equatable, Sendable {
        case starting
        case listening(port: UInt16)
        case failed(String)
        case stopped
    }

    public typealias Handler = @Sendable (MiniHTTP.Request, @escaping @Sendable (MiniHTTP.Response) -> Void) -> Void

    public struct Bonjour: Sendable {
        public var name: String?
        public var type: String
        public var txt: [String: String]
        public init(name: String? = nil, type: String, txt: [String: String] = [:]) {
            self.name = name
            self.type = type
            self.txt = txt
        }
    }

    public static let maxConnections = 16
    public static let requestTimeout: TimeInterval = 10

    private let queue = DispatchQueue(label: "at.hifiteam.activityplus.share-server")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private let handler: Handler

    public init(handler: @escaping Handler) {
        self.handler = handler
    }

    /// Port 0 picks a free one. `loopbackOnly` binds to 127.0.0.1 (tests); otherwise every interface.
    public func start(port: UInt16, loopbackOnly: Bool = false, bonjour: Bonjour? = nil, onState: @escaping @Sendable (State) -> Void) {
        queue.async { [self] in
            stopLocked()
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            let listener: NWListener
            do {
                if loopbackOnly {
                    parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port) ?? .any)
                    listener = try NWListener(using: parameters)
                } else {
                    listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port) ?? .any)
                }
            } catch {
                onState(.failed(error.localizedDescription))
                return
            }
            if let bonjour {
                let txt = bonjour.txt.isEmpty ? nil : NWTXTRecord(bonjour.txt)
                listener.service = txt.map { NWListener.Service(name: bonjour.name, type: bonjour.type, domain: nil, txtRecord: $0) }
                    ?? NWListener.Service(name: bonjour.name, type: bonjour.type)
            }
            listener.stateUpdateHandler = { [weak listener] state in
                switch state {
                case .ready: onState(.listening(port: listener?.port?.rawValue ?? port))
                case .failed(let error): onState(.failed(error.localizedDescription))
                case .waiting(let error): onState(.failed(error.localizedDescription))
                case .cancelled: onState(.stopped)
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            onState(.starting)
            listener.start(queue: queue)
            self.listener = listener
        }
    }

    public func stop() {
        queue.async { [self] in stopLocked() }
    }

    private func stopLocked() {
        listener?.cancel()
        listener = nil
        connections.values.forEach { $0.cancel() }
        connections.removeAll()
    }

    private func accept(_ connection: NWConnection) {
        guard connections.count < Self.maxConnections else { connection.cancel(); return }
        let key = ObjectIdentifier(connection)
        connections[key] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.queue.async { self?.connections[key] = nil }
            default: break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + Self.requestTimeout) { [weak connection] in connection?.cancel() }
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            do {
                if let request = try MiniHTTP.parseRequest(buffer) {
                    handler(request) { response in self.send(response, on: connection) }
                } else if isComplete || error != nil {
                    connection.cancel()
                } else {
                    receive(on: connection, buffer: buffer)
                }
            } catch MiniHTTP.ParseError.tooLarge {
                send(.error(413, "too large"), on: connection)
            } catch {
                send(.error(400, "bad request"), on: connection)
            }
        }
    }

    private func send(_ response: MiniHTTP.Response, on connection: NWConnection) {
        connection.send(content: response.serialized(), contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

/// One HTTP request over Network.framework, to a host and port or straight to a Bonjour service.
public enum MiniHTTPClient {
    public enum Failure: LocalizedError, Equatable {
        case unreachable(String)
        case timedOut
        case badResponse

        public var errorDescription: String? {
            switch self {
            case .unreachable(let reason): reason
            case .timedOut: String(localized: "No answer")
            case .badResponse: String(localized: "Unexpected answer")
            }
        }
    }

    public static func send(_ request: MiniHTTP.Request, to endpoint: NWEndpoint, host: String, timeout: TimeInterval = 8) async throws -> MiniHTTP.Response {
        let connection = NWConnection(to: endpoint, using: .tcp)
        let queue = DispatchQueue(label: "at.hifiteam.activityplus.http-client")
        let once = Once<Result<MiniHTTP.Response, Error>>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<MiniHTTP.Response, Error>) in
                once.setHandler { result in
                    connection.cancel()
                    continuation.resume(with: result)
                }
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        connection.send(content: request.serialized(host: host), completion: .contentProcessed { error in
                            if let error { once.fire(.failure(Failure.unreachable(error.localizedDescription))) }
                        })
                        receive(connection, buffer: Data(), once: once)
                    case .waiting(let error), .failed(let error):
                        once.fire(.failure(Failure.unreachable(error.localizedDescription)))
                    case .cancelled:
                        once.fire(.failure(CancellationError()))
                    default:
                        break
                    }
                }
                connection.start(queue: queue)
                queue.asyncAfter(deadline: .now() + timeout) { once.fire(.failure(Failure.timedOut)) }
            }
        } onCancel: {
            once.fire(.failure(CancellationError()))
        }
    }

    private static func receive(_ connection: NWConnection, buffer: Data, once: Once<Result<MiniHTTP.Response, Error>>) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            if buffer.count > MiniHTTP.maxResponseSize {
                once.fire(.failure(MiniHTTP.ParseError.tooLarge))
            } else if isComplete || error != nil {
                // Connection: close — the server is done once it closes.
                if let response = try? MiniHTTP.parseResponse(buffer) {
                    once.fire(.success(response))
                } else {
                    once.fire(.failure(error.map { Failure.unreachable($0.localizedDescription) } ?? Failure.badResponse))
                }
            } else {
                receive(connection, buffer: buffer, once: once)
            }
        }
    }
}

/// Delivers the first result only (ready, failure, timeout and cancellation race each other).
final class Once<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: ((Value) -> Void)?
    private var pending: Value?
    private var fired = false

    func setHandler(_ handler: @escaping (Value) -> Void) {
        lock.lock()
        if let pending {
            self.pending = nil
            lock.unlock()
            handler(pending)
            return
        }
        self.handler = fired ? nil : handler
        lock.unlock()
    }

    func fire(_ value: Value) {
        lock.lock()
        guard !fired else { lock.unlock(); return }
        fired = true
        let handler = self.handler
        self.handler = nil
        if handler == nil { pending = value }
        lock.unlock()
        handler?(value)
    }
}
