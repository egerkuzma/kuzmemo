import Foundation
import Testing
@testable import KuzmemoCore

private let createAnswer = ParserResponseTests.create
private let moscow = TimeZone(identifier: "Europe/Moscow")!

private func processor(
    _ steps: [ScriptedProvider.Step], now: String = "2026-09-28 14:30", retry: RetryPolicy = .standard
) throws -> (MemoProcessor, Store, ScriptedProvider) {
    let store = try makeStore(now: now)
    let provider = ScriptedProvider(steps)
    let clock = FixedNow(local: now, in: moscow)!
    let ids = IDSequence()
    let processor = MemoProcessor(
        store: store, interpreter: Interpreter(store: store, provider: provider), clock: clock,
        retryPolicy: retry, makeID: { "m" + ids.next() }
    )
    return (processor, store, provider)
}

@Suite("MemoProcessor")
struct MemoProcessorTests {
    @Test func aTextPhraseIsSavedInterpretedAndApplied() async throws {
        let (processor, store, _) = try processor([.json(createAnswer)])
        let outcome = await processor.submit(text: "напомни мне послезавтра сказать Дмитрию про доступ в Нотион", inputKind: .text)
        guard case let .applied(result) = outcome.kind else { Issue.record("expected applied: \(outcome.kind)"); return }
        #expect(result.changes.count == 1 && result.changes[0].kind == .created)

        let memo = try #require(try await store.memo(id: outcome.memo.id))
        #expect(memo.status == .applied && memo.intent == "create" && memo.llmModel == "sonnet" && memo.llmMs == 5)
        #expect(memo.anchorLocal == "2026-09-28 14:30" && memo.tz == "Europe/Moscow" && memo.opID == result.op?.id)
        #expect(memo.transcriptRaw == "напомни мне послезавтра сказать Дмитрию про доступ в Нотион")
        let item = try #require(try await store.items(on: LocalDate("2026-09-30")!).first)
        #expect(item.source == .quickadd && item.memoID == memo.id && item.title.contains("Дмитрию"))
    }

    @Test func voiceInputProducesVoiceItemsAndKeepsRecognitionStats() async throws {
        let (processor, store, _) = try processor([.json(createAnswer)])
        let outcome = await processor.submit(text: "напомни", inputKind: .voice, sttModel: "whisperkit-large-v3-turbo", sttMs: 640, durationMs: 4100)
        let memo = try #require(try await store.memo(id: outcome.memo.id))
        #expect(memo.inputKind == .voice && memo.sttModel == "whisperkit-large-v3-turbo" && memo.sttMs == 640 && memo.durationMs == 4100)
        #expect(try await store.items(on: LocalDate("2026-09-30")!).first?.source == .voice)
    }

    @Test func aTransientFailureSchedulesARetryThatCanSucceed() async throws {
        let (processor, store, provider) = try processor([.fail(.timedOut(seconds: 30)), .json(createAnswer)])
        let first = await processor.submit(text: "напомни", inputKind: .text)
        guard case let .failed(error, retryAt) = first.kind else { Issue.record("expected failure"); return }
        #expect(error == .timedOut(seconds: 30) && retryAt == Date(timeIntervalSince1970: 1_790_595_060))
        let failed = try #require(try await store.memo(id: first.memo.id))
        #expect(failed.status == .failed && failed.attempts == 1 && failed.nextRetryAt == 1_790_595_060_000 && failed.failStage == "llm")
        #expect(try await store.items(on: LocalDate("2026-09-30")!).isEmpty)

        let second = try #require(await processor.retry(memoID: first.memo.id))
        guard case .applied = second.kind else { Issue.record("expected applied: \(second.kind)"); return }
        let done = try #require(try await store.memo(id: first.memo.id))
        #expect(done.status == .applied && done.failStage == nil && done.nextRetryAt == nil)
        #expect(provider.requests.count == 2)
    }

    @Test func aLoginProblemWaitsForTheUserInsteadOfRetrying() async throws {
        let (processor, store, _) = try processor([.fail(.notLoggedIn)])
        let outcome = await processor.submit(text: "напомни", inputKind: .text)
        guard case let .failed(error, retryAt) = outcome.kind else { Issue.record("expected failure"); return }
        #expect(error == .notLoggedIn && retryAt == nil)
        #expect(try await store.memo(id: outcome.memo.id)?.nextRetryAt == nil)
        #expect(try await store.unfinishedMemos().map(\.id) == [outcome.memo.id])
    }

    @Test func retriesStopAfterTheMaximumNumberOfAttempts() async throws {
        let policy = RetryPolicy(delays: [60], maxAttempts: 2)
        let (processor, store, _) = try processor([.fail(.timedOut(seconds: 1)), .fail(.timedOut(seconds: 1))], retry: policy)
        let first = await processor.submit(text: "x", inputKind: .text)
        guard case let .failed(_, firstRetry) = first.kind else { Issue.record("expected failure"); return }
        #expect(firstRetry != nil)
        let second = try #require(await processor.retry(memoID: first.memo.id))
        guard case let .failed(_, secondRetry) = second.kind else { Issue.record("expected failure"); return }
        #expect(secondRetry == nil)
        #expect(try await store.memo(id: first.memo.id)?.attempts == 2)
    }

    @Test func questionsClarificationsAndNoiseChangeNothing() async throws {
        let (processor, store, _) = try processor([
            .json(ParserResponseTests.query), .json(ParserResponseTests.clarify), .json(#"{"intent":"unknown","confidence":0.9}"#),
        ])
        let question = await processor.submit(text: "скажи что на сегодня", inputKind: .voice)
        guard case let .answered(plan) = question.kind else { Issue.record("expected answered"); return }
        #expect(plan.target == .days(LocalDate("2026-09-28")! ... LocalDate("2026-09-28")!))
        #expect(question.memo.status == .answered)

        let unclear = await processor.submit(text: "в следующую пятницу созвон", inputKind: .voice)
        guard case let .clarify(c) = unclear.kind else { Issue.record("expected clarify"); return }
        #expect(c.reason == .ambiguousDate && unclear.memo.status == .clarifying)

        let noise = await processor.submit(text: "э-э ну", inputKind: .voice)
        guard case .unknown = noise.kind else { Issue.record("expected unknown"); return }
        #expect(noise.memo.status == .discarded)
        #expect(try await store.agenda(in: LocalDate("2026-09-01")! ... LocalDate("2026-12-31")!).isEmpty)
    }

    @Test func recoveryResumesInterruptedAndDueMemosOnly() async throws {
        let (processor, store, provider) = try processor([.json(createAnswer), .json(createAnswer)])
        func memo(_ id: String, _ status: MemoStatus, retryAt: Int64? = nil, text: String? = "напомни") -> Memo {
            Memo(id: id, createdAt: 1, anchorLocal: "2026-09-28 14:30", tz: "Europe/Moscow", inputKind: .voice,
                 status: status, transcriptRaw: text, nextRetryAt: retryAt)
        }
        for m in [
            memo("interrupted", .thinking),
            memo("due", .failed, retryAt: 1_790_594_000_000),
            memo("later", .failed, retryAt: 1_790_599_000_000),
            memo("waiting", .clarifying),
            memo("recording", .recorded, text: nil),
            memo("done", .applied),
        ] { try await store.save(memo: m) }

        let outcomes = await processor.recoverUnfinished()
        #expect(Set(outcomes.map(\.memo.id)) == ["interrupted", "due"])
        #expect(provider.requests.count == 2)
        #expect(try await store.unfinishedMemos().map(\.id).sorted() == ["later", "recording", "waiting"])
    }

    @Test func aMemoWhoseChangesAlreadyLandedIsNotAppliedTwice() async throws {
        let (processor, store, provider) = try processor([.json(createAnswer)])
        try await store.save(memo: Memo(id: "crashed", createdAt: 1, anchorLocal: "2026-09-28 14:30", tz: "Europe/Moscow",
                                        inputKind: .voice, status: .interpreted, transcriptRaw: "напомни"))
        let landed = try #require(try await store.perform(label: "before the crash", memoID: "crashed") { m in
            try m.insert(Item(id: "", kind: .reminder, title: "Уже создано", date: LocalDate("2026-09-30"), source: .voice, memoID: "crashed"))
        })
        let outcomes = await processor.recoverUnfinished()
        #expect(outcomes.count == 1 && provider.requests.isEmpty)
        let memo = try #require(try await store.memo(id: "crashed"))
        #expect(memo.status == .applied && memo.opID == landed.id)
        #expect(try await store.items(on: LocalDate("2026-09-30")!).count == 1)
    }

    @Test func relativeDatesUseTheMomentTheUserSpokeNotTheRetryTime() async throws {
        let (processor, store, provider) = try processor([.json(createAnswer)])
        try await store.save(memo: Memo(id: "old", createdAt: 1, anchorLocal: "2026-09-20 09:00", tz: "Europe/Moscow",
                                        inputKind: .voice, status: .failed, transcriptRaw: "напомни послезавтра", attempts: 1))
        _ = await processor.retry(memoID: "old")
        #expect(provider.requests.first?.userMessage.contains("<now>Sunday 2026-09-20 09:00 (Europe/Moscow, UTC+03:00)</now>") == true)
        // "послезавтра" from 2026-09-20 is 2026-09-22
        #expect(try await store.items(on: LocalDate("2026-09-22")!).count == 1)
    }

    @Test func aLocallyRecognisedQuestionIsRecordedWithoutCallingTheModel() async throws {
        let (processor, store, provider) = try processor([])
        let plan = QueryPlan(target: .days(LocalDate("2026-09-28")! ... LocalDate("2026-09-28")!))
        let outcome = await processor.answerLocally(text: "скажи что на сегодня", plan: plan, inputKind: .voice, sttModel: "whisper", sttMs: 500)
        guard case let .answered(answered) = outcome.kind else { Issue.record("expected answered"); return }
        #expect(answered == plan && provider.requests.isEmpty)
        let memo = try #require(try await store.memo(id: outcome.memo.id))
        #expect(memo.status == .answered && memo.llmModel == "local-router" && memo.intent == "query" && memo.sttMs == 500)
        #expect(try await store.unfinishedMemos().isEmpty)
    }

    @Test func glossaryCorrectionsAreRemembered() async throws {
        let (processor, store, _) = try processor([.json(#"{"intent":"unknown","confidence":0.9}"#)])
        try await store.save(term: GlossaryTerm(canonical: "Notion", aliases: ["нотиона"]))
        let outcome = await processor.submit(text: "доступ Нотиона", inputKind: .voice)
        #expect(outcome.memo.transcriptRaw == "доступ Нотиона" && outcome.memo.transcriptCorrected == "доступ Notion")
    }
}
