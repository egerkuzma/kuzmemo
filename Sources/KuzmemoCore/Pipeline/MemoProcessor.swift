import Foundation
import GRDB

/// How long to wait before asking the model again after a transient failure.
public struct RetryPolicy: Sendable {
    public var delays: [TimeInterval]
    public var maxAttempts: Int

    public init(delays: [TimeInterval], maxAttempts: Int) {
        self.delays = delays
        self.maxAttempts = maxAttempts
    }

    /// 1 min, 5 min, 30 min, 2 h, then every 2 h, at most 6 attempts.
    public static let standard = RetryPolicy(delays: [60, 300, 1800, 7200], maxAttempts: 6)

    /// Delay before the next attempt after `attempts` failed ones, or `nil` when we give up.
    public func delay(afterAttempts attempts: Int) -> TimeInterval? {
        guard attempts < maxAttempts, !delays.isEmpty else { return nil }
        return delays[min(attempts - 1, delays.count - 1)]
    }
}

public struct ProcessOutcome: Sendable {
    public enum Kind: Sendable {
        /// Changes were made; `changes` and the journal entry are in the result.
        case applied(ApplyResult)
        /// The user asked a question; the caller runs the query and speaks the answer.
        case answered(QueryPlan)
        /// More information is needed; nothing was changed.
        case clarify(Clarification)
        /// Not a command (noise, chatter).
        case unknown
        /// Everything was erased while the phrase was being worked on: nothing of it was saved or made.
        case erased
        /// The model could not be reached or answered badly. The memo is saved and will be retried.
        case failed(LLMError, retryAt: Date?)
    }

    public var memo: Memo
    public var kind: Kind
    /// Present when the model was consulted.
    public var interpretation: InterpretResult?
}

/// Takes a transcript from "captured" to "applied", persisting the memo before every step so that
/// nothing is lost when Claude is offline, the quota is exhausted or the app quits mid-way.
public actor MemoProcessor {
    private let store: Store
    private let interpreter: Interpreter
    private let clock: any NowProvider
    private let retryPolicy: RetryPolicy
    private let makeID: @Sendable () -> String
    /// Memos being interpreted right now; actor methods interleave at every `await`, and a retry or recovery
    /// that picked up the same memo would apply it twice.
    private var inFlight: Set<String> = []

    public init(
        store: Store, interpreter: Interpreter, clock: any NowProvider = SystemNow(),
        retryPolicy: RetryPolicy = .standard, makeID: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() }
    ) {
        self.store = store
        self.interpreter = interpreter
        self.clock = clock
        self.retryPolicy = retryPolicy
        self.makeID = makeID
    }

    // MARK: - Entry points

    /// Saves the utterance first, then interprets and applies it. An answer to a clarifying question passes the
    /// memo it answers as `parentMemoID` and the question; the answer is then read together with what was said
    /// before, from the same moment.
    public func submit(
        text: String, inputKind: MemoInputKind, sttModel: String? = nil, sttMs: Int? = nil, durationMs: Int? = nil,
        parentMemoID: String? = nil, followupQuestion: String? = nil, anchor: LocalDateTime? = nil
    ) async -> ProcessOutcome {
        var anchorText: String?
        var timeZone = clock.timeZone.identifier
        if let parentMemoID, let parent = try? await store.memo(id: parentMemoID) {
            anchorText = parent.anchorLocal // "tomorrow" keeps meaning what it meant when the question was asked
            timeZone = parent.tz
        }
        let localNow = anchor ?? clock.localNow()
        let memo = Memo(
            id: makeID(), createdAt: nowMs, anchorLocal: anchorText ?? "\(localNow.date) \(localNow.time)", tz: timeZone,
            inputKind: inputKind, status: .transcribed, durationMs: durationMs, sttModel: sttModel, sttMs: sttMs,
            transcriptRaw: text, parentMemoID: parentMemoID, followupQuestion: followupQuestion
        )
        do {
            try await store.save(memo: memo)
        } catch {
            return ProcessOutcome(memo: memo, kind: .failed(.processFailed(exitCode: -1, stderr: "database: \(error)"), retryAt: nil), interpretation: nil)
        }
        if let parentMemoID { await supersede(parentMemoID) }
        return await process(memo)
    }

    /// The question of a memo was answered: the answer's memo carries the phrase on.
    public func supersede(_ memoID: String) async {
        guard var memo = try? await store.memo(id: memoID), memo.status == .clarifying else { return }
        memo.status = .superseded
        try? await store.save(memo: memo)
    }

    /// Gives up on a memo the user was asked about (Esc, or a "no" in the middle of a question).
    public func discard(memoID: String, reason: String) async {
        guard var memo = try? await store.memo(id: memoID), memo.status == .clarifying || memo.status == .failed else { return }
        memo.status = .discarded
        memo.failReason = reason
        memo.nextRetryAt = nil
        try? await store.save(memo: memo)
    }

    /// Saves the words that started a conversation as a note without a date, for when a question got no answer.
    public func keepAsNote(memoID: String) async -> ProcessOutcome? {
        // Claimed before the first await: a double click on "Save as a note" must make one note, not two.
        guard inFlight.insert(memoID).inserted else { return nil }
        defer { inFlight.remove(memoID) }
        guard var memo = try? await store.memo(id: memoID), memo.status != .applied, memo.opID == nil else { return nil }
        // A phrase that has a journal entry was dealt with (the note was made, and perhaps undone since): it is marked so, and
        // no second note is made. The store now marks a phrase together with its changes; this covers phrases written before
        // it did, as in `process`.
        if let op = try? await store.op(forMemo: memo.id) {
            memo.status = .applied
            memo.opID = op.id
            memo.failReason = nil
            memo.nextRetryAt = nil
            try? await store.save(memo: memo)
            return ProcessOutcome(memo: memo, kind: .applied(ApplyResult(op: op, changes: [])), interpretation: nil)
        }
        let words = await chainTranscripts(endingAt: memo).first ?? memo.transcriptRaw
        guard let text = words?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        let title = text.count <= 80 ? text : String(text.prefix(77)) + "…"
        let plan = MutationPlan(actions: [.create(NewItem(kind: .note, title: title, details: title == text ? nil : text))])
        do {
            let applied = try await store.apply(plan, source: memo.inputKind == .voice ? .voice : .quickadd, memoID: memo.id, label: "Note from a phrase")
            memo.status = .applied
            memo.opID = applied.op?.id
            memo.failReason = nil
            memo.nextRetryAt = nil
            try? await store.save(memo: memo)
            return ProcessOutcome(memo: memo, kind: .applied(applied), interpretation: nil)
        } catch {
            return ProcessOutcome(memo: memo, kind: .failed(.processFailed(exitCode: -2, stderr: "apply: \(error)"), retryAt: nil), interpretation: nil)
        }
    }

    /// Questions that were still open when the app quit can no longer be answered (the conversation lives in
    /// memory), so the words are kept as notes. Call once at launch, before anything new starts.
    @discardableResult
    public func closeOrphanedQuestions() async -> [ProcessOutcome] {
        guard let memos = try? await store.unfinishedMemos() else { return [] }
        var outcomes: [ProcessOutcome] = []
        for memo in memos where memo.status == .clarifying && !inFlight.contains(memo.id) {
            if let outcome = await keepAsNote(memoID: memo.id) {
                outcomes.append(outcome)
            } else {
                await discard(memoID: memo.id, reason: "the question was left open when the app quit")
            }
        }
        return outcomes
    }

    /// Transcripts along the chain of questions and answers ending at `memo`, oldest first.
    private func chainTranscripts(endingAt memo: Memo) async -> [String] {
        var parts: [String] = []
        var current: Memo? = memo
        var depth = 0
        while let memo = current, depth < 6 {
            if let text = memo.transcriptRaw { parts.insert(text, at: 0) }
            current = memo.parentMemoID == nil ? nil : try? await store.memo(id: memo.parentMemoID!)
            depth += 1
        }
        return parts
    }

    private func followUp(for memo: Memo) async -> FollowUp? {
        guard let question = memo.followupQuestion, let parentID = memo.parentMemoID, let parent = try? await store.memo(id: parentID) else { return nil }
        let earlier = await chainTranscripts(endingAt: parent)
        guard !earlier.isEmpty else { return nil }
        return FollowUp(previous: earlier.joined(separator: ". "), question: question)
    }

    /// A question the local router recognised: no model call. The memo is still recorded so history is complete.
    public func answerLocally(
        text: String, plan: QueryPlan, inputKind: MemoInputKind, sttModel: String? = nil, sttMs: Int? = nil,
        durationMs: Int? = nil, anchor: LocalDateTime? = nil
    ) async -> ProcessOutcome {
        let localNow = anchor ?? clock.localNow()
        let memo = Memo(
            id: makeID(), createdAt: nowMs, anchorLocal: "\(localNow.date) \(localNow.time)", tz: clock.timeZone.identifier,
            inputKind: inputKind, status: .transcribed, durationMs: durationMs, sttModel: sttModel, sttMs: sttMs,
            transcriptRaw: text
        )
        return await answerLocally(memo: memo, plan: plan)
    }

    /// The same for a memo that already exists (a recording that has just been transcribed).
    public func answerLocally(memo input: Memo, plan: QueryPlan) async -> ProcessOutcome {
        var memo = input
        memo.status = .answered
        memo.llmModel = "local-router"
        memo.intent = Intent.query.rawValue
        memo.confidence = 1
        memo.failStage = nil
        memo.failReason = nil
        memo.nextRetryAt = nil
        try? await store.save(memo: memo)
        return ProcessOutcome(memo: memo, kind: .answered(plan), interpretation: nil)
    }

    /// Runs a saved memo again (manual "Retry" or the automatic retry).
    public func retry(memoID: String) async -> ProcessOutcome? {
        // The memo is claimed before the first await. Checking and claiming apart let two triggers (the button and the
        // timer) both pass the check while the first one was still reading the memo, and the phrase was applied twice.
        guard inFlight.insert(memoID).inserted else { return nil }
        guard let memo = try? await store.memo(id: memoID), !Self.finalStatuses.contains(memo.status) else {
            inFlight.remove(memoID)
            return nil
        }
        return await process(memo)
    }

    /// The person corrected the words of a failed memo (the Inbox card): replace the text and interpret it again.
    public func editAndRetry(memoID: String, text: String) async -> ProcessOutcome? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, inFlight.insert(memoID).inserted else { return nil }
        guard var memo = try? await store.memo(id: memoID) else {
            inFlight.remove(memoID)
            return nil
        }
        memo.transcriptRaw = trimmed
        memo.transcriptCorrected = nil
        memo.status = .transcribed
        memo.failStage = nil
        memo.failReason = nil
        memo.nextRetryAt = nil
        memo.attempts = 0
        try? await store.save(memo: memo)
        return await process(memo)
    }

    /// Resumes everything that was interrupted or is due for another attempt. Call at launch and on a timer.
    public func recoverUnfinished() async -> [ProcessOutcome] {
        guard let memos = try? await store.unfinishedMemos() else { return [] }
        var outcomes: [ProcessOutcome] = []
        for listed in memos where listed.transcriptRaw != nil {
            guard inFlight.insert(listed.id).inserted else { continue }
            // The list was read before the loop began and a model call takes seconds: by the time a memo's turn comes, a
            // live call may have finished it (or the person undone it). Look at the memo as it is now, and never run one
            // that has reached a final state.
            guard let memo = try? await store.memo(id: listed.id), memo.transcriptRaw != nil else {
                inFlight.remove(listed.id)
                continue
            }
            switch memo.status {
            case .transcribed, .thinking, .interpreted:
                outcomes.append(await process(memo))
            case .failed where memo.nextRetryAt.map({ $0 <= nowMs }) == true:
                outcomes.append(await process(memo))
            default:
                inFlight.remove(listed.id)
            }
        }
        return outcomes
    }

    /// States a memo does not leave: what became of it is final, and running it again would repeat (or undo) that.
    static let finalStatuses: Set<MemoStatus> = [.applied, .answered, .discarded, .superseded]

    // MARK: - Processing

    private var nowMs: Int64 { Int64(clock.now().timeIntervalSince1970 * 1000) }

    private func process(_ input: Memo) async -> ProcessOutcome {
        inFlight.insert(input.id)
        defer { inFlight.remove(input.id) }
        var memo = input
        guard let transcript = memo.transcriptRaw else {
            memo.status = .discarded
            memo.failReason = "no transcript"
            try? await store.save(memo: memo)
            return ProcessOutcome(memo: memo, kind: .unknown, interpretation: nil)
        }

        // A phrase that has a journal entry was executed, whether or not the person has undone it since: running it again would
        // make its changes twice, or make them anew after the undo. (The store marks a phrase applied in the transaction of its
        // changes; a phrase written by an older version can still be found in this state.)
        if let op = try? await store.op(forMemo: memo.id) {
            memo.status = .applied
            memo.opID = op.id
            try? await store.save(memo: memo)
            return ProcessOutcome(memo: memo, kind: .applied(ApplyResult(op: op, changes: [])), interpretation: nil)
        }

        memo.status = .thinking
        try? await store.save(memo: memo)

        let followUp = await followUp(for: memo)
        // A plain no to the app's own "Delete 3 entries?" is decided here, without the model: the limits were lifted for the
        // answer to that question, and a model that misread the no could have come back with the deletions.
        if let followUp, followUp.askedToConfirmBulk, FollowUp.declines(transcript) {
            memo.llmModel = "local-router"
            memo.intent = Intent.unknown.rawValue
            memo.confidence = 1
            memo.status = .discarded
            memo.failReason = "the person said no"
            try? await store.save(memo: memo)
            return ProcessOutcome(memo: memo, kind: .unknown, interpretation: nil)
        }

        let anchor = Self.parseAnchor(memo.anchorLocal) ?? clock.localNow()
        let timeZone = TimeZone(identifier: memo.tz) ?? clock.timeZone
        // Read once more when an entry the plan was made for changed while the model was answering (the person edited it
        // meanwhile): the second reading sees the entry as it is now. A second conflict is reported.
        var readings = 0
        while true {
            readings += 1
            let started = Date()
            let result: InterpretResult
            do {
                result = try await interpreter.interpret(InterpretRequest(
                    transcript: transcript, anchor: anchor, timeZone: timeZone, followUp: followUp
                ))
            } catch let error as LLMError {
                return await fail(memo, error, elapsed: Date().timeIntervalSince(started))
            } catch {
                return await fail(memo, .processFailed(exitCode: -1, stderr: "\(error)"), elapsed: Date().timeIntervalSince(started))
            }

            memo.llmModel = result.llm.model
            memo.llmMs = result.llm.wallMs
            memo.llmUsageJSON = result.llm.usageJSON
            memo.llmResponseJSON = result.llm.structuredJSON
            memo.intent = result.response.intent.rawValue
            memo.confidence = result.response.confidence
            memo.transcriptCorrected = result.transcriptSent == transcript ? result.response.transcriptCorrected : result.transcriptSent
            memo.failStage = nil
            memo.failReason = nil
            memo.nextRetryAt = nil
            memo.status = .interpreted
            // The model took seconds, and everything may have been erased meanwhile: a phrase that is gone stays gone (a failed
            // write, as opposed to a refused one, is not a reason to stop).
            guard (try? await store.saveUnlessErased(memo: memo)) != false else {
                return ProcessOutcome(memo: memo, kind: .erased, interpretation: result)
            }

            switch result.interpretation {
            case let .mutate(plan):
                do {
                    let applied = try await store.apply(
                        plan, source: memo.inputKind == .voice ? .voice : .quickadd, memoID: memo.id,
                        label: Self.label(for: plan)
                    )
                    memo.status = .applied
                    memo.opID = applied.op?.id
                    try? await store.save(memo: memo)
                    return ProcessOutcome(memo: memo, kind: .applied(applied), interpretation: result)
                } catch StoreError.memoErased {
                    return ProcessOutcome(memo: memo, kind: .erased, interpretation: result)
                } catch StoreError.changedMeanwhile where readings < 2 {
                    continue
                } catch {
                    return await fail(memo, .processFailed(exitCode: -2, stderr: "apply: \(error)"), elapsed: 0, stage: "apply")
                }
            case let .query(plan):
                memo.status = .answered
                try? await store.save(memo: memo)
                return ProcessOutcome(memo: memo, kind: .answered(plan), interpretation: result)
            case let .clarify(clarification):
                memo.status = .clarifying
                try? await store.save(memo: memo)
                return ProcessOutcome(memo: memo, kind: .clarify(clarification), interpretation: result)
            case .unknown:
                memo.status = .discarded
                try? await store.save(memo: memo)
                return ProcessOutcome(memo: memo, kind: .unknown, interpretation: result)
            }
        }
    }

    private func fail(_ input: Memo, _ error: LLMError, elapsed: TimeInterval, stage: String = "llm") async -> ProcessOutcome {
        var memo = input
        memo.status = .failed
        memo.failStage = stage
        memo.failReason = "\(error)"
        memo.attempts += 1
        var retryAt: Date?
        if error.isTransient, let delay = retryPolicy.delay(afterAttempts: memo.attempts) {
            retryAt = clock.now().addingTimeInterval(delay)
            memo.nextRetryAt = Int64(retryAt!.timeIntervalSince1970 * 1000)
        } else {
            memo.nextRetryAt = nil // needs the user (login, missing CLI) or attempts are used up
        }
        try? await store.save(memo: memo)
        return ProcessOutcome(memo: memo, kind: .failed(error, retryAt: retryAt), interpretation: nil)
    }

    static func parseAnchor(_ text: String) -> LocalDateTime? {
        let parts = text.split(separator: " ")
        guard parts.count == 2, let date = LocalDate(String(parts[0])), let time = LocalTime(String(parts[1])) else { return nil }
        return LocalDateTime(date: date, time: time)
    }

    static func label(for plan: MutationPlan) -> String {
        let created = plan.actions.filter { if case .create = $0 { true } else { false } }.count
        if created == plan.actions.count { return created == 1 ? "Create entry" : "Create entries (\(created))" }
        return "Change calendar"
    }
}

extension Store {
    /// The journal entry a memo produced, if any.
    public func op(forMemo memoID: String) async throws -> Op? {
        try await writer.read { db in
            try Op.filter(Column("memo_id") == memoID).order(Column("created_at").desc).fetchOne(db)
        }
    }
}
