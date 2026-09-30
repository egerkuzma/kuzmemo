import AVFoundation
import Foundation
import KuzmemoCore
import KuzmemoSTT

/// Control-channel routes for the voice path. They go through the same `VoiceController` the trigger key
/// uses, so a check here exercises the real code; only the microphone is replaced by a file.
enum VoiceRoutes {
    static func state(_ env: AppEnvironment) -> HTTPResponse {
        let voice = env.voice!
        var body: [String: Any] = [
            "phase": "\(voice.phase)", "policy": voice.policyDescription, "model": "\(voice.modelState)",
            "problem": voice.problem.map { "\($0)" } ?? NSNull(), "triggerRunning": voice.triggerRunning,
            "chord": voice.chordDescription ?? NSNull(),
            "pendingJobs": voice.pendingJobs, "lastTranscript": voice.lastTranscript ?? NSNull(),
            "hud": ["state": "\(voice.hud.model.state)", "level": voice.hud.model.level, "elapsed": voice.hud.model.elapsed],
            "speech": ["muted": voice.speech.muted, "speaking": voice.speech.isSpeaking, "engine": voice.speech.engine.rawValue],
            "output": ["silenced": voice.output.isSilencing, "events": voice.simulatedOutput.events],
            "permissions": [
                "microphone": "\(voice.permissions.microphone)", "inputMonitoring": voice.permissions.inputMonitoring,
            ],
        ]
        body["status"] = "\(env.status)"
        if let question = env.pendingQuestion {
            body["question"] = [
                "memoID": question.memoID, "text": question.question, "options": question.options, "round": question.round,
            ] as [String: Any]
        }
        return .json(body)
    }

    static func hotkey(_ path: String, _ env: AppEnvironment) -> HTTPResponse {
        let voice = env.voice!
        switch path {
        case "/hotkey/down": voice.triggerDown()
        case "/hotkey/up": voice.triggerUp()
        case "/hotkey/other": voice.otherKeyPressed()
        case "/hotkey/escape": voice.escapePressed()
        default: return .error("unknown hotkey event", status: 404)
        }
        return state(env)
    }

    /// The next recording plays this file instead of listening to the microphone.
    static func armInput(_ request: HTTPRequest, _ env: AppEnvironment) -> HTTPResponse {
        guard let path = request.jsonBody?["path"] as? String else { return .error("body must be {\"path\": \"file.wav\"}", status: 400) }
        do {
            let samples = try AudioFileLoader.load(URL(fileURLWithPath: path))
            env.voice.armScriptedInput(samples: samples)
            return .json(["armed": path, "seconds": Double(samples.count) / 16_000])
        } catch {
            return .error("\(error)", status: 400)
        }
    }

    /// Pushes a recording straight into the pipeline and answers when it has been fully processed.
    static func inject(_ request: HTTPRequest, _ env: AppEnvironment) async -> HTTPResponse {
        guard let path = request.jsonBody?["path"] as? String else { return .error("body must be {\"path\": \"file.wav\"}", status: 400) }
        let samples: [Float]
        do { samples = try AudioFileLoader.load(URL(fileURLWithPath: path)) } catch { return .error("\(error)", status: 400) }
        let started = Date()
        let spokenBefore = env.voice.speech.spokenCount
        let result = await env.voice.inject(samples: samples)
        let spoken = Array(env.voice.speech.log.suffix(env.voice.speech.spokenCount - spokenBefore))

        var body: [String: Any] = [
            "memoID": result.memoID, "transcript": result.transcript ?? NSNull(), "audioSeconds": result.audioSeconds,
            "sttMs": result.sttMs ?? NSNull(), "answeredLocally": result.answeredLocally,
            "wallMs": Int(Date().timeIntervalSince(started) * 1000), "lines": env.toast?.lines ?? [],
            "spoken": spoken,
        ]
        switch result.kind {
        case let .noSpeech(reason):
            body["kind"] = "noSpeech"
            body["reason"] = reason
        case let .recognitionFailed(message, needsUser, retryAt):
            body["kind"] = "recognitionFailed"
            body["error"] = message
            body["needsUser"] = needsUser
            body["retryAt"] = retryAt.map { ISO8601DateFormatter().string(from: $0) } ?? NSNull()
        case let .processed(outcome):
            body["kind"] = "processed"
            body["outcome"] = ControlRoutes.outcomeBody(outcome, env: env, started: started)
        }
        return .json(body)
    }

    /// A typed answer to the pending question, or an option chosen with a tap (`option`).
    static func answer(_ request: HTTPRequest, _ env: AppEnvironment) async -> HTTPResponse {
        guard let json = request.jsonBody, let text = (json["text"] ?? json["option"]) as? String else {
            return .error("body must be {\"text\": \"...\"} or {\"option\": \"...\"}", status: 400)
        }
        let started = Date()
        let outcome: ProcessOutcome?
        if json["option"] != nil { outcome = await env.voice.choose(text) } else { outcome = await env.answer(text, inputKind: .text) }
        guard let outcome else { return .error("no question is waiting for an answer", status: 409) }
        var body = ControlRoutes.outcomeBody(outcome, env: env, started: started)
        body["pendingQuestion"] = env.pendingQuestion?.question ?? NSNull()
        return .json(body)
    }

    /// Closes the pending question the way a timeout does (`keep`: save the phrase as a note) or like Esc.
    static func closeQuestion(_ request: HTTPRequest, _ env: AppEnvironment) async -> HTTPResponse {
        let keep = (request.jsonBody?["keep"] as? Bool) ?? true
        guard env.pendingQuestion != nil else { return .error("no question is waiting for an answer", status: 409) }
        await env.closeQuestion(keep: keep)
        return .json(["closed": true, "kept": keep, "lines": env.toast?.lines ?? []])
    }

    static func speechLog(_ env: AppEnvironment) -> HTTPResponse {
        .json(["muted": env.voice.speech.muted, "speech": env.voice.speech.log, "cues": env.voice.cues.log])
    }

    static func mute(_ request: HTTPRequest, _ env: AppEnvironment) -> HTTPResponse {
        guard let muted = request.jsonBody?["muted"] as? Bool else { return .error("body must be {\"muted\": true|false}", status: 400) }
        env.voice.setMuted(muted)
        return .json(["muted": muted])
    }

    /// A HUD in a given state, for `/render?view=hud&state=…`. The sample texts follow the interface language.
    static func hudState(_ name: String) -> HUDModel? {
        let russian = Localization.current == .russian
        let phrase = russian ? "напомни мне послезавтра сказать Дмитрию про доступ в Notion" : "remind me the day after tomorrow to tell Dmitry about access to Notion"
        let question = russian ? "Какую пятницу ты имеешь в виду?" : "Which Friday do you mean?"
        let options = russian
            ? ["Ближайшая пятница, 2 октября", "Пятница следующей недели, 9 октября"]
            : ["This coming Friday, October 2", "Friday of next week, October 9"]
        let model = HUDModel()
        switch name {
        case "preparing": model.state = .preparingModel
        case "recording": model.state = .recording(handsFree: false); model.level = 0.09; model.elapsed = 7
        case "handsfree": model.state = .recording(handsFree: true); model.level = 0.05; model.elapsed = 12
        case "transcribing": model.state = .transcribing
        case "interpreting": model.state = .interpreting(phrase)
        case "result":
            let saved = russian
                ? "Напоминание «Сказать Дмитрию про доступ в Notion» — 30 сентября, весь день."
                : "Reminder “Tell Dmitry about access to Notion” — September 30, all day."
            model.state = .result(.init(style: .success, lines: [saved], undoOpID: "op"))
        case "question":
            model.state = .result(.init(style: .question, lines: [question], options: options))
        case "listening":
            model.state = .listening(.init(style: .question, lines: [question], options: options))
            model.level = 0.06
        case "note": model.state = .note(tr("No speech heard — nothing was saved."), .warning)
        default: return nil
        }
        return model
    }
}
