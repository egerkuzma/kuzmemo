import Foundation
import Testing
@testable import KuzmemoCore

/// The control channel reads what any process of the same user can send. Whatever arrives, the parser answers (a request, "more",
/// "bad" or "too large") and never traps: a trap here ends the app.
@Suite("The control channel's HTTP parser")
struct HTTPParserTests {
    private func parse(_ text: String) -> HTTPParser.Result { HTTPParser.parse(Data(text.utf8)) }

    @Test func aPlainRequestIsRead() {
        guard case let .complete(request) = parse("GET /state?date=2026-09-28&q=%D0%B4%D0%B0 HTTP/1.1\r\nHost: x\r\n\r\n") else { Issue.record("expected a request"); return }
        #expect(request.method == "GET" && request.path == "/state")
        #expect(request.query == ["date": "2026-09-28", "q": "да"])
        #expect(request.headers["host"] == "x")
    }

    @Test func aBodyIsReadByItsLength() {
        guard case let .complete(request) = parse("POST /answer HTTP/1.1\r\nContent-Length: 15\r\n\r\n{\"text\":\"да\"} ignored") else { Issue.record("expected a request"); return }
        #expect(request.method == "POST" && String(decoding: request.body, as: UTF8.self) == "{\"text\":\"да\"}") // 15 bytes: "да" is four of them
        // fewer bytes than promised: wait for more
        if case .needMore = parse("POST /x HTTP/1.1\r\nContent-Length: 50\r\n\r\nshort") {} else { Issue.record("expected needMore") }
        if case .needMore = parse("GET /x HTTP/1.1\r\nHost: x") {} else { Issue.record("an unfinished head waits") }
    }

    /// "Content-Length: -1" made the body range run backwards, which traps.
    @Test func aLengthThatIsNegativeOrNotANumberIsABadRequest() {
        for length in ["-1", "-9223372036854775808", "abc", "1e3", " ", "99999999999999999999999"] {
            if case .invalid = parse("POST /x HTTP/1.1\r\nContent-Length: \(length)\r\n\r\nabc") {} else { Issue.record("length '\(length)' was not refused") }
        }
    }

    @Test func aBodyBeyondTheLimitIsTooLarge() {
        if case .tooLarge = parse("POST /x HTTP/1.1\r\nContent-Length: \(HTTPParser.maxBody + 1)\r\n\r\n") {} else { Issue.record("expected tooLarge") }
        if case .needMore = parse("POST /x HTTP/1.1\r\nContent-Length: \(HTTPParser.maxBody)\r\n\r\n") {} else { Issue.record("a body at the limit is allowed") }
    }

    /// "GET /state?=" split into no pieces and the key was read from nothing.
    @Test func queriesWithoutKeysAreSkippedNotTrapped() {
        for target in ["/state?=", "/state?&&", "/state?=x", "/state?&=&", "/state?", "/state?a", "/state??b=c"] {
            guard case let .complete(request) = parse("GET \(target) HTTP/1.1\r\n\r\n") else { Issue.record("'\(target)' was not read"); continue }
            #expect(request.path == "/state", "target \(target)")
        }
        guard case let .complete(odd) = parse("GET /state?a&b=&=c&d=1 HTTP/1.1\r\n\r\n") else { Issue.record("expected a request"); return }
        #expect(odd.query == ["a": "", "b": "", "d": "1"])
    }

    @Test func junkIsNotACrash() {
        for text in ["", "\r\n\r\n", "GET\r\n\r\n", " \r\n\r\n", "\u{0}\u{0}\r\n\r\n", "GET / HTTP/1.1\r\n:\r\n\r\n", "GET / HTTP/1.1\r\nContent-Length:\r\n\r\n"] {
            _ = parse(text)
        }
        var bytes = Data(repeating: 0x41, count: HTTPParser.maxHead + 10)
        if case .invalid = HTTPParser.parse(bytes) {} else { Issue.record("a head that never ends is refused") }
        bytes = Data([0xFF, 0xFE, 0xFD]) + Data("\r\n\r\n".utf8)
        if case .invalid = HTTPParser.parse(bytes) {} else { Issue.record("a head that is not text is refused") }
    }

    @Test func responsesAreSerialisedWithTheirLength() {
        let text = String(decoding: HTTPResponse.json(["ok": true]).serialized(), as: UTF8.self)
        #expect(text.hasPrefix("HTTP/1.1 200 OK\r\n") && text.contains("Content-Length: 11\r\n") && text.hasSuffix("{\"ok\":true}"))
        #expect(String(decoding: HTTPResponse.error("big", status: 413).serialized(), as: UTF8.self).hasPrefix("HTTP/1.1 413 Payload Too Large"))
    }
}
