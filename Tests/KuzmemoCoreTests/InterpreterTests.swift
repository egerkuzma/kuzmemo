import Foundation
import Synchronization
import Testing
@testable import KuzmemoCore

/// Replays scripted results and records what it was asked.
final class ScriptedProvider: LLMProvider, Sendable {
    enum Step: Sendable {
        case json(String)
        case fail(LLMError)
    }

    private let steps: Mutex<[Step]>
    private let seen = Mutex<[LLMRequest]>([])

    init(_ steps: [Step]) { self.steps = Mutex(steps) }

    var requests: [LLMRequest] { seen.withLock { $0 } }

    func complete(_ request: LLMRequest) async throws -> LLMResponse {
        seen.withLock { $0.append(request) }
        let step = steps.withLock { $0.isEmpty ? Step.fail(.processFailed(exitCode: 99, stderr: "no more steps")) : $0.removeFirst() }
        switch step {
        case let .json(text):
            return LLMResponse(structuredJSON: text, rawEnvelope: text, model: request.model, wallMs: 5, reportedMs: 4, usageJSON: nil, costUSD: nil)
        case let .fail(error):
            throw error
        }
    }
}

private let moscow = TimeZone(identifier: "Europe/Moscow")!
private let mondayAfternoon = LocalDateTime(date: LocalDate("2026-09-28")!, time: LocalTime("14:30")!)

@Suite("Interpreter")
struct InterpreterTests {
    @Test func aValidAnswerIsDecodedAndValidated() async throws {
        let store = try makeStore()
        let provider = ScriptedProvider([.json(ParserResponseTests.create)])
        let interpreter = Interpreter(store: store, provider: provider)
        let result = try await interpreter.interpret(InterpretRequest(
            transcript: "напомни мне послезавтра сказать Дмитрию про доступ в Нотион", anchor: mondayAfternoon, timeZone: moscow
        ))
        guard case let .mutate(plan) = result.interpretation, case let .create(new)? = plan.actions.first else {
            Issue.record("expected a create plan, got \(result.interpretation)"); return
        }
        #expect(new.date == LocalDate("2026-09-30") && new.kind == .reminder)
        #expect(result.attempts == 1 && result.response.intent == .create)

        let request = try #require(provider.requests.first)
        #expect(request.systemPrompt == Prompt.system && request.model == "sonnet" && request.effort == "low")
        #expect(request.schema == ResponseSchema.compact)
        #expect(request.userMessage.contains("<transcript>напомни мне послезавтра сказать Дмитрию про доступ в Нотион</transcript>"))
        #expect(request.userMessage.contains("<now>Monday 2026-09-28 14:30 (Europe/Moscow, UTC+03:00)</now>"))
    }

    @Test func theGlossaryCleansTheTranscriptAndAppearsInThePrompt() async throws {
        let store = try makeStore()
        try await store.save(term: GlossaryTerm(canonical: "Notion", aliases: ["нотион", "нотиона"]))
        let provider = ScriptedProvider([.json(#"{"intent":"unknown","confidence":0.9}"#)])
        let result = try await Interpreter(store: store, provider: provider).interpret(InterpretRequest(
            transcript: "проверить доступ Нотиона", anchor: mondayAfternoon, timeZone: moscow
        ))
        #expect(result.transcriptSent == "проверить доступ Notion")
        let message = try #require(provider.requests.first?.userMessage)
        #expect(message.contains("<transcript>проверить доступ Notion</transcript>"))
        #expect(message.contains("<glossary>Notion (нотион, нотиона)</glossary>"))
    }

    @Test func theModelSeesExistingEntriesAndTheirNumbersResolve() async throws {
        let store = try makeStore()
        try await store.perform(label: "seed") { m in
            try m.insert(Item(id: "", kind: .event, title: "Встреча с Дмитрием", date: LocalDate("2026-10-02"), time: LocalTime("15:00"), source: .voice))
        }
        let answer = #"{"intent":"update","confidence":0.9,"actions":[{"op":"update","ref":1,"changes":{"when":{"mode":"weekday","weekday":"thu","week_offset":0,"phrase":"на четверг"}}}]}"#
        let provider = ScriptedProvider([.json(answer)])
        let result = try await Interpreter(store: store, provider: provider).interpret(InterpretRequest(
            transcript: "перенеси встречу с Дмитрием на четверг", anchor: mondayAfternoon, timeZone: moscow
        ))
        let message = try #require(provider.requests.first?.userMessage)
        #expect(message.contains("[1] 2026-10-02 15:00 event \"Встреча с Дмитрием\""))
        #expect(result.context.expanded)
        guard case let .mutate(plan) = result.interpretation else { Issue.record("expected mutate: \(result.interpretation)"); return }
        #expect(plan.actions == [.update(itemID: "id-1", changes: ItemChanges(date: LocalDate("2026-10-01")))])
    }

    @Test func aMalformedAnswerIsAskedForOnceMore() async throws {
        let store = try makeStore()
        let provider = ScriptedProvider([.json(#"{"intent":"nonsense"}"#), .json(#"{"intent":"unknown","confidence":0.8}"#)])
        let result = try await Interpreter(store: store, provider: provider).interpret(InterpretRequest(
            transcript: "э-э ну", anchor: mondayAfternoon, timeZone: moscow
        ))
        #expect(result.attempts == 2 && provider.requests.count == 2)
        #expect(result.interpretation == .unknown(nil))
    }

    @Test func twoMalformedAnswersFailWithASchemaViolation() async throws {
        let store = try makeStore()
        let provider = ScriptedProvider([.json("not json"), .json(#"{"intent":"nonsense"}"#)])
        await #expect(throws: LLMError.self) {
            try await Interpreter(store: store, provider: provider).interpret(InterpretRequest(
                transcript: "x", anchor: mondayAfternoon, timeZone: moscow
            ))
        }
        #expect(provider.requests.count == 2)
    }

    @Test func loginAndTimeoutFailuresAreNotRetriedHere() async throws {
        let store = try makeStore()
        let login = ScriptedProvider([.fail(.notLoggedIn), .json(ParserResponseTests.create)])
        await #expect(throws: LLMError.notLoggedIn) {
            try await Interpreter(store: store, provider: login).interpret(InterpretRequest(transcript: "x", anchor: mondayAfternoon, timeZone: moscow))
        }
        #expect(login.requests.count == 1)
        let slow = ScriptedProvider([.fail(.timedOut(seconds: 30)), .json(ParserResponseTests.create)])
        await #expect(throws: LLMError.timedOut(seconds: 30)) {
            try await Interpreter(store: store, provider: slow).interpret(InterpretRequest(transcript: "x", anchor: mondayAfternoon, timeZone: moscow))
        }
        #expect(slow.requests.count == 1)
    }

    @Test func settingsFlowThroughToTheRequest() async throws {
        let store = try makeStore()
        let provider = ScriptedProvider([.json(#"{"intent":"unknown","confidence":0.8}"#)])
        var interpreter = Interpreter(store: store, provider: provider, model: "opus", effort: nil, timeout: 12)
        interpreter.promptBuilder = PromptBuilder(dayParts: {
            var parts = DayPartDefaults.standard
            parts.morning = LocalTime("07:30")!
            return parts
        }())
        _ = try await interpreter.interpret(InterpretRequest(transcript: "x", anchor: mondayAfternoon, timeZone: moscow))
        let request = try #require(provider.requests.first)
        #expect(request.model == "opus" && request.effort == nil && request.timeout == 12)
        #expect(request.userMessage.contains("morning=07:30"))
    }
}
