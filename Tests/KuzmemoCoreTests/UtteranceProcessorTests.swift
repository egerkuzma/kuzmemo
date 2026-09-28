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
    return Rig(utterances: utterances, store: store, spool: spool, provider: provider, directory: directory)
}

@Suite("UtteranceProcessor")
struct UtteranceProcessorTests {
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

        guard case let .recognitionFailed(message, retryAt) = first.kind else { Issue.record("expected failure: \(first.kind)"); return }
        #expect(message.contains("ANE busy") && retryAt == Date(timeIntervalSince1970: 1_790_595_030)) // 30 s later
        let failed = try #require(try await r.store.memo(id: first.memoID))
        #expect(failed.status == .failed && failed.failStage == "stt" && failed.attempts == 1 && failed.nextRetryAt == 1_790_595_030_000)
        #expect(failed.audioPath != nil && r.spool.files().count == 1)

        // Not due yet: a timer-driven recovery leaves it alone.
        #expect(await r.utterances.recoverUnfinished(includeBlocked: false).isEmpty)
        #expect(stt.callCount == 1)
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

    @Test func aMissingModelWaitsForTheUser() async throws {
        let stt = ScriptedTranscriber([.fail(.modelMissing("/nowhere")), .reply("напомни позвонить")])
        let r = try rig(stt: stt)
        defer { try? FileManager.default.removeItem(at: r.directory) }
        let first = await r.utterances.process(Utterance(samples: recording()))
        guard case let .recognitionFailed(_, retryAt) = first.kind else { Issue.record("expected failure"); return }
        #expect(retryAt == nil)
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
