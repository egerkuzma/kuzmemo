import AppKit
import Foundation
import KuzmemoCore

/// The dev control channel's routes. Everything here runs on the main actor and talks to the same
/// `AppEnvironment` the UI uses, so a check through the socket exercises the real code path.
enum ControlRoutes {
    /// A build that is not the dev bundle can have the channel on (`KUZMEMO_CONTROL=1`), to look at a window or a banner on the
    /// real app. Only what changes nothing of the person's is open then: reading, rendering, opening and closing windows,
    /// moving around the UI. Settings, the clock, transcripts, keys, the voice sample and undo belong to the dev bundle, where
    /// scripts reset things at will; before this, a handful of routes checked it one by one and the rest did not.
    private static let openToEveryBuild: Set<String> = ["/ui", "/window/open", "/window/close", "/popover/wiring"]

    static func handle(_ request: HTTPRequest) async -> HTTPResponse {
        let env = AppEnvironment.shared
        if request.method != "GET", !env.paths.isDev, !openToEveryBuild.contains(request.path) {
            return .error("this route changes things: it is open on the dev bundle only", status: 409)
        }
        switch (request.method, request.path) {
        case ("GET", "/state"): return await state(request, env)
        case ("POST", "/memo/transcript"): return await submit(request, env)
        case ("GET", "/agenda"): return await agenda(request, env)
        case ("GET", "/inbox"): return await inbox(env)
        case ("POST", "/dev/seed"): return await seed(env)
        case ("GET", "/audio"): return audio(env)
        case ("GET", "/glossary"): return await glossary(env)
        case ("POST", "/glossary"): return await replaceGlossary(request, env)
        case ("GET", "/settings"): return await SettingsRoutes.read(env)
        case ("POST", "/settings"): return await SettingsRoutes.update(request, env)
        case ("GET", "/notifications"): return NotificationRoutes.state(request, env)
        case ("POST", "/notifications/sync"): return await NotificationRoutes.sync(request, env)
        case ("POST", "/ui"): return await ui(request, env)
        case ("GET", "/window"): return WindowRoutes.describe(request.query["name"] ?? "main")
        case ("GET", "/windows"): return WindowRoutes.list()
        case ("POST", "/popover/wiring"): return await PopoverRoutes.wiring(env)
        case ("POST", "/window/open"): return await WindowRoutes.open(env, name: request.query["name"] ?? "main")
        case ("POST", "/window/close"): return WindowRoutes.close(request.query["name"] ?? "main")
        case ("POST", "/window/key"):
            return WindowRoutes.key(name: request.query["name"] ?? "main", key: request.query["key"] ?? "", sheet: request.query["sheet"] == "1")
        case ("POST", "/undo"): return await undo(env)
        case ("POST", "/clock"): return clock(request, env)
        case ("POST", "/db/reset"): return await reset(env)
        case ("GET", "/data"): return await DataRoutes.read(env)
        case ("POST", "/data/check"): return await DataRoutes.check(env)
        case ("POST", "/data/backup"): return await DataRoutes.backup(request, env)
        case ("POST", "/data/daily"): return await DataRoutes.daily(env)
        case ("POST", "/data/erase"): return await DataRoutes.erase(request, env)
        case ("GET", "/render"): return await render(request, env)
        case ("GET", "/voice"): return VoiceRoutes.state(env)
        case ("POST", "/hotkey/down"), ("POST", "/hotkey/up"), ("POST", "/hotkey/other"), ("POST", "/hotkey/escape"):
            return VoiceRoutes.hotkey(request.path, env)
        case ("POST", "/voice/input"): return VoiceRoutes.armInput(request, env)
        case ("POST", "/answer"): return await VoiceRoutes.answer(request, env)
        case ("POST", "/question/close"): return await VoiceRoutes.closeQuestion(request, env)
        case ("POST", "/record/inject-audio"): return await VoiceRoutes.inject(request, env)
        case ("GET", "/speech/log"): return VoiceRoutes.speechLog(env)
        case ("GET", "/speech/silero"): return SileroRoutes.state(env)
        case ("POST", "/speech/silero/say"): return await SileroRoutes.say(request, env)
        case ("GET", "/speech/clone"): return CloneRoutes.state(env)
        case ("POST", "/speech/clone/say"): return await CloneRoutes.say(request, env)
        case ("POST", "/speech/clone/enroll"): return await CloneRoutes.enroll(request, env)
        case ("POST", "/speech/clone/choose"): return await CloneRoutes.choose(request, env)
        case ("POST", "/speech/clone/save"): return await CloneRoutes.save(request, env)
        case ("POST", "/speech/clone/cancel"): return CloneRoutes.cancel(env)
        case ("POST", "/speech/clone/prewarm"): return await CloneRoutes.prewarm(request, env)
        case ("POST", "/speech/clone/forget"): return CloneRoutes.forget(env)
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

    /// Demo data for looking at the window; refuses outside the dev bundle.
    private static func seed(_ env: AppEnvironment) async -> HTTPResponse {
        guard env.paths.isDev else { return .error("refusing to add demo data outside the dev bundle", status: 409) }
        do {
            try await DevSeed.run(env)
            await env.calendar.reload()
            return .json(["seeded": true])
        } catch {
            return .error("\(error)", status: 500)
        }
    }

    /// The audio inputs and the one a recording would use now, without opening any of them.
    private static func audio(_ env: AppEnvironment) -> HTTPResponse {
        let devices = InputDevices.all()
        let pick = MicrophoneChoice.pick(env.settings.recording.microphonePreference, among: devices)
        let reason: Any
        switch pick.reason {
        case let .bluetoothAvoided(name)?: reason = "bluetoothAvoided: \(name)"
        case .pickedDeviceMissing?: reason = "pickedDeviceMissing"
        case nil: reason = NSNull()
        }
        return .json([
            "devices": devices.map { ["uid": $0.uid, "name": $0.name, "transport": $0.transport.rawValue, "default": $0.isSystemDefault] as [String: Any] },
            "preference": env.settings.recording.microphone ?? "automatic",
            "picked": pick.device?.uid ?? NSNull(), "pickedName": pick.device?.name ?? NSNull(),
            "pickedTransport": pick.device?.transport.rawValue ?? NSNull(), "reason": reason,
        ])
    }

    /// The glossary as the database holds it.
    private static func glossary(_ env: AppEnvironment) async -> HTTPResponse {
        let terms = (try? await env.store.glossary()) ?? []
        return .json(["terms": terms.map { term -> [String: Any] in
            ["canonical": term.canonical, "kind": term.kind ?? NSNull(), "aliases": term.aliases, "spoken": term.spoken ?? NSNull(), "enabled": term.enabled]
        }])
    }

    /// Replaces the whole glossary (a new install starts with an empty one, so tests bring their own words):
    /// `{"terms": [{"canonical": "GitHub", "aliases": ["git hub"], "spoken": "Git Hub"}]}`.
    private static func replaceGlossary(_ request: HTTPRequest, _ env: AppEnvironment) async -> HTTPResponse {
        guard env.paths.isDev else { return .error("refusing to replace the glossary outside the dev bundle", status: 409) }
        guard let items = request.jsonBody?["terms"] as? [[String: Any]] else { return .error("body must be {\"terms\": [...]}", status: 400) }
        var terms: [GlossaryTerm] = []
        for item in items {
            guard let canonical = (item["canonical"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !canonical.isEmpty else {
                return .error("every term needs a canonical spelling", status: 400)
            }
            terms.append(GlossaryTerm(
                canonical: canonical, kind: item["kind"] as? String, aliases: (item["aliases"] as? [String]) ?? [],
                spoken: item["spoken"] as? String, enabled: (item["enabled"] as? Bool) ?? true
            ))
        }
        do {
            try await env.store.replaceGlossary(with: terms)
            return .json(["terms": terms.count])
        } catch {
            return .error("\(error)", status: 500)
        }
    }

    /// Puts the window in a state: `mode`, `date`, `search`, and `editor` ("new" or a part of an entry's title).
    private static func ui(_ request: HTTPRequest, _ env: AppEnvironment) async -> HTTPResponse {
        guard let json = request.jsonBody else { return .error("body must be JSON", status: 400) }
        let calendar = env.calendar
        if let text = json["date"] as? String {
            guard let date = LocalDate(text) else { return .error("bad date", status: 400) }
            calendar.select(date)
        }
        if let text = json["mode"] as? String {
            guard let mode = CalendarModel.Mode(rawValue: text) else { return .error("mode must be day, inbox, search or recurring", status: 400) }
            if mode == .day { calendar.select(calendar.selectedDate) } else { calendar.show(mode) }
        }
        if let text = json["search"] as? String { calendar.setSearchText(text) }
        if let text = json["settingsTab"] as? String {
            guard let tab = SettingsView.Tab(rawValue: text) else { return .error("unknown settings tab", status: 400) }
            env.settingsTab = tab
        }
        await calendar.settled()
        await calendar.reload()
        if let editor = json["editor"] as? String {
            if editor == "new" {
                env.editorRequest = .new(ItemDraft(kind: .task, date: calendar.selectedDate))
            } else if let item = await findItem(titleContaining: editor, env) {
                env.editorRequest = .edit(item)
            } else {
                return .error("no entry with «\(editor)» in its title", status: 404)
            }
        } else if json["editor"] is NSNull {
            env.editorRequest = nil
        }
        return .json([
            "mode": calendar.mode.rawValue, "date": "\(calendar.selectedDate)", "today": "\(calendar.today)",
            "dayEntries": calendar.dayEntries.count, "overdue": calendar.overdueEntries.count, "inbox": calendar.inboxCount,
            "search": calendar.searchResults.count, "recurring": calendar.recurring.count,
        ])
    }

    static func findItem(titleContaining part: String, _ env: AppEnvironment) async -> Item? {
        let needle = SearchText.normalize(part)
        let all = (try? await env.store.agenda(in: env.calendar.grid.range)) ?? []
        if let hit = all.first(where: { SearchText.normalize($0.item.title).contains(needle) }) { return hit.item }
        let extras = ((try? await env.store.inbox()) ?? []) + ((try? await env.store.recurringSeries()) ?? [])
        return extras.first { SearchText.normalize($0.title).contains(needle) }
    }

    /// Entries without a date.
    private static func inbox(_ env: AppEnvironment) async -> HTTPResponse {
        guard let items = try? await env.store.inbox() else { return .error("cannot read the inbox", status: 500) }
        return .json(["items": items.map { ["id": $0.id, "title": $0.title, "kind": $0.kind.rawValue, "details": $0.details ?? "", "source": $0.source.rawValue] }])
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

    /// A number from the query, kept inside `range`; a missing one, or one that is not a finite number ("nan", "inf" would trap
    /// when the picture size is made an integer), is the default.
    private static func number(_ text: String?, default fallback: Double, in range: ClosedRange<Double>) -> Double {
        guard let text, let value = Double(text), value.isFinite else { return fallback }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    private static func render(_ request: HTTPRequest, _ env: AppEnvironment) async -> HTTPResponse {
        let dark = request.query["scheme"] == "dark"
        let width = CGFloat(number(request.query["width"], default: 380, in: 100 ... 4000))
        let data: Data?
        switch request.query["view"] ?? "popover" {
        case "popover": data = Snapshot.png(PopoverView(env: env), width: width, dark: dark)
        case "main":
            let height = CGFloat(number(request.query["height"], default: 660, in: 100 ... 6000))
            data = Snapshot.png(MainWindowView(env: env), width: max(width, 860), height: height, dark: dark)
        case "settings":
            env.settingsTab = SettingsView.Tab(rawValue: request.query["tab"] ?? "") ?? env.settingsTab
            data = Snapshot.png(SettingsView(env: env), width: SettingsView.size.width, height: SettingsView.size.height, dark: dark)
        case "settingsTab":
            // One tab on its own, as tall as asked, so the whole form is visible (the window scrolls it).
            let tab = SettingsView.Tab(rawValue: request.query["tab"] ?? "") ?? env.settingsTab
            if tab == .data { await env.data.refresh() }
            let height = CGFloat(number(request.query["height"], default: 1500, in: 100 ... 6000))
            data = Snapshot.png(SettingsView.page(tab, env: env).environment(\.locale, DateBridge.locale), width: SettingsView.size.width, height: height, dark: dark)
        case "live":
            return await WindowRoutes.capture(
                name: request.query["name"] ?? "main", sheet: request.query["sheet"] == "1", front: request.query["front"] == "1",
                chrome: request.query["chrome"] == "1", scale: CGFloat(number(request.query["scale"], default: 2, in: 0.5 ... 4)), scheme: request.query["scheme"]
            )
        case "editor":
            let title = request.query["title"] ?? "new"
            let editing: AppEnvironment.EditorRequest
            if title == "new" {
                editing = .new(ItemDraft(kind: .task, date: env.calendar.selectedDate))
            } else if let item = await findItem(titleContaining: title, env) {
                editing = .edit(item)
            } else {
                return .error("no entry with «\(title)» in its title", status: 404)
            }
            data = Snapshot.png(ItemEditorView(request: editing, env: env), width: 480, dark: dark)
        case "hud":
            guard let state = VoiceRoutes.hudState(request.query["state"] ?? "recording") else {
                return .error("state must be one of preparing, recording, handsfree, transcribing, interpreting, result, question, listening, note", status: 400)
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
