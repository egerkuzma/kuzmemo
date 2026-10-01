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

/// A recording that answers a clarifying question the app asked.
public struct Reply: Equatable, Sendable {
    /// The memo that asked (it is `clarifying` until the answer has been recognised).
    public var memoID: String
    public var question: String

    public init(memoID: String, question: String) {
        self.memoID = memoID
        self.question = question
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
        /// The engine could not run. The recording is kept and transcribed again later; `needsUser` means it will
        /// not be retried on its own (the speech model is not installed).
        case recognitionFailed(String, needsUser: Bool, retryAt: Date?)
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
        _ utterance: Utterance, replyTo reply: Reply? = nil, onStage: @Sendable (UtteranceStage) -> Void = { _ in }
    ) async -> UtteranceResult {
        let spoken = utterance.spokenAt ?? clock.localNow()
        var anchorText = "\(spoken.date) \(spoken.time)"
        var timeZone = clock.timeZone.identifier
        if let reply, let asker = try? await store.memo(id: reply.memoID) {
            anchorText = asker.anchorLocal // relative dates in the answer count from the original phrase
            timeZone = asker.tz
        }
        let id = makeID()
        inFlight.insert(id)
        defer { inFlight.remove(id) }
        var memo = Memo(
            id: id, createdAt: nowMs, anchorLocal: anchorText, tz: timeZone,
            inputKind: .voice, status: .recorded, durationMs: Int(Double(utterance.samples.count) / 16),
            parentMemoID: reply?.memoID, followupQuestion: reply?.question
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
        for listed in memos where listed.audioPath != nil {
            guard inFlight.insert(listed.id).inserted else { continue }
            defer { inFlight.remove(listed.id) }
            // The list was read before the loop began, and recognising a recording takes a while: by the time a memo's turn
            // comes, a live call may have finished it. The memo as it is now decides (the stale copy once overwrote a
            // finished memo with "the recording is missing" and wiped its transcript).
            guard let memo = try? await store.memo(id: listed.id), let path = memo.audioPath else { continue }
            let due: Bool
            switch memo.status {
            case .recorded, .transcribing: due = true
            case .failed where memo.failStage == "stt": due = memo.nextRetryAt.map { $0 <= nowMs } ?? includeBlocked
            default: due = false
            }
            guard due else { continue }
            guard let samples = try? spool.read(path: path) else {
                var lost = memo
                lost.status = .discarded
                lost.failReason = "the recording is missing"
                lost.audioPath = nil
                try? await store.save(memo: lost)
                continue
            }
            results.append(await transcribe(memo, samples: samples, onStage: onStage))
        }
        // Leftovers of finished memos. Files younger than a few minutes may belong to a recording whose memo is
        // still being saved, so they are left alone; what still belongs to a memo is read again here, not taken from the
        // list above (which is old by now), and nothing is swept when it cannot be read.
        guard let current = try? await store.unfinishedMemos() else { return results }
        let wanted = Set(current.compactMap(\.audioPath))
        for path in spool.files(olderThan: 600) where !wanted.contains(path) { spool.remove(path: path) }
        return results
    }

    /// "Retry" on a recording whose recognition failed: transcribe the kept audio now.
    public func retry(
        memoID: String, onStage: @Sendable (UtteranceStage) -> Void = { _ in }
    ) async -> UtteranceResult? {
        guard inFlight.insert(memoID).inserted else { return nil } // claimed before the first await
        defer { inFlight.remove(memoID) }
        guard let memo = try? await store.memo(id: memoID), memo.status == .failed || memo.status == .recorded,
              let path = memo.audioPath, let samples = try? spool.read(path: path) else { return nil }
        return await transcribe(memo, samples: samples, onStage: onStage)
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
            recognition = try await recognizer.recognize(samples, isReply: memo.parentMemoID != nil)
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
            // The transcript is stored first and the recording deleted only once that has worked: a failed write (a full
            // disk, a lock that timed out) used to leave a memo without its text and without its audio, and recovery then
            // discarded the phrase. Now the recording stays, the memo stays "transcribing", and recovery recognises it again.
            let recording = memo.audioPath
            memo.audioPath = nil
            do {
                try await store.save(memo: memo)
            } catch {
                let delay = retryPolicy.delay(afterAttempts: memo.attempts + 1) ?? 30
                return UtteranceResult(
                    kind: .recognitionFailed("the transcript could not be stored: \(error)", needsUser: false, retryAt: clock.now().addingTimeInterval(delay)),
                    memoID: memo.id, transcript: nil, audioSeconds: seconds, sttMs: nil, answeredLocally: false
                )
            }
            spool.remove(path: recording)

            if let asker = memo.parentMemoID { await processor.supersede(asker) } // the answer carries the phrase on
            onStage(.interpreting(output.text))
            let anchor = MemoProcessor.parseAnchor(memo.anchorLocal) ?? clock.localNow()
            // An answer such as "завтра" ("tomorrow") must not be mistaken for the question "что на завтра" ("what is on tomorrow").
            if memo.parentMemoID == nil, let plan = router.route(output.text, today: anchor.date) {
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
        if memo.parentMemoID != nil {
            // An answer that could not be recognised is not worth resuming later: the conversation has moved on.
            memo.status = .discarded
            spool.remove(path: memo.audioPath)
            memo.audioPath = nil
            memo.nextRetryAt = nil
        } else if !needsUser, let delay = retryPolicy.delay(afterAttempts: memo.attempts) {
            retryAt = clock.now().addingTimeInterval(delay)
            memo.nextRetryAt = Int64(retryAt!.timeIntervalSince1970 * 1000)
        } else {
            memo.nextRetryAt = nil
        }
        try? await store.save(memo: memo)
        return UtteranceResult(
            kind: .recognitionFailed("\(error)", needsUser: needsUser, retryAt: retryAt), memoID: memo.id, transcript: nil, audioSeconds: seconds, sttMs: nil, answeredLocally: false
        )
    }
}
