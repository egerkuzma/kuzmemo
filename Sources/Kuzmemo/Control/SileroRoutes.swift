import Foundation
import KuzmemoCore

/// Control-channel access to the neural voice. Making a phrase is silent (nothing is played), so it is fine in the
/// automation build, which must never make a sound.
enum SileroRoutes {
    /// Where Python and the model were found (or what is missing) and what the voice did last.
    static func state(_ env: AppEnvironment) -> HTTPResponse {
        let speech = env.voice.speech
        let silero = speech.silero
        silero.refresh()
        var body: [String: Any] = [
            "engine": speech.engine.rawValue, "speaker": silero.speaker, "loading": silero.isLoading, "speakers": silero.speakers,
            "lastError": silero.lastError ?? NSNull(), "fallback": speech.lastFallback ?? NSNull(),
            "lastEngine": speech.lastEngine?.rawValue ?? NSNull(),
        ]
        switch silero.status {
        case .unknown: body["status"] = "unknown"
        case let .ready(found): body["status"] = "ready"; body["python"] = found.python.path; body["model"] = found.model.path; body["source"] = found.source
        case let .unavailable(problem): body["status"] = "unavailable"; body["problem"] = problem.message
        case .missingHelper: body["status"] = "missingHelper"
        }
        return .json(body)
    }

    /// `{"text": "…"}`: makes the phrase with the current speaker and speed and reports how long it took.
    static func say(_ request: HTTPRequest, _ env: AppEnvironment) async -> HTTPResponse {
        guard let text = request.jsonBody?["text"] as? String, !text.isEmpty else { return .error("body must be {\"text\": \"...\"}", status: 400) }
        let started = Date()
        do {
            let (phrase, spoken) = try await env.voice.speech.silero.synthesizeOnly(text)
            defer { try? FileManager.default.removeItem(at: phrase.url) }
            return .json([
                "ok": true, "spoken": spoken, "seconds": phrase.seconds, "synthesisMs": phrase.milliseconds,
                "totalMs": Int(Date().timeIntervalSince(started) * 1000),
            ])
        } catch {
            return .error("\(error.localizedDescription)", status: 502)
        }
    }
}
