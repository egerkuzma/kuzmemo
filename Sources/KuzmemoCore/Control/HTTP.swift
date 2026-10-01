import Foundation

/// One request of the dev control channel (HTTP over a Unix socket). The parser lives here, not in the app, so that it can be
/// tested: it reads what any process of the same user can send, and a malformed request must not be able to stop the app.
public struct HTTPRequest: Sendable {
    public var method: String
    public var path: String
    public var query: [String: String]
    public var headers: [String: String]
    public var body: Data

    public init(method: String, path: String, query: [String: String] = [:], headers: [String: String] = [:], body: Data = Data()) {
        self.method = method
        self.path = path
        self.query = query
        self.headers = headers
        self.body = body
    }

    public var jsonBody: [String: Any]? {
        (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
    }
}

public struct HTTPResponse: Sendable {
    public var status: Int
    public var contentType: String
    public var body: Data

    public init(status: Int, contentType: String, body: Data) {
        self.status = status
        self.contentType = contentType
        self.body = body
    }

    public static func json(_ object: Any, status: Int = 200) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        return HTTPResponse(status: status, contentType: "application/json; charset=utf-8", body: data)
    }

    public static func text(_ text: String, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, contentType: "text/plain; charset=utf-8", body: Data(text.utf8))
    }

    public static func png(_ data: Data) -> HTTPResponse {
        HTTPResponse(status: 200, contentType: "image/png", body: data)
    }

    public static func error(_ message: String, status: Int) -> HTTPResponse {
        .json(["error": message], status: status)
    }

    public func serialized() -> Data {
        let reason = [200: "OK", 400: "Bad Request", 404: "Not Found", 405: "Method Not Allowed", 409: "Conflict", 413: "Payload Too Large", 500: "Internal Server Error"][status] ?? "OK"
        let head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        return Data(head.utf8) + body
    }
}

/// A minimal HTTP/1.1 request parser: request line, headers, and a `Content-Length` body. Limits are part of it: a head over
/// 64 KB or a body over 8 MB is refused, a length that is not a non-negative number is refused, and nothing a client sends
/// can make it trap.
public enum HTTPParser {
    public enum Result {
        case complete(HTTPRequest)
        case needMore
        case invalid
        case tooLarge
    }

    public static let maxHead = 64 * 1024
    public static let maxBody = 8 * 1024 * 1024

    public static func parse(_ data: Data) -> Result {
        let separator = Data("\r\n\r\n".utf8)
        guard let headEnd = data.range(of: separator) else { return data.count > maxHead ? .invalid : .needMore }
        guard headEnd.lowerBound - data.startIndex <= maxHead,
              let head = String(data: data[..<headEnd.lowerBound], encoding: .utf8) else { return .invalid }
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return .invalid }

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        // "-1" used to make the body range run backwards, which traps; a length nobody can read is a bad request
        guard let length = Int(headers["content-length"] ?? "0"), length >= 0 else { return .invalid }
        guard length <= maxBody else { return .tooLarge }
        let bodyStart = headEnd.upperBound
        guard data.count - (bodyStart - data.startIndex) >= length else { return .needMore }
        let body = data[bodyStart ..< bodyStart + length]

        let target = String(requestLine[1])
        let parts = target.split(separator: "?", maxSplits: 1).map(String.init)
        var query: [String: String] = [:]
        if parts.count == 2 {
            for pair in parts[1].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                guard let key = kv.first, !key.isEmpty else { continue } // "?=", "?=x" and "?&&" have no key: skip, never index into nothing
                query[key.removingPercentEncoding ?? key] = kv.count > 1 ? (kv[1].removingPercentEncoding ?? kv[1]) : ""
            }
        }
        return .complete(HTTPRequest(
            method: String(requestLine[0]).uppercased(), path: parts.first ?? "", query: query, headers: headers, body: Data(body)
        ))
    }
}
