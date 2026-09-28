import Foundation

nonisolated struct HTTPRequest: Sendable {
    var method: String
    var path: String
    var query: [String: String]
    var headers: [String: String]
    var body: Data

    var jsonBody: [String: Any]? {
        (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
    }
}

nonisolated struct HTTPResponse: Sendable {
    var status: Int
    var contentType: String
    var body: Data

    static func json(_ object: Any, status: Int = 200) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        return HTTPResponse(status: status, contentType: "application/json; charset=utf-8", body: data)
    }

    static func text(_ text: String, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, contentType: "text/plain; charset=utf-8", body: Data(text.utf8))
    }

    static func png(_ data: Data) -> HTTPResponse {
        HTTPResponse(status: 200, contentType: "image/png", body: data)
    }

    static func error(_ message: String, status: Int) -> HTTPResponse {
        .json(["error": message], status: status)
    }

    func serialized() -> Data {
        let reason = [200: "OK", 400: "Bad Request", 404: "Not Found", 405: "Method Not Allowed", 409: "Conflict", 500: "Internal Server Error"][status] ?? "OK"
        var head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        head.reserveCapacity(head.count)
        return Data(head.utf8) + body
    }
}

/// A minimal HTTP/1.1 request parser: request line, headers, and a `Content-Length` body.
nonisolated enum HTTPParser {
    enum Result {
        case complete(HTTPRequest)
        case needMore
        case invalid
    }

    static func parse(_ data: Data) -> Result {
        let separator = Data("\r\n\r\n".utf8)
        guard let headEnd = data.range(of: separator) else { return data.count > 64 * 1024 ? .invalid : .needMore }
        guard let head = String(data: data[..<headEnd.lowerBound], encoding: .utf8) else { return .invalid }
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return .invalid }

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = headEnd.upperBound
        guard data.count - bodyStart >= length else { return .needMore }
        let body = data[bodyStart ..< bodyStart + length]

        let target = String(requestLine[1])
        let parts = target.split(separator: "?", maxSplits: 1).map(String.init)
        var query: [String: String] = [:]
        if parts.count == 2 {
            for pair in parts[1].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
                query[kv[0].removingPercentEncoding ?? kv[0]] = kv.count > 1 ? (kv[1].removingPercentEncoding ?? kv[1]) : ""
            }
        }
        return .complete(HTTPRequest(
            method: String(requestLine[0]).uppercased(), path: parts[0], query: query, headers: headers, body: Data(body)
        ))
    }
}
