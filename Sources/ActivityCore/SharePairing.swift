import CryptoKit
import Foundation

/// A Mac that paired with this one and may read its summary. Only a hash of its token is kept here,
/// so the stored list is useless to anyone who copies it.
public struct PairedViewer: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var name: String
    public var pairedAt: Date
    public var lastSeen: Date?
    public var tokenHash: String

    public init(id: UUID = UUID(), name: String, pairedAt: Date = Date(), lastSeen: Date? = nil, tokenHash: String) {
        self.id = id
        self.name = name
        self.pairedAt = pairedAt
        self.lastSeen = lastSeen
        self.tokenHash = tokenHash
    }
}

public enum ShareToken {
    /// 32 random bytes, base64url without padding (43 characters).
    public static func generate() -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Compares without stopping at the first difference, so timing says nothing about how close a guess was.
    public static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var difference: UInt8 = 0
        for i in 0..<x.count { difference |= x[i] ^ y[i] }
        return difference == 0
    }

    /// The viewer the token belongs to, if any.
    public static func viewer(for token: String?, in viewers: [PairedViewer]) -> PairedViewer? {
        guard let token, !token.isEmpty else { return nil }
        let hashed = hash(token)
        var match: PairedViewer?
        for viewer in viewers where constantTimeEqual(viewer.tokenHash, hashed) { match = viewer }
        return match
    }
}

/// The 6-digit code shown on the shared Mac while it waits for another Mac to pair.
/// It expires after a few minutes and after a few wrong guesses, so it cannot be tried through.
public struct PairingCode: Sendable, Equatable {
    public static let lifetime: TimeInterval = 300
    public static let maxAttempts = 5

    public let code: String
    public let created: Date
    public private(set) var failedAttempts = 0
    public private(set) var used = false

    public init(code: String, created: Date = Date()) {
        self.code = code
        self.created = created
    }

    public static func random(now: Date = Date()) -> PairingCode {
        var generator = SystemRandomNumberGenerator()
        return PairingCode(code: String(format: "%06d", Int.random(in: 0...999_999, using: &generator)), created: now)
    }

    public func expires(at now: Date = Date()) -> Bool {
        now.timeIntervalSince(created) >= Self.lifetime
    }

    public func isActive(now: Date = Date()) -> Bool {
        !used && failedAttempts < Self.maxAttempts && !expires(at: now)
    }

    public enum Check: Equatable {
        case accepted
        case wrong(remaining: Int)
        case closed
    }

    /// Checks a guess. A correct one uses the code up; a wrong one counts against it.
    public mutating func check(_ guess: String, now: Date = Date()) -> Check {
        guard isActive(now: now) else { return .closed }
        let digits = guess.filter(\.isNumber)
        if digits.count == code.count, ShareToken.constantTimeEqual(digits, code) {
            used = true
            return .accepted
        }
        failedAttempts += 1
        return failedAttempts >= Self.maxAttempts ? .closed : .wrong(remaining: Self.maxAttempts - failedAttempts)
    }
}

/// The HTTP side of "Let other Macs see this Mac", without any networking, so it can be tested directly.
///
/// - `GET /v1/info` – who this is (name, app version); no token needed, Bonjour says as much anyway.
/// - `POST /v1/pair` `{"code": "123456", "name": "Viewer"}` – trades the code shown on this Mac for a token.
/// - `GET /v1/summary` with `Authorization: Bearer <token>` – the `RemoteSummary`.
///
/// Nothing can be changed through it: there are no commands, only these three reads and the pairing.
public struct ShareResponder {
    public struct Info: Codable, Sendable, Equatable {
        public var app: String
        public var schema: Int
        public var name: String
        public var appVersion: String
        public var pairing: Bool
        public init(app: String = "Activity+", schema: Int = RemoteSummary.schema, name: String, appVersion: String, pairing: Bool) {
            self.app = app
            self.schema = schema
            self.name = name
            self.appVersion = appVersion
            self.pairing = pairing
        }
    }

    public struct PairRequest: Codable, Sendable, Equatable {
        public var code: String
        public var name: String
        public init(code: String, name: String) { self.code = code; self.name = name }
    }

    public struct PairResponse: Codable, Sendable, Equatable {
        public var token: String
        public var name: String
        public init(token: String, name: String) { self.token = token; self.name = name }
    }

    public var name: String
    public var appVersion: String
    public var viewers: [PairedViewer]
    public var pairing: PairingCode?
    /// Makes the token; replaced in tests.
    public var makeToken: () -> String = ShareToken.generate

    public init(name: String, appVersion: String, viewers: [PairedViewer] = [], pairing: PairingCode? = nil) {
        self.name = name
        self.appVersion = appVersion
        self.viewers = viewers
        self.pairing = pairing
    }

    public enum Event: Equatable {
        case none
        /// A Mac paired; store the new list.
        case paired(PairedViewer)
        /// A paired Mac read the summary.
        case seen(UUID)
        /// A wrong code was entered.
        case wrongCode
    }

    /// Answers one request. `summary` is only called for an authorized summary request.
    public mutating func respond(to request: MiniHTTP.Request, now: Date = Date(), summary: () -> Data?) -> (MiniHTTP.Response, Event) {
        let path = request.path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? request.path
        switch (request.method, path) {
        case ("GET", "/v1/info"):
            let info = Info(name: name, appVersion: appVersion, pairing: pairing?.isActive(now: now) == true)
            return (.json(200, Self.encode(info)), .none)
        case ("POST", "/v1/pair"):
            return pair(request, now: now)
        case ("GET", "/v1/summary"):
            guard let viewer = ShareToken.viewer(for: request.bearerToken, in: viewers) else {
                return (.error(401, "not paired"), .none)
            }
            guard let body = summary() else { return (.error(503, "no data yet"), .seen(viewer.id)) }
            return (.json(200, body), .seen(viewer.id))
        case (_, "/v1/info"), (_, "/v1/pair"), (_, "/v1/summary"):
            return (.error(405, "method not allowed"), .none)
        default:
            return (.error(404, "not found"), .none)
        }
    }

    private mutating func pair(_ request: MiniHTTP.Request, now: Date) -> (MiniHTTP.Response, Event) {
        guard var code = pairing, code.isActive(now: now) else {
            return (.error(403, "pairing is not open on this Mac"), .none)
        }
        guard let body = try? JSONDecoder().decode(PairRequest.self, from: request.body) else {
            return (.error(400, "bad request"), .none)
        }
        let result = code.check(body.code, now: now)
        pairing = code
        switch result {
        case .accepted:
            let token = makeToken()
            let viewerName = String(body.name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(64))
            let viewer = PairedViewer(name: viewerName.isEmpty ? "Mac" : viewerName, pairedAt: now, tokenHash: ShareToken.hash(token))
            viewers.append(viewer)
            return (.json(200, Self.encode(PairResponse(token: token, name: name))), .paired(viewer))
        case .wrong:
            return (.error(403, "wrong code"), .wrongCode)
        case .closed:
            return (.error(403, "pairing is not open on this Mac"), .wrongCode)
        }
    }

    static func encode<T: Encodable>(_ value: T) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(value)) ?? Data()
    }
}
