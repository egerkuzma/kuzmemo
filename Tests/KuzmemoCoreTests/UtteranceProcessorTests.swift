import Foundation
import Synchronization
import Testing
@testable import KuzmemoCore

private let moscow = TimeZone(identifier: "Europe/Moscow")!

/// Speech-like audio: a tone with syllable-rate modulation, surrounded by silence like a real recording.
private func recording(_ seconds: Double = 1.5) -> [Float] {
    let tone = (0 ..< Int(seconds * 16000)).map { i -> Float in
        let t = Double(i) / 16000
        return Float(sin(2 * .pi * 180 * t) * 0.25 * (0.55 + 0.45 * sin(2 * .pi * 4 * t)))
    }
    return [Float](repeating: 0, count: 16000) + tone + [Float](repeating: 0, count: 16000)
}

/// A transcriber that answers from a script, so a test can make the engine fail and then recover.
private final class ScriptedTranscriber: Transcriber, Sendable {
    enum Step: Sendable {
        case reply(String)
        case fail(TranscriberError)
    }

    let modelName = "scripted-stt"
    private let steps: Mutex<[Step]>
    private let calls = Mutex(0)

    init(_ steps: [Step]) { self.steps = Mutex(steps) }

    var callCount: Int { calls.withLock { $0 } }
    func prepare() async throws {}
    func unload() async {}
    func transcribe(_ samples: [Float]) async throws -> TranscriptionOutput {
        calls.withLock { $0 += 1 }
        let step = steps.withLock { $0.isEmpty ? Step.reply("") : $0.removeFirst() }
        switch step {
        case let .reply(text):
            return TranscriptionOutput(text: text, language: "ru", audioSeconds: Double(samples.count) / 16000, processingSeconds: 0.25, model: modelName)
        case let .fail(error):
            throw error
        }
    }
}

private final class BlockingTranscriber: Transcriber, Sendable {
    let modelName = "blocking-stt"
    let gate = Gate()
    private let calls = Mutex(0)
    var callCount: Int { calls.withLock { $0 } }
    func prepare() async throws {}
    func unload() async {}
    func transcribe(_ samples: [Float]) async throws -> TranscriptionOutput {
        calls.withLock { $0 += 1 }
        await gate.wait()
        return TranscriptionOutput(text: "напомни позвонить", language: "ru", audioSeconds: 1, processingSeconds: 0.1, model: modelName)
    }
}

private struct Rig {
    var utterances: UtteranceProcessor
    var processorForTests: MemoProcessor
    var store: Store
    var spool: AudioSpool
    var provider: ScriptedProvider
    var directory: URL
}

private func rig(
    stt: any Transcriber, claude: [ScriptedProvider.Step] = [.json(ParserResponseTests.create)], now: String = "2026-09-28 14:30",
    sttRetry: RetryPolicy = RetryPolicy(delays: [30, 120, 600], maxAttempts: 4)
) throws -> Rig {
    let store = try makeStore(now: now)
    let provider = ScriptedProvider(claude)
    let clock = FixedNow(local: now, in: moscow)!
    let ids = IDSequence()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kuzmemo-spool-\(UUID().uuidString)", isDirectory: true)
    let spool = AudioSpool(directory: directory)
    let processor = MemoProcessor(store: store, interpreter: Interpreter(store: store, provider: provider), clock: clock, makeID: { "m" + ids.next() })
    let utterances = UtteranceProcessor(
        recognizer: Recognizer(transcriber: stt), processor: processor, store: store, spool: spool, clock: clock,
        retryPolicy: sttRetry, makeID: { "u" + ids.next() }
    )
    return Rig(utterances: utterances, processorForTests: processor, store: store, spool: spool, provider: provider, directory: directory)
}

/// A memo that asked a clarifying question, made by speaking `phrase` (the first scripted model answer must be a question).
private func askingMemo(_ r: Rig, phrase: String) async throws -> String {
    let asked = await r.processorForTests.submit(text: phrase, inputKind: .voice)
    guard case .clarify = asked.kind else { throw Skip("the first scripted answer was not a question") }
    return asked.memo.id
}

private struct Skip: Error { let message: String; init(_ message: String) { self.message = message } }

@Suite("UtteranceProcessor")
struct UtteranceProcessorTests {
    /// Erasing everything while a recording is being recognised: the recognised words used to be saved into a memo made anew, and
    /// the phrase went on to the model and into the calendar.
    @Test func anEraseWhileARecordingIsBeingRecognisedLeavesNothingBehind() async throws {
        let stt = BlockingTranscriber()
        let r = try rig(stt: stt)
        defer { try? FileManager.default.removeItem(at: r.directory) }
        let live = Task { await r.utterances.process(Utterance(samples: recording())) }
        while stt.callCount == 0 { try await Task.sleep(for: .milliseconds(10)) }

        try await r.store.eraseEntriesAndHistory()
        await stt.gate.open()
        _ = await live.value

        #expect(try await r.store.overview() == DataOverview(entries: 0, memos: 0, undoSteps: 0, glossaryTerms: 0))
        #expect(r.provider.requests.isEmpty, "the erased phrase was sent to the model")
    }

    @Test func spokenPhraseGoesToClaudeAndTheRecordingIsDeleted() async throws {
        let r = try rig(stt: ScriptedTranscriber([.reply("напомни мне послезавтра сказать Дмитрию про доступ в Нотион")]))
        defer { try? FileManager.default.removeItem(at: r.directory) }
        let result = await r.utterances.process(Utterance(samples: recording()))

        guard case let .processed(outcome) = result.kind, case let .applied(applied) = outcome.kind else {
            Issue.record("expected an applied change: \(result.kind)"); return
        }
        #expect(applied.changes.count == 1 && !result.answeredLocally)
        #expect(result.transcript == "напомни мне послезавтра сказать Дмитрию про доступ в Нотион")
        #expect(try await r.store.items(on: LocalDate("2026-09-30")!).first?.source == .voice)

        let memo = try #require(try await r.store.memo(id: result.memoID))
        #expect(memo.status == .applied && memo.inputKind == .voice && memo.sttModel == "scripted-stt" && memo.sttMs == 250)
        #expect(memo.audioPath == nil && r.spool.files().isEmpty)
        #expect(memo.durationMs == 3500 && memo.anchorLocal == "2026-09-28 14:30")
    }

    @Test func plainQuestionsAreAnsweredWithoutAskingTheModel() async throws {
        let r = try rig(stt: ScriptedTranscriber([.reply("Скажи, что на сегодня")]), claude: [])
        defer { try? FileManager.default.removeItem(at: r.directory) }
        let result = await r.utterances.process(Utterance(samples: recording()))

        guard case let .processed(outcome) = result.kind, case .answered = outcome.kind else {
            Issue.record("expected an answer: \(result.kind)"); return
        }
        #expect(result.answeredLocally && r.provider.requests.isEmpty)
        let memo = try #require(try await r.store.memo(id: result.memoID))
        #expect(memo.status == .answered && memo.llmModel == "local-router" && memo.transcriptRaw == "Скажи, что на сегодня")
    }

    /// The transcript is written before the recording is deleted. When the write fails, the recording must survive and the
    /// memo must stay where recovery finds it; the old order deleted the audio first, so a failed write lost the phrase.
    @Test func aTranscriptThatCannotBeStoredDoesNotCostTheRecording() async throws {
        let r = try rig(stt: ScriptedTranscriber([.reply("напомни мне послезавтра сказать Дмитрию про доступ в Нотион"), .reply("напомни мне послезавтра сказать Дмитрию про доступ в Нотион")]))
        defer { try? FileManager.default.removeItem(at: r.directory) }
        // the store refuses to record a transcript, as a full disk would
        try await r.store.writer.write { db in
            try db.execute(sql: "CREATE TRIGGER refuse_transcripts BEFORE UPDATE ON memos WHEN NEW.status = 'transcribed' BEGIN SELECT RAISE(ABORT, 'disk full'); END")
        }
        let result = await r.utterances.process(Utterance(samples: recording()))
        guard case let .recognitionFailed(message, needsUser, retryAt) = result.kind else { Issue.record("expected a failure: \(result.kind)"); return }
        #expect(message.contains("could not be stored") && !needsUser && retryAt != nil)
        #expect(r.spool.files().count == 1, "the recording must still be there")
        let waiting = try #require(try await r.store.memo(id: result.memoID))
        #expect(waiting.status == .transcribing && waiting.audioPath != nil && waiting.transcriptRaw == nil)

        // the store works again: recovery recognises the kept recording and the phrase goes through
        try await r.store.writer.write { db in try db.execute(sql: "DROP TRIGGER refuse_transcripts") }
        let recovered = await r.utterances.recoverUnfinished(includeBlocked: false)
        #expect(recovered.count == 1)
        guard case let .processed(outcome)? = recovered.first?.kind, case .applied = outcome.kind else { Issue.record("expected the phrase to be applied: \(String(describing: recovered.first?.kind))"); return }
        #expect(r.spool.files().isEmpty)
    }

    /// The list of unfinished recordings is read once, and recognising one takes a while. A recording that something else has
    /// finished by its turn must be left alone: the stale copy used to be saved as "the recording is missing" over the
    /// finished memo and wiped its transcript.
    @Test func recoveryLeavesAMemoThatWasFinishedMeanwhile() async throws {
        let stt = BlockingTranscriber()
        let r = try rig(stt: stt, claude: [.json(ParserResponseTests.create), .json(ParserResponseTests.create)])
        defer { try? FileManager.default.removeItem(at: r.directory) }
        func memo(_ id: String, at: Int64, path: String?) -> Memo {
            Memo(id: id, createdAt: at, anchorLocal: "2026-09-28 14:30", tz: "Europe/Moscow", inputKind: .voice,
                 status: .recorded, audioPath: path)
        }
        let firstPath = try r.spool.write(recording(), name: "first")
        let secondPath = try r.spool.write(recording(), name: "second")
        try await r.store.save(memo: memo("first", at: 1, path: firstPath))
        try await r.store.save(memo: memo("second", at: 2, path: secondPath))

        let recovery = Task { await r.utterances.recoverUnfinished(includeBlocked: false) }
        while stt.callCount == 0 { try await Task.sleep(for: .milliseconds(10)) }
        // while the first is being recognised, the second is finished by someone else and its recording is deleted
        var finished = memo("second", at: 2, path: nil)
        finished.status = .applied
        finished.transcriptRaw = "напомни позвонить"
        try await r.store.save(memo: finished)
        r.spool.remove(path: secondPath)
        await stt.gate.open()
        _ = await recovery.value

        let kept = try #require(try await r.store.memo(id: "second"))
        #expect(kept.status == .applied && kept.transcriptRaw == "напомни позвонить", "the finished memo was overwritten: \(kept.status) \(kept.failReason ?? "")")
    }

    @Test func silenceIsDiscardedAndNeverReachesTheEngine() async throws {
        let stt = ScriptedTranscriber([.reply("Продолжение следует...")])
        let r = try rig(stt: stt, claude: [])
        defer { try? FileManager.default.removeItem(at: r.directory) }
        let result = await r.utterances.process(Utterance(samples: [Float](repeating: 0, count: 48000)))

        guard case .noSpeech = result.kind else { Issue.record("expected noSpeech: \(result.kind)"); return }
        #expect(stt.callCount == 0)
        let memo = try #require(try await r.store.memo(id: result.memoID))
        #expect(memo.status == .discarded && memo.audioPath == nil && r.spool.files().isEmpty)
    }

    @Test func aninventedPhraseIsDiscardedToo() async throws {
        let r = try rig(stt: ScriptedTranscriber([.reply("Субтитры сделал DimaTorzok")]), claude: [])
        defer { try? FileManager.default.removeItem(at: r.directory) }
        let result = await r.utterances.process(Utterance(samples: recording()))
        guard case let .noSpeech(reason) = result.kind else { Issue.record("expected noSpeech: \(result.kind)"); return }
        #expect(reason.contains("DimaTorzok") && r.provider.requests.isEmpty)
    }

    @Test func aFailingEngineSchedulesAnotherAttempt() async throws {
        let stt = ScriptedTranscriber([.fail(.transcriptionFailed("ANE busy"))])
        let r = try rig(stt: stt)
        defer { try? FileManager.default.removeItem(at: r.directory) }
        let first = await r.utterances.process(Utterance(samples: recording()))

        guard case let .recognitionFailed(message, needsUser, retryAt) = first.kind else { Issue.record("expected failure: \(first.kind)"); return }
        #expect(message.contains("ANE busy") && !needsUser && retryAt == Date(timeIntervalSince1970: 1_790_595_030)) // 30 s later
        let failed = try #require(try await r.store.memo(id: first.memoID))
        #expect(failed.status == .failed && failed.failStage == "stt" && failed.attempts == 1 && failed.nextRetryAt == 1_790_595_030_000)
        #expect(failed.audioPath != nil && r.spool.files().count == 1 && first.recordingKept)

        // Not due yet: a timer-driven recovery leaves it alone.
        #expect(await r.utterances.recoverUnfinished(includeBlocked: false).isEmpty)
        #expect(stt.callCount == 1)
    }

    /// The spool cannot be written (a full disk, a folder in the way): the phrase is still recognised and handled, and the failure
    /// is said, instead of a silent promise that the recording is safe.
    @Test func aRecordingThatCannotBeKeptIsStillProcessedAndTheFailureIsReported() async throws {
        let r = try rig(stt: ScriptedTranscriber([.reply("напомни позвонить"), .fail(.transcriptionFailed("ANE busy"))]))
        defer { try? FileManager.default.removeItem(at: r.directory) }
        try FileManager.default.createDirectory(at: r.directory.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("in the way".utf8).write(to: r.directory) // a file where the spool folder should be

        let admitted = await r.utterances.admit(Utterance(samples: recording()))
        #expect(admitted.failure?.contains("spool") == true && admitted.memo.audioPath == nil)
        #expect(try await r.store.memo(id: admitted.memo.id)?.status == .recorded) // the database write worked, the phrase is there
        let result = await r.utterances.process(admitted: admitted.memo, samples: recording())
        guard case let .processed(outcome) = result.kind, case .applied = outcome.kind else { Issue.record("expected applied: \(result.kind)"); return }

        // a recognition that fails without the audio on disk says so: there is nothing to try again with
        let second = await r.utterances.process(Utterance(samples: recording()))
        guard case .recognitionFailed = second.kind else { Issue.record("expected failure: \(second.kind)"); return }
        #expect(!second.recordingKept)
    }

    @Test func aFailedRecognitionIsRetriedWhenDueAndThenFlowsOn() async throws {
        let stt = ScriptedTranscriber([.fail(.loadFailed("compiling")), .reply("напомни позвонить")])
        let r = try rig(stt: stt, sttRetry: RetryPolicy(delays: [0], maxAttempts: 4)) // "due" as soon as it is scheduled
        defer { try? FileManager.default.removeItem(at: r.directory) }
        let first = await r.utterances.process(Utterance(samples: recording()))
        guard case .recognitionFailed = first.kind else { Issue.record("expected failure: \(first.kind)"); return }

        let recovered = await r.utterances.recoverUnfinished(includeBlocked: false)
        let second = try #require(recovered.first)
        guard case let .processed(outcome) = second.kind, case .applied = outcome.kind else {
            Issue.record("expected the phrase to be applied: \(second.kind)"); return
        }
        let done = try #require(try await r.store.memo(id: first.memoID))
        #expect(done.status == .applied && done.audioPath == nil && done.failStage == nil && r.spool.files().isEmpty)
        #expect(done.attempts == 1 && stt.callCount == 2)
    }

    @Test func retryingARecordingTranscribesItNow() async throws {
        let stt = ScriptedTranscriber([.fail(.modelMissing("/nowhere")), .reply("напомни позвонить")])
        let r = try rig(stt: stt)
        defer { try? FileManager.default.removeItem(at: r.directory) }
        let first = await r.utterances.process(Utterance(samples: recording()))
        guard case .recognitionFailed = first.kind else { Issue.record("expected failure"); return }

        let again = try #require(await r.utterances.retry(memoID: first.memoID))
        guard case let .processed(outcome) = again.kind, case .applied = outcome.kind else { Issue.record("expected applied: \(again.kind)"); return }
        #expect(try await r.store.memo(id: first.memoID)?.status == .applied && r.spool.files().isEmpty)
        #expect(await r.utterances.retry(memoID: first.memoID) == nil) // nothing left to retry
    }

    @Test func aMissingModelWaitsForTheUser() async throws {
        let stt = ScriptedTranscriber([.fail(.modelMissing("/nowhere")), .reply("напомни позвонить")])
        let r = try rig(stt: stt)
        defer { try? FileManager.default.removeItem(at: r.directory) }
        let first = await r.utterances.process(Utterance(samples: recording()))
        guard case let .recognitionFailed(_, needsUser, retryAt) = first.kind else { Issue.record("expected failure"); return }
        #expect(needsUser && retryAt == nil)
        #expect(try await r.store.memo(id: first.memoID)?.nextRetryAt == nil)

        #expect(await r.utterances.recoverUnfinished(includeBlocked: false).isEmpty) // a timer does not hammer a missing model
        #expect(await r.utterances.recoverUnfinished(includeBlocked: true).count == 1) // launch or "retry" does
    }

    @Test func aRecordingLeftByACrashIsTranscribedAfterRestart() async throws {
        let r = try rig(stt: ScriptedTranscriber([.reply("напомни позвонить")]))
        defer { try? FileManager.default.removeItem(at: r.directory) }
        // What the previous run left behind: a memo in `recorded` and its audio.
        let path = try r.spool.write(recording(), name: "crashed")
        try await r.store.save(memo: Memo(
            id: "crashed", createdAt: 1_790_594_000_000, anchorLocal: "2026-09-28 14:29", tz: "Europe/Moscow",
            inputKind: .voice, status: .recorded, audioPath: path, durationMs: 3500
        ))

        let results = await r.utterances.recoverUnfinished(includeBlocked: false)
        #expect(results.count == 1 && results[0].memoID == "crashed")
        let memo = try #require(try await r.store.memo(id: "crashed"))
        #expect(memo.status == .applied && memo.anchorLocal == "2026-09-28 14:29" && r.spool.files().isEmpty)
    }

    /// A recording that waits its turn behind another one is on disk and in the database from the moment it was admitted, and a
    /// recovery pass that runs meanwhile leaves it to the worker that will process it.
    @Test func anAdmittedRecordingIsSavedBeforeItsTurnComes() async throws {
        let r = try rig(stt: ScriptedTranscriber([.reply("напомни позвонить")]))
        defer { try? FileManager.default.removeItem(at: r.directory) }
        let spokenAt = LocalDateTime(date: LocalDate("2026-09-28")!, time: LocalTime("14:29")!)
        let admitted = await r.utterances.admit(Utterance(samples: recording(), spokenAt: spokenAt))
        let memo = admitted.memo
        #expect(admitted.failure == nil)
        let saved = try #require(try await r.store.memo(id: memo.id))
        #expect(saved.status == .recorded && saved.anchorLocal == "2026-09-28 14:29" && saved.audioPath == memo.audioPath)
        #expect(r.spool.files().count == 1)
        #expect(try r.spool.read(path: memo.audioPath ?? "").count == recording().count)
        #expect(await r.utterances.recoverUnfinished(includeBlocked: true).isEmpty) // claimed: not recognised twice
        #expect(r.spool.files().count == 1)

        let result = await r.utterances.process(admitted: memo, samples: recording())
        guard case let .processed(outcome) = result.kind, case .applied = outcome.kind else { Issue.record("expected applied: \(result.kind)"); return }
        #expect(result.memoID == memo.id && r.spool.files().isEmpty && r.provider.requests.count == 1)
    }

    /// The app quit (or crashed) with a recording still waiting in the queue: the next launch recognises it, once.
    @Test func anAdmittedRecordingThatNeverGotItsTurnIsRecognisedAtTheNextLaunch() async throws {
        let r = try rig(stt: ScriptedTranscriber([.reply("напомни позвонить")]))
        defer { try? FileManager.default.removeItem(at: r.directory) }
        let memo = await r.utterances.admit(Utterance(samples: recording())).memo
        // the next launch: a processor of its own over the same database and spool
        let relaunched = UtteranceProcessor(
            recognizer: Recognizer(transcriber: ScriptedTranscriber([.reply("напомни позвонить")])), processor: r.processorForTests,
            store: r.store, spool: r.spool, clock: FixedNow(local: "2026-09-28 14:35", in: moscow)!
        )
        let results = await relaunched.recoverUnfinished(includeBlocked: true)
        #expect(results.count == 1 && results[0].memoID == memo.id)
        #expect(try await r.store.memo(id: memo.id)?.status == .applied && r.spool.files().isEmpty)
        #expect(await relaunched.recoverUnfinished(includeBlocked: true).isEmpty) // and not a second time
    }

    @Test func aMissingRecordingIsGivenUpOn() async throws {
        let r = try rig(stt: ScriptedTranscriber([]), claude: [])
        defer { try? FileManager.default.removeItem(at: r.directory) }
        try await r.store.save(memo: Memo(
            id: "lost", createdAt: 1, anchorLocal: "2026-09-28 14:29", tz: "Europe/Moscow", inputKind: .voice,
            status: .recorded, audioPath: r.directory.appendingPathComponent("nothing.f32").path
        ))
        #expect(await r.utterances.recoverUnfinished(includeBlocked: true).isEmpty)
        #expect(try await r.store.memo(id: "lost")?.status == .discarded)
    }

    @Test func recoveryLeavesARecordingThatIsBeingRecognisedAlone() async throws {
        let stt = BlockingTranscriber()
        let r = try rig(stt: stt)
        defer { try? FileManager.default.removeItem(at: r.directory) }
        let live = Task { await r.utterances.process(Utterance(samples: recording())) }
        while stt.callCount == 0 { try await Task.sleep(for: .milliseconds(10)) }

        #expect(await r.utterances.recoverUnfinished(includeBlocked: true).isEmpty) // the timer fires mid-recognition
        #expect(stt.callCount == 1 && r.spool.files().count == 1)

        await stt.gate.open()
        let result = await live.value
        guard case let .processed(outcome) = result.kind, case .applied = outcome.kind else {
            Issue.record("expected applied: \(result.kind)"); return
        }
        #expect(stt.callCount == 1 && r.provider.requests.count == 1)
    }

    @Test func aSpokenAnswerContinuesTheConversationAndSkipsTheRouter() async throws {
        // "завтра" ("tomorrow") alone would be the question "что на завтра" ("what is on tomorrow") to the router; as an
        // answer it is a date.
        let r = try rig(stt: ScriptedTranscriber([.reply("завтра")]), claude: [.json(ParserResponseTests.clarify), .json(ParserResponseTests.create)])
        defer { try? FileManager.default.removeItem(at: r.directory) }
        let asker = try await askingMemo(r, phrase: "напомни позвонить Дмитрию")

        let result = await r.utterances.process(Utterance(samples: recording()), replyTo: Reply(memoID: asker, question: "На какую дату напомнить?"))
        guard case let .processed(outcome) = result.kind, case .applied = outcome.kind else {
            Issue.record("expected applied: \(result.kind)"); return
        }
        #expect(!result.answeredLocally)
        let message = try #require(r.provider.requests.last?.userMessage)
        #expect(message.contains("<previous>напомни позвонить Дмитрию</previous>") && message.contains("<transcript>завтра</transcript>"))
        let memo = try #require(try await r.store.memo(id: result.memoID))
        #expect(memo.parentMemoID == asker && memo.followupQuestion == "На какую дату напомнить?" && memo.anchorLocal == "2026-09-28 14:30")
        #expect(try await r.store.memo(id: asker)?.status == .superseded)
    }

    @Test func anAnswerWithoutSpeechLeavesTheQuestionOpen() async throws {
        let r = try rig(stt: ScriptedTranscriber([]), claude: [.json(ParserResponseTests.clarify)])
        defer { try? FileManager.default.removeItem(at: r.directory) }
        let asker = try await askingMemo(r, phrase: "напомни позвонить Дмитрию")
        let result = await r.utterances.process(Utterance(samples: [Float](repeating: 0, count: 48000)), replyTo: Reply(memoID: asker, question: "?"))
        guard case .noSpeech = result.kind else { Issue.record("expected noSpeech: \(result.kind)"); return }
        #expect(try await r.store.memo(id: asker)?.status == .clarifying) // the app can still save it as a note
    }

    @Test func anAnswerThatCannotBeRecognisedIsNotResumedLater() async throws {
        let r = try rig(stt: ScriptedTranscriber([.fail(.transcriptionFailed("busy"))]), claude: [.json(ParserResponseTests.clarify)])
        defer { try? FileManager.default.removeItem(at: r.directory) }
        let asker = try await askingMemo(r, phrase: "напомни позвонить Дмитрию")
        let result = await r.utterances.process(Utterance(samples: recording()), replyTo: Reply(memoID: asker, question: "?"))
        guard case let .recognitionFailed(_, _, retryAt) = result.kind else { Issue.record("expected failure: \(result.kind)"); return }
        #expect(retryAt == nil)
        let memo = try #require(try await r.store.memo(id: result.memoID))
        #expect(memo.status == .discarded && memo.audioPath == nil && r.spool.files().isEmpty)
        #expect(try await r.store.memo(id: asker)?.status == .clarifying)
    }

    @Test func progressIsReportedInOrder() async throws {
        let r = try rig(stt: ScriptedTranscriber([.reply("напомни позвонить")]))
        defer { try? FileManager.default.removeItem(at: r.directory) }
        let stages = Mutex<[UtteranceStage]>([])
        _ = await r.utterances.process(Utterance(samples: recording())) { stage in stages.withLock { $0.append(stage) } }
        #expect(stages.withLock { $0 } == [.transcribing, .interpreting("напомни позвонить")])
    }

    @Test func aSlowRecognitionStillResolvesDatesFromWhenItWasSpoken() async throws {
        let r = try rig(stt: ScriptedTranscriber([.reply("напомни позвонить")]), now: "2026-09-28 23:58")
        defer { try? FileManager.default.removeItem(at: r.directory) }
        let spoken = LocalDateTime(date: LocalDate("2026-09-28")!, time: LocalTime("23:50")!)
        let result = await r.utterances.process(Utterance(samples: recording(), spokenAt: spoken))
        let memo = try #require(try await r.store.memo(id: result.memoID))
        #expect(memo.anchorLocal == "2026-09-28 23:50")
    }
}

extension UtteranceProcessorTests {
    @Test func anUnkeptAdmissionCanBeSavedAfterItsWorkerFailsWithoutMakingAnotherMemo() async throws {
        let r = try rig(stt: ScriptedTranscriber([.fail(.transcriptionFailed("busy"))]))
        defer { try? FileManager.default.removeItem(at: r.directory) }
        try Data("not a folder".utf8).write(to: r.directory)
        let samples = recording()
        let admitted = await r.utterances.admit(Utterance(samples: samples))
        #expect(admitted.failure != nil)
        _ = await r.utterances.process(admitted: admitted.memo, samples: samples)
        #expect(await r.utterances.isKept(memoID: admitted.memo.id) == false)
        try FileManager.default.removeItem(at: r.directory)
        try await r.utterances.keepAfterFailure(admitted.memo, samples: samples)
        #expect(await r.utterances.isKept(memoID: admitted.memo.id))
        let kept = try #require(try await r.store.memo(id: admitted.memo.id))
        #expect(kept.status == .failed && kept.audioPath != nil)
        #expect(try r.spool.read(path: kept.audioPath!) == samples)
        #expect(try await r.store.overview().memos == 1)
        try await r.utterances.keepAfterFailure(admitted.memo, samples: samples)
        #expect(try await r.store.overview().memos == 1 && r.spool.files().count == 1)
    }

    @Test func aLateAdmissionRetryNeverResurrectsErasedMemos() async throws {
        let r = try rig(stt: ScriptedTranscriber([.fail(.transcriptionFailed("busy"))]))
        defer { try? FileManager.default.removeItem(at: r.directory) }
        try Data("not a folder".utf8).write(to: r.directory)
        let samples = recording()
        let admitted = await r.utterances.admit(Utterance(samples: samples))
        _ = await r.utterances.process(admitted: admitted.memo, samples: samples)
        try await r.store.eraseEntriesAndHistory()
        try FileManager.default.removeItem(at: r.directory)
        try await r.utterances.keepAfterFailure(admitted.memo, samples: samples)
        #expect(try await r.store.memo(id: admitted.memo.id) == nil)
        #expect(r.spool.files().isEmpty)
    }
}
