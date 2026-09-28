import Foundation

/// A finished recording on its way through the pipeline.
public struct Utterance: Sendable {
    /// 16 kHz mono Float32.
    public var samples: [Float]
    /// When it was spoken; "tomorrow" counts from here even if recognition and the model take a while.
    public var spokenAt: LocalDateTime?

    public init(samples: [Float], spokenAt: LocalDateTime? = nil) {
        self.samples = samples
        self.spokenAt = spokenAt
    }
}

/// Where a recording is, for a progress display.
public enum UtteranceStage: Equatable, Sendable {
    case transcribing
    case interpreting(String)
}

public struct UtteranceResult: Sendable {
    public enum Kind: Sendable {
        /// Silence, noise or an invented phrase; nothing was stored except a discarded memo.
        case noSpeech(reason: String)
        /// The engine could not run. The recording is kept and transcribed again later.
        case recognitionFailed(String, retryAt: Date?)
        case processed(ProcessOutcome)
    }

    public var kind: Kind
    public var memoID: String
    public var transcript: String?
    public var audioSeconds: Double
    public var sttMs: Int?
    /// True when a question was answered by the local router, without asking Claude.
    public var answeredLocally: Bool
}

/// Recording → text → decision. A recording is written to a spool and a memo is saved *before* recognition,
/// so a missing model or a crash never loses a phrase; once the transcript is stored the audio is deleted.
/// Plain questions ("что на сегодня") are answered by the local router; everything else goes to `MemoProcessor`.
public actor UtteranceProcessor {
    private let recognizer: Recognizer
    private let processor: MemoProcessor
    private let store: Store
    private let spool: AudioSpool
    private let router: LocalIntentRouter
    private let clock: any NowProvider
    private let retryPolicy: RetryPolicy
    private let makeID: @Sendable () -> String
    /// Memos this actor is working on right now. Actor methods interleave at every `await`, so a timer-driven
    /// recovery must not pick up a recording that a live call is still recognising.
    private var inFlight: Set<String> = []

    public init(
        recognizer: Recognizer, processor: MemoProcessor, store: Store, spool: AudioSpool,
        router: LocalIntentRouter = LocalIntentRouter(), clock: any NowProvider = SystemNow(),
        retryPolicy: RetryPolicy = RetryPolicy(delays: [30, 120, 600], maxAttempts: 4),
        makeID: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() }
    ) {
        self.recognizer = recognizer
        self.processor = processor
        self.store = store
        self.spool = spool
        self.router = router
        self.clock = clock
        self.retryPolicy = retryPolicy
        self.makeID = makeID
    }

    public func process(
        _ utterance: Utterance, onStage: @Sendable (UtteranceStage) -> Void = { _ in }
    ) async -> UtteranceResult {
        let anchor = utterance.spokenAt ?? clock.localNow()
        let id = makeID()
        inFlight.insert(id)
        defer { inFlight.remove(id) }
        var memo = Memo(
            id: id, createdAt: nowMs, anchorLocal: "\(anchor.date) \(anchor.time)", tz: clock.timeZone.identifier,
            inputKind: .voice, status: .recorded, durationMs: Int(Double(utterance.samples.count) / 16)
        )
        // If the spool cannot be written the phrase is still handled, just without the crash safety net.
        memo.audioPath = try? spool.write(utterance.samples, name: id)
        try? await store.save(memo: memo)
        return await transcribe(memo, samples: utterance.samples, onStage: onStage)
    }

    /// Picks up recordings that were never transcribed (the app quit, the model was missing) and those due for
    /// another attempt. `includeBlocked` also retries recordings that were waiting for the user to fix something
    /// (for example to install the speech model); do that at launch and on "retry", not on a timer.
    public func recoverUnfinished(
        includeBlocked: Bool, onStage: @Sendable (UtteranceStage) -> Void = { _ in }
    ) async -> [UtteranceResult] {
        guard let memos = try? await store.unfinishedMemos() else { return [] }
        var results: [UtteranceResult] = []
        var keep = Set<String>()
        for memo in memos {
            guard let path = memo.audioPath else { continue }
            guard !inFlight.contains(memo.id) else { keep.insert(path); continue }
            let due: Bool
            switch memo.status {
            case .recorded, .transcribing: due = true
            case .failed where memo.failStage == "stt": due = memo.nextRetryAt.map { $0 <= nowMs } ?? includeBlocked
            default: due = false
            }
            guard due else { keep.insert(path); continue }
            guard let samples = try? spool.read(path: path) else {
                var lost = memo
                lost.status = .discarded
                lost.failReason = "the recording is missing"
                lost.audioPath = nil
                try? await store.save(memo: lost)
                continue
            }
            keep.insert(path)
            inFlight.insert(memo.id)
            results.append(await transcribe(memo, samples: samples, onStage: onStage))
            inFlight.remove(memo.id)
        }
        // Leftovers of finished memos. Files younger than a few minutes may belong to a recording whose memo is
        // still being saved, so they are left alone.
        for path in spool.files(olderThan: 600) where !keep.contains(path) { spool.remove(path: path) }
        return results
    }

    // MARK: - Steps

    private var nowMs: Int64 { Int64(clock.now().timeIntervalSince1970 * 1000) }

    private func transcribe(_ input: Memo, samples: [Float], onStage: @Sendable (UtteranceStage) -> Void) async -> UtteranceResult {
        var memo = input
        let seconds = Double(samples.count) / 16000
        onStage(.transcribing)
        memo.status = .transcribing
        try? await store.save(memo: memo)

        let recognition: Recognition
        do {
            recognition = try await recognizer.recognize(samples)
        } catch {
            return await recognitionFailed(memo, error, seconds: seconds)
        }

        switch recognition {
        case let .noSpeech(reason):
            memo.status = .discarded
            memo.failStage = "stt"
            memo.failReason = reason
            spool.remove(path: memo.audioPath)
            memo.audioPath = nil
            try? await store.save(memo: memo)
            return UtteranceResult(kind: .noSpeech(reason: reason), memoID: memo.id, transcript: nil, audioSeconds: seconds, sttMs: nil, answeredLocally: false)

        case let .speech(output):
            let sttMs = Int(output.processingSeconds * 1000)
            memo.transcriptRaw = output.text
            memo.sttModel = output.model
            memo.sttMs = sttMs
            memo.failStage = nil
            memo.failReason = nil
            memo.nextRetryAt = nil
            memo.status = .transcribed
            spool.remove(path: memo.audioPath)
            memo.audioPath = nil
            try? await store.save(memo: memo)

            onStage(.interpreting(output.text))
            let anchor = MemoProcessor.parseAnchor(memo.anchorLocal) ?? clock.localNow()
            if let plan = router.route(output.text, today: anchor.date) {
                let outcome = await processor.answerLocally(memo: memo, plan: plan)
                return UtteranceResult(
                    kind: .processed(outcome), memoID: memo.id, transcript: output.text, audioSeconds: seconds, sttMs: sttMs, answeredLocally: true
                )
            }
            let outcome = await processor.retry(memoID: memo.id)
                ?? ProcessOutcome(memo: memo, kind: .failed(.processFailed(exitCode: -1, stderr: "memo vanished"), retryAt: nil), interpretation: nil)
            return UtteranceResult(
                kind: .processed(outcome), memoID: memo.id, transcript: output.text, audioSeconds: seconds, sttMs: sttMs, answeredLocally: false
            )
        }
    }

    private func recognitionFailed(_ input: Memo, _ error: any Error, seconds: Double) async -> UtteranceResult {
        var memo = input
        memo.status = .failed
        memo.failStage = "stt"
        memo.failReason = "\(error)"
        memo.attempts += 1
        var retryAt: Date?
        let needsUser: Bool
        if case .modelMissing? = error as? TranscriberError { needsUser = true } else { needsUser = false }
        if !needsUser, let delay = retryPolicy.delay(afterAttempts: memo.attempts) {
            retryAt = clock.now().addingTimeInterval(delay)
            memo.nextRetryAt = Int64(retryAt!.timeIntervalSince1970 * 1000)
        } else {
            memo.nextRetryAt = nil
        }
        try? await store.save(memo: memo)
        return UtteranceResult(
            kind: .recognitionFailed("\(error)", retryAt: retryAt), memoID: memo.id, transcript: nil, audioSeconds: seconds, sttMs: nil, answeredLocally: false
        )
    }
}
