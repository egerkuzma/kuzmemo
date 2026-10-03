import Foundation
import GRDB
import Synchronization
import Testing
@testable import KuzmemoCore

private let createAnswer = ParserResponseTests.create
private let moscow = TimeZone(identifier: "Europe/Moscow")!

/// Answers like `inner`, but the n-th call waits for the n-th gate (one gate per call, so a test can hold each answer apart).
private final class SteppedProvider: LLMProvider, Sendable {
    let gates: [Gate]
    private let inner: ScriptedProvider
    private let calls = Mutex(0)

    init(_ inner: ScriptedProvider, steps: Int) {
        self.inner = inner
        gates = (0 ..< steps).map { _ in Gate() }
    }

    var callCount: Int { calls.withLock { $0 } }

    func complete(_ request: LLMRequest) async throws -> LLMResponse {
        let index = calls.withLock { $0 += 1; return $0 - 1 }
        if index < gates.count { await gates[index].wait() }
        return try await inner.complete(request)
    }
}

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

    @Test func aMemoBeingInterpretedIsNotPickedUpAgain() async throws {
        let store = try makeStore()
        let provider = GatedProvider(ScriptedProvider([.json(createAnswer)]))
        let processor = MemoProcessor(
            store: store, interpreter: Interpreter(store: store, provider: provider),
            clock: FixedNow(local: "2026-09-28 14:30", in: moscow)!
        )
        let live = Task { await processor.submit(text: "напомни мне послезавтра сказать Дмитрию", inputKind: .text) }
        while provider.callCount == 0 { try await Task.sleep(for: .milliseconds(10)) }

        // A timer-driven recovery or a manual retry fires while the model is still thinking.
        #expect(await processor.recoverUnfinished().isEmpty)
        let memoID = try #require(try await store.unfinishedMemos().first).id
        #expect(await processor.retry(memoID: memoID) == nil)

        await provider.gate.open()
        let outcome = await live.value
        guard case .applied = outcome.kind else { Issue.record("expected applied: \(outcome.kind)"); return }
        #expect(try await store.items(on: LocalDate("2026-09-30")!).count == 1) // applied once, not twice
        #expect(provider.callCount == 1)
    }

    /// "Erase all entries and history" while a retry is with the model: the answer used to arrive after the erase, save the phrase
    /// again and make its entry all over (the app only refused to erase while a spoken phrase was being worked on, and a retry
    /// started by the timer is not that).
    @Test func anEraseWhileAPhraseIsWithTheModelIsNotUndoneByTheAnswer() async throws {
        let store = try makeStore()
        let provider = GatedProvider(ScriptedProvider([.json(createAnswer)]))
        let processor = MemoProcessor(
            store: store, interpreter: Interpreter(store: store, provider: provider),
            clock: FixedNow(local: "2026-09-28 14:30", in: moscow)!
        )
        try await store.save(memo: Memo(id: "failed", createdAt: 1, anchorLocal: "2026-09-28 14:30", tz: "Europe/Moscow", inputKind: .voice,
                                        status: .failed, transcriptRaw: "напомни мне послезавтра сказать Дмитрию", nextRetryAt: 1))
        let retry = Task { await processor.retry(memoID: "failed") }
        while provider.callCount == 0 { try await Task.sleep(for: .milliseconds(10)) }

        try await store.eraseEntriesAndHistory() // the person erases while the model is thinking
        await provider.gate.open()
        _ = await retry.value

        #expect(try await store.overview() == DataOverview(entries: 0, memos: 0, undoSteps: 0, glossaryTerms: 0))
        #expect(try await store.search("Дмитрию").isEmpty)
    }

    /// The same for a phrase that is typed, and for one that is waiting for the answer to a question.
    @Test func aPhraseThatIsErasedIsNeverSavedAgainByAnyStepOfTheProcessor() async throws {
        let store = try makeStore()
        let provider = ScriptedProvider([.json(createAnswer)])
        let processor = MemoProcessor(
            store: store, interpreter: Interpreter(store: store, provider: provider),
            clock: FixedNow(local: "2026-09-28 14:30", in: moscow)!
        )
        let memo = Memo(id: "asking", createdAt: 1, anchorLocal: "2026-09-28 14:30", tz: "Europe/Moscow", inputKind: .voice,
                        status: .clarifying, transcriptRaw: "напомни про Дмитрия")
        try await store.save(memo: memo)
        try await store.eraseEntriesAndHistory()
        #expect(await processor.keepAsNote(memoID: "asking") == nil) // nothing is there any more to keep
        await processor.discard(memoID: "asking", reason: "late")
        await processor.supersede("asking")
        #expect(try await store.overview() == DataOverview(entries: 0, memos: 0, undoSteps: 0, glossaryTerms: 0))
    }

    /// "Save as a note" used to make the note and then mark the phrase as dealt with, in two writes. If the app quit between them,
    /// the phrase was still "asking" at the next launch, and closing orphaned questions made the same note a second time. The
    /// store now marks the phrase in the note's own transaction; a database written by an older version can still be in that state.
    @Test func savingAPhraseAsANoteTwiceAfterACrashBetweenTheWritesMakesOneNote() async throws {
        let store = try makeStore()
        let provider = ScriptedProvider([])
        let processor = MemoProcessor(
            store: store, interpreter: Interpreter(store: store, provider: provider),
            clock: FixedNow(local: "2026-09-28 14:30", in: moscow)!
        )
        try await store.save(memo: Memo(id: "asking", createdAt: 1, anchorLocal: "2026-09-28 14:30", tz: "Europe/Moscow", inputKind: .voice,
                                        status: .clarifying, transcriptRaw: "позвонить Дмитрию"))
        // what the older version did before the app was gone: the note and its journal entry, but not the memo's new status
        let plan = MutationPlan(actions: [.create(NewItem(kind: .note, title: "позвонить Дмитрию"))])
        let first = try await store.apply(plan, source: .voice, memoID: "asking", label: "Note from a phrase")
        try await store.writer.write { db in try db.execute(sql: "UPDATE memos SET status = 'clarifying', op_id = NULL WHERE id = 'asking'") }
        #expect(try await store.memo(id: "asking")?.status == .clarifying)

        let outcomes = await processor.closeOrphanedQuestions() // the next launch
        #expect(try await store.inbox().map(\.title) == ["позвонить Дмитрию"], "a second note was made")
        let memo = try #require(try await store.memo(id: "asking"))
        #expect(memo.status == .applied && memo.opID == first.op?.id)
        guard case .applied = outcomes.first?.kind else { Issue.record("expected the phrase to be reported as applied: \(outcomes)"); return }
    }

    /// Two triggers for one memo (the Retry button and the timer, a double click) used to pass the "not in flight" check while
    /// the first was still reading the memo, and the phrase was interpreted and applied twice.
    @Test func severalSimultaneousRetriesApplyThePhraseOnce() async throws {
        let store = try makeStore()
        let provider = GatedProvider(ScriptedProvider([.json(createAnswer), .json(createAnswer), .json(createAnswer), .json(createAnswer)]))
        let processor = MemoProcessor(
            store: store, interpreter: Interpreter(store: store, provider: provider),
            clock: FixedNow(local: "2026-09-28 14:30", in: moscow)!
        )
        try await store.save(memo: Memo(id: "failed", createdAt: 1, anchorLocal: "2026-09-28 14:30", tz: "Europe/Moscow", inputKind: .voice,
                                        status: .failed, transcriptRaw: "напомни мне послезавтра сказать Дмитрию", nextRetryAt: 1))
        let tries = (0 ..< 4).map { _ in Task { await processor.retry(memoID: "failed") } }
        while provider.callCount == 0 { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(100)) // time for the others to pass a check, if it let them
        await provider.gate.open()
        var results: [ProcessOutcome?] = []
        for attempt in tries { results.append(await attempt.value) }
        #expect(results.compactMap { $0 }.count == 1, "only one retry may run")
        #expect(provider.callCount == 1)
        #expect(try await store.items(on: LocalDate("2026-09-30")!).count == 1)
    }

    /// The model answers in seconds, and the person may edit the very entry meanwhile (the editor, a notification's Done). The
    /// plan was made from the entry as the model saw it: it is not applied over the person's change. The phrase is read again,
    /// against the entry as it is now, and that reading is what is applied.
    @Test func aLateAnswerDoesNotOverwriteAnEntryEditedWhileTheModelWasThinking() async throws {
        let store = try makeStore()
        let stale = #"{"intent":"update","confidence":0.9,"actions":[{"op":"update","ref":1,"changes":{"when":{"mode":"absolute","date":"2026-10-02","phrase":"на пятницу"}}}]}"#
        let fresh = #"{"intent":"update","confidence":0.9,"actions":[{"op":"update","ref":1,"changes":{"when":{"mode":"absolute","date":"2026-10-09","phrase":"на 9 октября"}}}]}"#
        let scripted = ScriptedProvider([.json(stale), .json(fresh)])
        let provider = GatedProvider(scripted)
        let processor = MemoProcessor(
            store: store, interpreter: Interpreter(store: store, provider: provider), clock: FixedNow(local: "2026-09-28 14:30", in: moscow)!
        )
        let made = try await store.create(ItemDraft(kind: .event, title: "Встреча с Дмитрием", date: LocalDate("2026-09-30"), time: LocalTime("15:00")))
        let phrase = Task { await processor.submit(text: "перенеси встречу с Дмитрием на пятницу", inputKind: .voice) }
        while provider.callCount == 0 { try await Task.sleep(for: .milliseconds(10)) }
        // meanwhile, in the editor: the meeting moves to the 5th
        var draft = ItemDraft(made.item)
        draft.date = LocalDate("2026-10-05")
        try await store.save(draft, as: made.item.id, expectingVersion: 1)
        await provider.gate.open()

        let outcome = await phrase.value
        guard case let .applied(result) = outcome.kind else { Issue.record("expected applied: \(outcome.kind)"); return }
        #expect(provider.callCount == 2) // read again, against the entry as it is now
        let item = try #require(try await store.item(id: made.item.id))
        #expect(item.date == LocalDate("2026-10-09") && item.version == 3 && result.changes.count == 1)
        // the second reading was shown the edited entry, not the one the first answer was made for
        let second = try #require(scripted.requests.last?.userMessage)
        #expect(second.contains("2026-10-05") && !second.contains("2026-09-30"))
    }

    /// A second conflict in a row is not tried a third time: the phrase fails and waits for the person.
    @Test func aSecondConflictInARowFailsThePhrase() async throws {
        let store = try makeStore()
        let move = #"{"intent":"update","confidence":0.9,"actions":[{"op":"update","ref":1,"changes":{"when":{"mode":"absolute","date":"2026-10-02","phrase":"на пятницу"}}}]}"#
        let provider = SteppedProvider(ScriptedProvider([.json(move), .json(move), .json(move)]), steps: 3)
        let processor = MemoProcessor(
            store: store, interpreter: Interpreter(store: store, provider: provider), clock: FixedNow(local: "2026-09-28 14:30", in: moscow)!
        )
        let made = try await store.create(ItemDraft(kind: .event, title: "Встреча с Дмитрием", date: LocalDate("2026-09-30"), time: LocalTime("15:00")))
        let phrase = Task { await processor.submit(text: "перенеси встречу с Дмитрием на пятницу", inputKind: .voice) }
        var draft = ItemDraft(made.item)
        while provider.callCount < 1 { try await Task.sleep(for: .milliseconds(10)) }
        draft.title = "Встреча с Дмитрием и Анной" // an edit while the first answer is on its way
        try await store.save(draft, as: made.item.id)
        await provider.gates[0].open()
        while provider.callCount < 2 { try await Task.sleep(for: .milliseconds(10)) }
        draft.details = "в переговорной" // and another while the second one is
        try await store.save(draft, as: made.item.id)
        await provider.gates[1].open()

        let outcome = await phrase.value
        guard case let .failed(error, _) = outcome.kind else { Issue.record("expected failed: \(outcome.kind)"); return }
        #expect("\(error)".contains("changedMeanwhile") && provider.callCount == 2)
        #expect(try await store.item(id: made.item.id)?.date == LocalDate("2026-09-30")) // never moved
        #expect(try await store.memo(id: outcome.memo.id)?.status == .failed)
    }

    @Test func aDoubleClickOnSaveAsANoteMakesOneNote() async throws {
        let (processor, store, _) = try processor([.json(ParserResponseTests.clarify)])
        let asked = await processor.submit(text: "напомни позвонить Дмитрию", inputKind: .voice)
        async let first = processor.keepAsNote(memoID: asked.memo.id)
        async let second = processor.keepAsNote(memoID: asked.memo.id)
        let outcomes = await [first, second].compactMap { $0 }
        #expect(outcomes.count == 1)
        #expect(try await store.inbox().count == 1)
        #expect(await processor.keepAsNote(memoID: asked.memo.id) == nil) // and a later click finds the note already made
        #expect(try await store.inbox().count == 1)
    }

    /// Recovery reads the list of unfinished memos once and then works through it, and a model call takes seconds. A memo
    /// that a live call has finished by its turn must be left alone; the stale copy used to be run again and applied twice.
    @Test func recoveryLooksAtEachMemoAsItIsWhenItsTurnComes() async throws {
        let store = try makeStore()
        let provider = GatedProvider(ScriptedProvider([.json(createAnswer), .json(createAnswer)]))
        let processor = MemoProcessor(
            store: store, interpreter: Interpreter(store: store, provider: provider),
            clock: FixedNow(local: "2026-09-28 14:30", in: moscow)!
        )
        func memo(_ id: String, at: Int64) -> Memo {
            Memo(id: id, createdAt: at, anchorLocal: "2026-09-28 14:30", tz: "Europe/Moscow", inputKind: .voice,
                 status: .transcribed, transcriptRaw: "напомни мне послезавтра сказать Дмитрию")
        }
        try await store.save(memo: memo("first", at: 1))
        try await store.save(memo: memo("second", at: 2))
        let recovery = Task { await processor.recoverUnfinished() }
        while provider.callCount == 0 { try await Task.sleep(for: .milliseconds(10)) }
        // while the first is being interpreted, something else finishes the second
        var finished = memo("second", at: 2)
        finished.status = .applied
        try await store.save(memo: finished)
        await provider.gate.open()
        let outcomes = await recovery.value
        #expect(outcomes.map(\.memo.id) == ["first"])
        #expect(provider.callCount == 1)
        #expect(try await store.memo(id: "second")?.status == .applied)
        #expect(try await store.items(on: LocalDate("2026-09-30")!).count == 1)
    }

    @Test func anAnswerIsReadWithTheQuestionFromTheMomentItWasAsked() async throws {
        let clarify = ParserResponseTests.clarify
        let (processor, store, provider) = try processor([.json(clarify), .json(createAnswer)], now: "2026-09-28 14:30")
        let asked = await processor.submit(text: "напомни позвонить Дмитрию", inputKind: .voice)
        guard case .clarify = asked.kind else { Issue.record("expected a question: \(asked.kind)"); return }
        #expect(try await store.memo(id: asked.memo.id)?.status == .clarifying)

        let answered = await processor.submit(
            text: "в пятницу", inputKind: .voice, parentMemoID: asked.memo.id, followupQuestion: "На какую дату напомнить?",
            anchor: LocalDateTime(date: LocalDate("2026-09-30")!, time: LocalTime("09:00")!) // ignored: the asker's moment wins
        )
        guard case .applied = answered.kind else { Issue.record("expected applied: \(answered.kind)"); return }
        let message = try #require(provider.requests.last?.userMessage)
        #expect(message.contains("<previous>напомни позвонить Дмитрию</previous>") && message.contains("<question>На какую дату напомнить?</question>"))
        #expect(message.contains("<now>Monday 2026-09-28 14:30"))
        #expect(try await store.memo(id: asked.memo.id)?.status == .superseded)
        let memo = try #require(try await store.memo(id: answered.memo.id))
        #expect(memo.parentMemoID == asked.memo.id && memo.followupQuestion == "На какую дату напомнить?" && memo.anchorLocal == "2026-09-28 14:30")
        #expect(try await store.unfinishedMemos().isEmpty) // a superseded question is not left hanging
    }

    /// The app asked "Delete 3 entries?" and the person said no. The model is not consulted at all: the limits are lifted for
    /// the answer to that question, so a model that misread the no and came back with the deletions would have been obeyed.
    @Test func aNoToTheAppsOwnBulkQuestionNeverReachesTheModel() async throws {
        let threeDeletes = #"{"intent":"delete","confidence":0.9,"actions":[{"op":"delete","ref":1},{"op":"delete","ref":2},{"op":"delete","ref":3}]}"#
        let (processor, store, provider) = try processor([.json(threeDeletes), .json(threeDeletes)])
        try await store.perform(label: "fixtures") { m in
            for n in 1 ... 3 { try m.insert(Item(id: "i\(n)", kind: .reminder, title: "Запись \(n)", date: LocalDate("2026-09-29"))) }
        }
        let asked = await processor.submit(text: "удали всё на завтра", inputKind: .voice)
        guard case let .clarify(question) = asked.kind, question.question == "Удалить 3 записи?" else { Issue.record("expected the bulk question: \(asked.kind)"); return }
        #expect(provider.requests.count == 1)

        let declined = await processor.submit(text: "нет, не надо", inputKind: .voice, parentMemoID: asked.memo.id, followupQuestion: question.question)
        guard case .unknown = declined.kind else { Issue.record("expected nothing to happen: \(declined.kind)"); return }
        #expect(provider.requests.count == 1) // the misreading model was never given the chance
        #expect(try await store.items(on: LocalDate("2026-09-29")!).count == 3)
        #expect(try await store.memo(id: asked.memo.id)?.status == .superseded)
        #expect(try await store.memo(id: declined.memo.id)?.status == .discarded)
        #expect(try await store.unfinishedMemos().isEmpty)
    }

    /// The yes goes to the model (it has to say which entries), and its answer counts as confirmed only within what was agreed to.
    @Test func aYesToTheAppsOwnBulkQuestionIsAppliedWithinWhatWasAgreedTo() async throws {
        let threeDeletes = #"{"intent":"delete","confidence":0.9,"actions":[{"op":"delete","ref":1},{"op":"delete","ref":2},{"op":"delete","ref":3}]}"#
        let fourDeletes = #"{"intent":"delete","confidence":0.9,"actions":[{"op":"delete","ref":1},{"op":"delete","ref":2},{"op":"delete","ref":3},{"op":"delete","ref":4}]}"#
        let (processor, store, provider) = try processor([.json(threeDeletes), .json(fourDeletes), .json(threeDeletes), .json(threeDeletes)])
        try await store.perform(label: "fixtures") { m in
            for n in 1 ... 4 { try m.insert(Item(id: "i\(n)", kind: .reminder, title: "Запись \(n)", date: LocalDate("2026-09-29"))) }
        }
        let asked = await processor.submit(text: "удали три записи на завтра", inputKind: .voice)
        guard case let .clarify(question) = asked.kind else { Issue.record("expected the bulk question: \(asked.kind)"); return }
        // the model's answer to the yes names four: more than the three the person agreed to, so it is asked about again
        let more = await processor.submit(text: "да, удалить", inputKind: .voice, parentMemoID: asked.memo.id, followupQuestion: question.question)
        guard case let .clarify(again) = more.kind else { Issue.record("expected a new question: \(more.kind)"); return }
        #expect(again.question == "Удалить 4 записи?" && provider.requests.count == 2)
        #expect(try await store.items(on: LocalDate("2026-09-29")!).count == 4)
        // the same yes, with an answer that stays within the agreed three, is applied
        let fine = await processor.submit(text: "да", inputKind: .voice, parentMemoID: more.memo.id, followupQuestion: again.question)
        guard case let .applied(result) = fine.kind else { Issue.record("expected the deletions: \(fine.kind)"); return }
        #expect(result.changes.count == 3 && provider.requests.count == 3)
        #expect(try await store.items(on: LocalDate("2026-09-29")!).count == 1)
    }

    @Test func aRetryAfterAFailureKeepsTheConversation() async throws {
        let (processor, _, provider) = try processor([.json(ParserResponseTests.clarify), .fail(.timedOut(seconds: 30)), .json(createAnswer)])
        let asked = await processor.submit(text: "напомни позвонить Дмитрию", inputKind: .voice)
        let failed = await processor.submit(text: "в пятницу", inputKind: .voice, parentMemoID: asked.memo.id, followupQuestion: "На какую дату напомнить?")
        guard case .failed = failed.kind else { Issue.record("expected failure: \(failed.kind)"); return }
        let retried = try #require(await processor.retry(memoID: failed.memo.id))
        guard case .applied = retried.kind else { Issue.record("expected applied: \(retried.kind)"); return }
        #expect(provider.requests.count == 3)
        #expect(provider.requests[2].userMessage.contains("<previous>напомни позвонить Дмитрию</previous>"))
    }

    @Test func aSecondQuestionKeepsBothEarlierAnswersInView() async throws {
        let (processor, _, provider) = try processor([.json(ParserResponseTests.clarify), .json(ParserResponseTests.clarify), .json(createAnswer)])
        let first = await processor.submit(text: "созвон с Акме", inputKind: .voice)
        let second = await processor.submit(text: "в пятницу", inputKind: .voice, parentMemoID: first.memo.id, followupQuestion: "Какую пятницу?")
        guard case .clarify = second.kind else { Issue.record("expected another question: \(second.kind)"); return }
        _ = await processor.submit(text: "ближайшую", inputKind: .voice, parentMemoID: second.memo.id, followupQuestion: "Во сколько?")
        #expect(provider.requests[2].userMessage.contains("<previous>созвон с Акме. в пятницу</previous>"))
        #expect(provider.requests[2].userMessage.contains("<question>Во сколько?</question>"))
    }

    @Test func aQuestionNobodyAnsweredBecomesANoteWithTheOriginalWords() async throws {
        let (processor, store, _) = try processor([.json(ParserResponseTests.clarify)])
        let asked = await processor.submit(text: "напомни позвонить Дмитрию", inputKind: .voice)
        let saved = try #require(await processor.keepAsNote(memoID: asked.memo.id))
        guard case let .applied(result) = saved.kind, let change = result.changes.first else { Issue.record("expected a note: \(saved.kind)"); return }
        #expect(change.item.kind == .note && change.item.title == "напомни позвонить Дмитрию" && change.item.date == nil)
        #expect(change.item.source == .voice && change.item.memoID == asked.memo.id)
        #expect(try await store.memo(id: asked.memo.id)?.status == .applied)
        // and it can be undone like any other change
        try await store.undo(opID: try #require(result.op).id)
        #expect(try await store.inbox().isEmpty)
    }

    @Test func aLongPhraseKeepsAllItsWordsInTheNoteDetails() async throws {
        let (processor, _, _) = try processor([.json(ParserResponseTests.clarify)])
        let long = String(repeating: "очень длинная мысль ", count: 12).trimmingCharacters(in: .whitespaces)
        let asked = await processor.submit(text: long, inputKind: .text)
        let saved = try #require(await processor.keepAsNote(memoID: asked.memo.id))
        guard case let .applied(result) = saved.kind, let item = result.changes.first?.item else { Issue.record("expected a note"); return }
        #expect(item.title.count == 78 && item.title.hasSuffix("…") && item.details == long)
    }

    @Test func questionsLeftOpenWhenTheAppQuitBecomeNotes() async throws {
        let (processor, store, _) = try processor([.json(ParserResponseTests.clarify), .json(ParserResponseTests.clarify), .json(createAnswer)])
        let open1 = await processor.submit(text: "напомни позвонить Дмитрию", inputKind: .voice)
        let open2 = await processor.submit(text: "созвон с Акме", inputKind: .text)
        let done = await processor.submit(text: "напомни", inputKind: .text)
        #expect(try await store.unfinishedMemos().count == 2)

        // a new run of the app: nobody can answer these any more
        let closed = await processor.closeOrphanedQuestions()
        #expect(closed.count == 2)
        #expect(try await store.unfinishedMemos().isEmpty)
        let notes = try await store.inbox().map(\.title).sorted()
        #expect(notes == ["напомни позвонить Дмитрию", "созвон с Акме"])
        for id in [open1.memo.id, open2.memo.id] { #expect(try await store.memo(id: id)?.status == .applied) }
        #expect(try await store.memo(id: done.memo.id)?.status == .applied)
        #expect(await processor.closeOrphanedQuestions().isEmpty) // nothing left to close
    }

    @Test func discardingAQuestionLeavesNothingBehind() async throws {
        let (processor, store, _) = try processor([.json(ParserResponseTests.clarify), .json(createAnswer)])
        let asked = await processor.submit(text: "напомни позвонить Дмитрию", inputKind: .voice)
        await processor.discard(memoID: asked.memo.id, reason: "cancelled")
        let memo = try #require(try await store.memo(id: asked.memo.id))
        #expect(memo.status == .discarded && memo.failReason == "cancelled")
        #expect(try await store.unfinishedMemos().isEmpty)
        // a finished memo is never rewritten
        let done = await processor.submit(text: "напомни", inputKind: .text)
        await processor.discard(memoID: done.memo.id, reason: "late")
        #expect(try await store.memo(id: done.memo.id)?.status == .applied)
    }

    @Test func correctedWordsAreInterpretedAgain() async throws {
        let (processor, store, provider) = try processor([.fail(.notLoggedIn), .json(createAnswer)])
        let failed = await processor.submit(text: "напомни про доступ в нотиан", inputKind: .voice)
        guard case .failed = failed.kind else { Issue.record("expected failure"); return }
        let fixed = try #require(await processor.editAndRetry(memoID: failed.memo.id, text: "  напомни послезавтра про доступ в Notion "))
        guard case .applied = fixed.kind else { Issue.record("expected applied: \(fixed.kind)"); return }
        let memo = try #require(try await store.memo(id: failed.memo.id))
        #expect(memo.transcriptRaw == "напомни послезавтра про доступ в Notion" && memo.status == .applied && memo.attempts == 0 && memo.failReason == nil)
        #expect(provider.requests.last?.userMessage.contains("<transcript>напомни послезавтра про доступ в Notion</transcript>") == true)
        #expect(await processor.editAndRetry(memoID: failed.memo.id, text: "   ") == nil)
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

    @Test func aPhraseIsMarkedAppliedInTheTransactionOfItsChanges() async throws {
        let (_, store, _) = try processor([])
        try await store.save(memo: Memo(id: "m", createdAt: 1, anchorLocal: "2026-09-28 14:30", tz: "Europe/Moscow",
                                        inputKind: .voice, status: .interpreted, transcriptRaw: "напомни"))
        let plan = MutationPlan(actions: [.create(NewItem(kind: .reminder, title: "Позвонить", date: LocalDate("2026-09-30")))])
        let applied = try await store.apply(plan, source: .voice, memoID: "m", label: "Create entry")
        // No write of the processor's own in between: the row says "applied" the moment the changes are committed.
        let memo = try #require(try await store.memo(id: "m"))
        #expect(memo.status == .applied && memo.opID == applied.op?.id && memo.opID != nil)
    }

    /// The state an older version could leave behind: the changes are in, the phrase still says "interpreted".
    private func landChangesWithoutMarking(_ store: Store, memoID: String) async throws -> Op {
        let landed = try #require(try await store.perform(label: "before the crash", memoID: memoID) { m in
            try m.insert(Item(id: "", kind: .reminder, title: "Уже создано", date: LocalDate("2026-09-30"), source: .voice, memoID: memoID))
        })
        try await store.writer.write { db in
            try db.execute(sql: "UPDATE memos SET status = 'interpreted', op_id = NULL WHERE id = ?", arguments: [memoID])
        }
        return landed
    }

    @Test func aMemoWhoseChangesAlreadyLandedIsNotAppliedTwice() async throws {
        let (processor, store, provider) = try processor([.json(createAnswer)])
        try await store.save(memo: Memo(id: "crashed", createdAt: 1, anchorLocal: "2026-09-28 14:30", tz: "Europe/Moscow",
                                        inputKind: .voice, status: .interpreted, transcriptRaw: "напомни"))
        let landed = try await landChangesWithoutMarking(store, memoID: "crashed")
        let outcomes = await processor.recoverUnfinished()
        #expect(outcomes.count == 1 && provider.requests.isEmpty)
        let memo = try #require(try await store.memo(id: "crashed"))
        #expect(memo.status == .applied && memo.opID == landed.id)
        #expect(try await store.items(on: LocalDate("2026-09-30")!).count == 1)
    }

    @Test func aMemoWhoseChangesWereUndoneIsNotAppliedAgainByRecovery() async throws {
        let (processor, store, provider) = try processor([.json(createAnswer)])
        try await store.save(memo: Memo(id: "crashed", createdAt: 1, anchorLocal: "2026-09-28 14:30", tz: "Europe/Moscow",
                                        inputKind: .voice, status: .interpreted, transcriptRaw: "напомни"))
        let landed = try await landChangesWithoutMarking(store, memoID: "crashed")
        try await store.undo(opID: landed.id) // the person did not want it after all
        #expect(try await store.items(on: LocalDate("2026-09-30")!).isEmpty)
        let outcomes = await processor.recoverUnfinished()
        // The phrase was executed once; that it was undone is not a reason to execute it again.
        #expect(outcomes.count == 1 && provider.requests.isEmpty)
        let memo = try #require(try await store.memo(id: "crashed"))
        #expect(memo.status == .applied && memo.opID == landed.id)
        #expect(try await store.items(on: LocalDate("2026-09-30")!).isEmpty)
    }

    @Test func aQuestionWhoseNoteWasUndoneGetsNoSecondNote() async throws {
        let (processor, store, _) = try processor([])
        try await store.save(memo: Memo(id: "asked", createdAt: 1, anchorLocal: "2026-09-28 14:30", tz: "Europe/Moscow",
                                        inputKind: .voice, status: .clarifying, transcriptRaw: "созвон в пятницу"))
        let first = try #require(await processor.keepAsNote(memoID: "asked"))
        guard case let .applied(result) = first.kind, let op = result.op else { Issue.record("expected the note"); return }
        try await store.writer.write { db in // an older version: the note is in, the phrase still asks
            try db.execute(sql: "UPDATE memos SET status = 'clarifying', op_id = NULL WHERE id = 'asked'")
        }
        try await store.undo(opID: op.id)
        #expect(try await store.inbox().isEmpty)
        let second = try #require(await processor.keepAsNote(memoID: "asked"))
        guard case let .applied(again) = second.kind else { Issue.record("expected it to be closed as dealt with"); return }
        #expect(again.changes.isEmpty && again.op?.id == op.id)
        #expect(try await store.inbox().isEmpty) // the undone note did not come back
    }

    @Test func relativeDatesUseTheMomentTheUserSpokeNotTheRetryTime() async throws {
        let (processor, store, provider) = try processor([.json(createAnswer)])
        try await store.save(memo: Memo(id: "old", createdAt: 1, anchorLocal: "2026-09-20 09:00", tz: "Europe/Moscow",
                                        inputKind: .voice, status: .failed, transcriptRaw: "напомни послезавтра", attempts: 1))
        _ = await processor.retry(memoID: "old")
        #expect(provider.requests.first?.userMessage.contains("<now>Sunday 2026-09-20 09:00 (Europe/Moscow, UTC+03:00)</now>") == true)
        // "послезавтра" (the day after tomorrow) from 2026-09-20 is 2026-09-22
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
