import Foundation

/// Just enough HTTP/1.1 for sharing between Macs and reading node_exporter: one request per connection,
/// no keep-alive. Network.framework carries the bytes, so plain-HTTP rules for URLSession (ATS) do not apply.
public enum MiniHTTP {
    /// Requests larger than this are refused: nothing the share server accepts comes close.
    public static let maxRequestSize = 16 * 1024
    /// node_exporter pages are typically 50–200 kB; anything far beyond is not a metrics page.
    public static let maxResponseSize = 8 * 1024 * 1024

    public struct Request: Sendable, Equatable {
        public var method: String
        public var path: String
        /// Header names lowercased.
        public var headers: [String: String]
        public var body: Data

        public init(method: String, path: String, headers: [String: String] = [:], body: Data = Data()) {
            self.method = method
            self.path = path
            self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { $1 })
            self.body = body
        }

        /// The token from `Authorization: Bearer <token>`.
        public var bearerToken: String? {
            guard let value = headers["authorization"] else { return nil }
            let parts = value.split(separator: " ", maxSplits: 1)
            guard parts.count == 2, parts[0].lowercased() == "bearer" else { return nil }
            let token = parts[1].trimmingCharacters(in: .whitespaces)
            return token.isEmpty ? nil : token
        }

        public func serialized(host: String) -> Data {
            var head = "\(method) \(path) HTTP/1.1\r\nHost: \(host)\r\nConnection: close\r\nUser-Agent: Activity+\r\n"
            for (name, value) in headers.sorted(by: { $0.key < $1.key }) where name != "host" && name != "connection" {
                head += "\(name): \(value)\r\n"
            }
            if !body.isEmpty || method == "POST" { head += "content-length: \(body.count)\r\n" }
            head += "\r\n"
            return Data(head.utf8) + body
        }
    }

    public struct Response: Sendable, Equatable {
        public var status: Int
        public var headers: [String: String]
        public var body: Data

        public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
            self.status = status
            self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { $1 })
            self.body = body
        }

        public static func json(_ status: Int, _ body: Data) -> Response {
            Response(status: status, headers: ["content-type": "application/json; charset=utf-8"], body: body)
        }

        public static func error(_ status: Int, _ message: String) -> Response {
            let body = (try? JSONSerialization.data(withJSONObject: ["error": message], options: [.sortedKeys])) ?? Data()
            return json(status, body)
        }

        public func serialized() -> Data {
            var head = "HTTP/1.1 \(status) \(MiniHTTP.reason(status))\r\n"
            var all = headers
            all["content-length"] = String(body.count)
            all["connection"] = "close"
            all["cache-control"] = "no-store"
            for (name, value) in all.sorted(by: { $0.key < $1.key }) { head += "\(name): \(value)\r\n" }
            head += "\r\n"
            return Data(head.utf8) + body
        }
    }

    public enum ParseError: Error, Equatable {
        case malformed
        case tooLarge
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 413: "Payload Too Large"
        case 429: "Too Many Requests"
        case 500: "Internal Server Error"
        case 503: "Service Unavailable"
        default: "Status"
        }
    }

    private static let headerEnd = Data("\r\n\r\n".utf8)

    /// Splits the head (status/request line and headers) from the rest; nil while the head is incomplete.
    private static func splitHead(_ data: Data) -> (lines: [String], rest: Data)? {
        guard let range = data.range(of: headerEnd) else { return nil }
        guard let head = String(data: data[data.startIndex..<range.lowerBound], encoding: .utf8) else { return ([], Data()) }
        return (head.components(separatedBy: "\r\n"), Data(data[range.upperBound...]))
    }

    private static func parseHeaders(_ lines: ArraySlice<String>) -> [String: String]? {
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { return nil }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return nil }
            headers[name] = value
        }
        return headers
    }

    /// A complete request from the bytes received so far; nil means "wait for more".
    public static func parseRequest(_ data: Data) throws -> Request? {
        guard data.count <= maxRequestSize else { throw ParseError.tooLarge }
        guard let (lines, rest) = splitHead(data) else { return nil }
        guard let requestLine = lines.first else { throw ParseError.malformed }
        let parts = requestLine.split(separator: " ")
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1."), let headers = parseHeaders(lines.dropFirst()) else { throw ParseError.malformed }
        let length = Int(headers["content-length"] ?? "0") ?? -1
        guard length >= 0 else { throw ParseError.malformed }
        guard length <= maxRequestSize else { throw ParseError.tooLarge }
        guard rest.count >= length else { return nil }
        return Request(method: String(parts[0]), path: String(parts[1]), headers: headers, body: Data(rest.prefix(length)))
    }

    /// The response from all bytes the server sent before closing the connection.
    public static func parseResponse(_ data: Data) throws -> Response {
        guard let (lines, rest) = splitHead(data), let statusLine = lines.first else { throw ParseError.malformed }
        let parts = statusLine.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2, parts[0].hasPrefix("HTTP/1."), let status = Int(parts[1]),
              let headers = parseHeaders(lines.dropFirst()) else { throw ParseError.malformed }
        var body = rest
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            body = try dechunk(rest)
        } else if let length = headers["content-length"].flatMap({ Int($0) }) {
            guard rest.count >= length else { throw ParseError.malformed }
            body = Data(rest.prefix(length))
        }
        return Response(status: status, headers: headers, body: body)
    }

    /// Decodes `Transfer-Encoding: chunked` (Go's net/http, which node_exporter uses, sends larger pages that way).
    static func dechunk(_ data: Data) throws -> Data {
        var output = Data()
        var index = data.startIndex
        let crlf = Data("\r\n".utf8)
        while true {
            guard let lineEnd = data.range(of: crlf, in: index..<data.endIndex) else { throw ParseError.malformed }
            guard let sizeLine = String(data: data[index..<lineEnd.lowerBound], encoding: .ascii) else { throw ParseError.malformed }
            let sizeText = sizeLine.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            guard let size = Int(sizeText, radix: 16), size >= 0 else { throw ParseError.malformed }
            index = lineEnd.upperBound
            if size == 0 { return output }
            guard data.distance(from: index, to: data.endIndex) >= size else { throw ParseError.malformed }
            let end = data.index(index, offsetBy: size)
            output.append(data[index..<end])
            guard output.count <= maxResponseSize else { throw ParseError.tooLarge }
            index = end
            // Each chunk ends with CRLF.
            if data.distance(from: index, to: data.endIndex) >= 2 { index = data.index(index, offsetBy: 2) }
        }
    }
}
