import Foundation
import KuzmemoCore
import KuzmemoSTT

/// Control-channel access to the "My voice" engine. Making a phrase is silent (nothing is played; an `offline` player
/// renders into memory), so it is fine in the automation build, which must never make a sound.
enum CloneRoutes {
    static func state(_ env: AppEnvironment) -> HTTPResponse {
        let speech = env.voice.speech
        let clone = speech.clone
        clone.refresh()
        var body: [String: Any] = [
            "engine": speech.engine.rawValue, "status": statusName(clone.status), "steps": clone.steps,
            "voiceFolder": clone.locator.voiceDirectory.path, "engineFolder": clone.locator.directory.path,
            "lastError": clone.lastError ?? NSNull(), "fallback": speech.lastFallback ?? NSNull(),
            "lastEngine": speech.lastEngine?.rawValue ?? NSNull(), "speaking": clone.isSpeaking,
        ]
        if let sample = clone.sample { body["sample"] = ["seconds": sample.seconds, "saved": ISO8601DateFormatter().string(from: sample.saved)] }
        switch clone.enrollment.state {
        case .idle: body["enrollment"] = "idle"
        case let .working(message): body["enrollment"] = "working"; body["enrollmentStep"] = message
        case let .review(draft): body["enrollment"] = "review"; body["draft"] = ["seconds": draft.seconds, "words": draft.words, "suggested": draft.suggested]
        }
        body["enrollmentProblem"] = clone.enrollment.problem ?? NSNull()
        if let report = clone.lastReport { body["lastReport"] = describe(report) }
        return .json(body)
    }

    /// `{"text": "…", "cache": false, "play": "none"|"offline", "save": "/folder"}`: makes the answer as the app would and
    /// reports how long each sentence took. `cache` lets sentences made before come from the cache (off by default so that
    /// the numbers are the engine's). `play: offline` also queues the sentences on a player that renders into memory.
    /// `save` keeps every sentence as a WAV file in that folder.
    static func say(_ request: HTTPRequest, _ env: AppEnvironment) async -> HTTPResponse {
        guard let json = request.jsonBody, let text = json["text"] as? String, !text.isEmpty else { return .error("body must be {\"text\": \"...\"}", status: 400) }
        let clone = env.voice.speech.clone
        let stepsBefore = clone.steps
        defer { clone.steps = stepsBefore } // a step count given for one check does not stay
        if let steps = json["steps"] as? Int { clone.steps = min(max(steps, SpeechSettings.cloneStepsRange.lowerBound), SpeechSettings.cloneStepsRange.upperBound) }
        let folder = (json["save"] as? String).map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let folder { try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let player = (json["play"] as? String) == "offline" ? SegmentPlayer(offline: true) : nil
        let started = Date()
        do {
            let (lines, report) = try await clone.synthesizeOnly(text, useCache: (json["cache"] as? Bool) ?? false, player: player) { index, segment in
                if let folder { try? segment.wav.write(to: folder.appendingPathComponent(String(format: "line-%02d.wav", index + 1))) }
            }
            var body = describe(report)
            body["ok"] = true
            body["lines"] = lines
            body["totalMs"] = Int(Date().timeIntervalSince(started) * 1000)
            if let player { body["rendered"] = player.renderedSeconds }
            return .json(body)
        } catch {
            return .error(OmniVoiceSpeechOutput.message(for: error), status: 502)
        }
    }

    /// `{"path": "/recording.wav", "words": "what is said in it"}`: makes the file into the voice of this bundle, the way
    /// the settings page does after the person has checked the words. Without `words` the recognizer is asked (that loads
    /// the speech model, which is slow the first time).
    static func enroll(_ request: HTTPRequest, _ env: AppEnvironment) async -> HTTPResponse {
        guard let json = request.jsonBody, let path = json["path"] as? String else { return .error("body must be {\"path\": \"...\", \"words\": \"...\"}", status: 400) }
        let clone = env.voice.speech.clone
        var words = json["words"] as? String
        if words == nil {
            guard let samples = try? AudioFileLoader.load(URL(fileURLWithPath: path)),
                  case let .success(.speech(output)) = await env.voice.recognizeForTest(samples) else {
                return .error("the words could not be recognized; pass them as \"words\"", status: 422)
            }
            words = SpeechText.forNeuralVoice(output.text)
        }
        do {
            try await clone.enrollment.enroll(URL(fileURLWithPath: path), words: words ?? "")
            return state(env)
        } catch {
            return .error(OmniVoiceSpeechOutput.message(for: error), status: 422)
        }
    }

    /// `{"path": "/recording.wav", "recognize": false}`: the first step of the settings page ("Choose a recording…"): the
    /// file is prepared and the state goes to review, waiting for `/speech/clone/save`. With `recognize` the speech model
    /// suggests the words (slow the first time).
    static func choose(_ request: HTTPRequest, _ env: AppEnvironment) async -> HTTPResponse {
        guard let json = request.jsonBody, let path = json["path"] as? String else { return .error("body must be {\"path\": \"...\"}", status: 400) }
        let recognize = (json["recognize"] as? Bool) ?? false
        await env.voice.speech.clone.enrollment.choose(URL(fileURLWithPath: path)) { samples in
            guard recognize, case let .success(.speech(output)) = await env.voice.recognizeForTest(samples) else { return nil }
            return output.text
        }
        return state(env)
    }

    /// `{"words": "…"}`: the second step: the person's version of the words, then the voice is made.
    static func save(_ request: HTTPRequest, _ env: AppEnvironment) async -> HTTPResponse {
        guard let words = request.jsonBody?["words"] as? String else { return .error("body must be {\"words\": \"...\"}", status: 400) }
        await env.voice.speech.clone.enrollment.save(words: words)
        return state(env)
    }

    /// Gives up the recording that is being reviewed.
    static func cancel(_ env: AppEnvironment) -> HTTPResponse {
        env.voice.speech.clone.enrollment.cancel()
        return state(env)
    }

    /// Forgets the voice of this bundle.
    static func forget(_ env: AppEnvironment) -> HTTPResponse {
        let clone = env.voice.speech.clone
        do { try OmniVoiceEnrollment(locator: clone.locator).remove() } catch { return .error("\(error)", status: 500) }
        clone.voiceChanged()
        return state(env)
    }

    private static func statusName(_ status: OmniVoiceLocator.Status) -> String {
        switch status {
        case .notInstalled: "notInstalled"
        case .noVoice: "noVoice"
        case .ready: "ready"
        }
    }

    private static func describe(_ report: OmniVoiceSpeechOutput.Report) -> [String: Any] {
        [
            "lineCount": report.lines, "cachedLines": report.cachedLines, "firstSoundSeconds": report.firstSoundSeconds ?? NSNull(),
            "madeInSeconds": report.madeInSeconds, "audioSeconds": report.audioSeconds, "silenceSeconds": report.silenceSeconds ?? NSNull(),
            "steps": report.steps, "startedAhead": report.startedAhead, "readyAt": report.readyAt, "lengths": report.lengths,
        ]
    }
}
