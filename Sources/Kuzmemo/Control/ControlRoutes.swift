import AppKit
import Foundation
import KuzmemoCore

/// The dev control channel's routes. Everything here runs on the main actor and talks to the same
/// `AppEnvironment` the UI uses, so a check through the socket exercises the real code path.
enum ControlRoutes {
    static func handle(_ request: HTTPRequest) async -> HTTPResponse {
        let env = AppEnvironment.shared
        switch (request.method, request.path) {
        case ("GET", "/state"): return await state(request, env)
        case ("POST", "/memo/transcript"): return await submit(request, env)
        case ("GET", "/agenda"): return await agenda(request, env)
        case ("POST", "/undo"): return await undo(env)
        case ("POST", "/clock"): return clock(request, env)
        case ("POST", "/db/reset"): return await reset(env)
        case ("GET", "/render"): return render(request, env)
        case ("GET", "/voice"): return VoiceRoutes.state(env)
        case ("POST", "/hotkey/down"), ("POST", "/hotkey/up"), ("POST", "/hotkey/other"), ("POST", "/hotkey/escape"):
            return VoiceRoutes.hotkey(request.path, env)
        case ("POST", "/voice/input"): return VoiceRoutes.armInput(request, env)
        case ("POST", "/record/inject-audio"): return await VoiceRoutes.inject(request, env)
        case ("GET", "/speech/log"): return VoiceRoutes.speechLog(env)
        case ("POST", "/speech/mute"): return VoiceRoutes.mute(request, env)
        default: return .error("no route \(request.method) \(request.path)", status: 404)
        }
    }

    // MARK: State

    private static func state(_ request: HTTPRequest, _ env: AppEnvironment) async -> HTTPResponse {
        let now = env.clock.localNow()
        var body: [String: Any] = [
            "app": [
                "version": env.version, "bundle": Bundle.main.bundleIdentifier ?? "", "dev": env.paths.isDev,
                "pid": ProcessInfo.processInfo.processIdentifier,
            ],
            "clock": ["now": "\(now.date) \(now.time)", "pinned": env.clock.isPinned, "tz": env.clock.timeZone.identifier],
            "status": "\(env.status)",
            "database": env.paths.database.path,
        ]
        if let counts = try? await env.store.counts() {
            body["counts"] = [
                "items": counts.items, "memos": counts.memos, "ops": counts.ops, "unfinishedMemos": counts.unfinishedMemos,
            ]
        }
        if let toast = env.toast {
            body["toast"] = ["style": "\(toast.style)", "lines": toast.lines, "options": toast.options, "undoOpID": toast.undoOpID as Any]
        }
        if request.query["claude"] == "1" {
            let executable = try? await env.provider.resolvedExecutable().path
            var claude: [String: Any] = ["path": executable ?? NSNull()]
            switch await env.provider.authStatus() {
            case let .loggedIn(method): claude["auth"] = "loggedIn"; claude["method"] = method ?? NSNull()
            case .loggedOut: claude["auth"] = "loggedOut"
            case let .unknown(text): claude["auth"] = "unknown"; claude["detail"] = text
            }
            body["claude"] = claude
        }
        return .json(body)
    }

    // MARK: Commands

    private static func submit(_ request: HTTPRequest, _ env: AppEnvironment) async -> HTTPResponse {
        guard let json = request.jsonBody, let text = json["text"] as? String else {
            return .error("body must be {\"text\": \"...\"}", status: 400)
        }
        let kind: MemoInputKind = (json["inputKind"] as? String) == "voice" ? .voice : .text
        let started = Date()
        guard let outcome = await env.submit(text: text, inputKind: kind) else {
            return .error("empty text or the pipeline is busy", status: 409)
        }
        let body = outcomeBody(outcome, env: env, started: started)
        return .json(body)
    }

    private static func agenda(_ request: HTTPRequest, _ env: AppEnvironment) async -> HTTPResponse {
        let today = env.clock.localNow().date
        let from = request.query["from"].flatMap(LocalDate.init) ?? today
        let to = request.query["to"].flatMap(LocalDate.init) ?? from
        guard from <= to else { return .error("from must not be after to", status: 400) }
        do {
            let entries = try await env.store.agenda(in: from ... to)
            return .json(["from": "\(from)", "to": "\(to)", "entries": entries.map(describe(entry:))])
        } catch {
            return .error("\(error)", status: 500)
        }
    }

    private static func undo(_ env: AppEnvironment) async -> HTTPResponse {
        guard let op = try? await env.store.lastUndoableOp() else { return .error("nothing to undo", status: 404) }
        await env.undo(opID: op.id)
        return .json(["undone": op.id, "label": op.label, "lines": env.toast?.lines ?? []])
    }

    private static func clock(_ request: HTTPRequest, _ env: AppEnvironment) -> HTTPResponse {
        guard let json = request.jsonBody, json.keys.contains("local") else {
            return .error("body must be {\"local\": \"YYYY-MM-DD HH:MM\"} or {\"local\": null}", status: 400)
        }
        let local = json["local"] as? String
        guard env.clock.pin(local: local) else { return .error("bad local time", status: 400) }
        let now = env.clock.localNow()
        return .json(["now": "\(now.date) \(now.time)", "pinned": env.clock.isPinned])
    }

    private static func reset(_ env: AppEnvironment) async -> HTTPResponse {
        guard env.paths.isDev else { return .error("refusing to erase data outside the dev bundle", status: 409) }
        do {
            try await env.store.eraseAllData()
            await env.reloadToday()
            return .json(["erased": true])
        } catch {
            return .error("\(error)", status: 500)
        }
    }

    private static func render(_ request: HTTPRequest, _ env: AppEnvironment) -> HTTPResponse {
        let dark = request.query["scheme"] == "dark"
        let width = CGFloat(Double(request.query["width"] ?? "") ?? 380)
        let data: Data?
        switch request.query["view"] ?? "popover" {
        case "popover": data = Snapshot.png(PopoverView(env: env), width: width, dark: dark)
        case "main": data = Snapshot.png(MainWindowView(env: env), width: max(width, 560), dark: dark)
        case "hud":
            guard let state = VoiceRoutes.hudState(request.query["state"] ?? "recording") else {
                return .error("state must be one of preparing, recording, handsfree, transcribing, interpreting, result, question, note", status: 400)
            }
            data = Snapshot.png(HUDView(model: state), width: max(width, 420), dark: dark)
        default: return .error("view must be popover, main or hud", status: 400)
        }
        guard let data else { return .error("render failed", status: 500) }
        return .png(data)
    }

    // MARK: Encoding

    /// What a processed memo looks like to a script: the outcome kind, the changes or answer, and model stats.
    static func outcomeBody(_ outcome: ProcessOutcome, env: AppEnvironment, started: Date) -> [String: Any] {
        var body: [String: Any] = [
            "memoID": outcome.memo.id, "memoStatus": outcome.memo.status.rawValue,
            "wallMs": Int(Date().timeIntervalSince(started) * 1000),
            "lines": env.toast?.lines ?? [],
        ]
        switch outcome.kind {
        case let .applied(result):
            body["kind"] = "applied"
            body["opID"] = result.op?.id ?? NSNull()
            body["changes"] = result.changes.map(describe)
        case let .answered(plan):
            body["kind"] = "answered"
            body["entries"] = env.queryResult?.entries.map(describe(entry:)) ?? []
            _ = plan
        case let .clarify(clarification):
            body["kind"] = "clarify"
            body["question"] = clarification.question
            body["reason"] = clarification.reason.rawValue
            body["options"] = clarification.options
        case .unknown:
            body["kind"] = "unknown"
        case let .failed(error, retryAt):
            body["kind"] = "failed"
            body["error"] = "\(error)"
            body["retryAt"] = retryAt.map { ISO8601DateFormatter().string(from: $0) } ?? NSNull()
        }
        if let result = outcome.interpretation {
            body["llm"] = [
                "model": result.llm.model, "wallMs": result.llm.wallMs, "attempts": result.attempts,
                "intent": result.response.intent.rawValue, "confidence": result.response.confidence,
            ]
            if !result.warnsEmpty { body["warnings"] = result.warnings }
        }
        return body
    }


    private static func describe(_ change: AppliedChange) -> [String: Any] {
        [
            "kind": change.kind.rawValue, "id": change.item.id, "title": change.item.title,
            "itemKind": change.item.kind.rawValue, "date": change.item.date.map { "\($0)" } ?? NSNull(),
            "time": change.item.time.map { "\($0)" } ?? NSNull(), "recurring": change.item.recurrence != nil,
            "summary": change.summary(today: AppEnvironment.shared.clock.localNow().date),
        ]
    }

    private static func describe(entry: AgendaEntry) -> [String: Any] {
        [
            "id": entry.id, "title": entry.item.title, "kind": entry.item.kind.rawValue,
            "date": "\(entry.date)", "time": entry.time.map { "\($0)" } ?? NSNull(), "done": entry.isDone,
            "recurring": entry.isRecurring, "source": entry.item.source.rawValue,
        ]
    }
}

private extension InterpretResult {
    var warnsEmpty: Bool { warnings.isEmpty }

    var warnings: [String] {
        if case let .mutate(plan) = interpretation { return plan.warnings }
        return []
    }
}
