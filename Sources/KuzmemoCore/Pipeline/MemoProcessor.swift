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

    /// Saves the utterance first, then interprets and applies it.
    public func submit(
        text: String, inputKind: MemoInputKind, sttModel: String? = nil, sttMs: Int? = nil, durationMs: Int? = nil,
        parentMemoID: String? = nil, anchor: LocalDateTime? = nil
    ) async -> ProcessOutcome {
        let localNow = anchor ?? clock.localNow()
        let memo = Memo(
            id: makeID(), createdAt: nowMs, anchorLocal: "\(localNow.date) \(localNow.time)", tz: clock.timeZone.identifier,
            inputKind: inputKind, status: .transcribed, durationMs: durationMs, sttModel: sttModel, sttMs: sttMs,
            transcriptRaw: text, parentMemoID: parentMemoID
        )
        do {
            try await store.save(memo: memo)
        } catch {
            return ProcessOutcome(memo: memo, kind: .failed(.processFailed(exitCode: -1, stderr: "database: \(error)"), retryAt: nil), interpretation: nil)
        }
        return await process(memo)
    }

    /// A question the local router recognised: no model call. The memo is still recorded so history is complete.
    public func answerLocally(
        text: String, plan: QueryPlan, inputKind: MemoInputKind, sttModel: String? = nil, sttMs: Int? = nil,
        durationMs: Int? = nil, anchor: LocalDateTime? = nil
    ) async -> ProcessOutcome {
        let localNow = anchor ?? clock.localNow()
        let memo = Memo(
            id: makeID(), createdAt: nowMs, anchorLocal: "\(localNow.date) \(localNow.time)", tz: clock.timeZone.identifier,
            inputKind: inputKind, status: .answered, durationMs: durationMs, sttModel: sttModel, sttMs: sttMs,
            transcriptRaw: text, llmModel: "local-router", intent: Intent.query.rawValue, confidence: 1
        )
        try? await store.save(memo: memo)
        return ProcessOutcome(memo: memo, kind: .answered(plan), interpretation: nil)
    }

    /// Runs a saved memo again (manual "Повторить" or the automatic retry).
    public func retry(memoID: String) async -> ProcessOutcome? {
        guard let memo = try? await store.memo(id: memoID) else { return nil }
        return await process(memo)
    }

    /// Resumes everything that was interrupted or is due for another attempt. Call at launch and on a timer.
    public func recoverUnfinished() async -> [ProcessOutcome] {
        guard let memos = try? await store.unfinishedMemos() else { return [] }
        var outcomes: [ProcessOutcome] = []
        for memo in memos where memo.transcriptRaw != nil {
            switch memo.status {
            case .transcribed, .thinking, .interpreted:
                outcomes.append(await process(memo))
            case .failed:
                if let due = memo.nextRetryAt, due <= nowMs { outcomes.append(await process(memo)) }
            default:
                continue
            }
        }
        return outcomes
    }

    // MARK: - Processing

    private var nowMs: Int64 { Int64(clock.now().timeIntervalSince1970 * 1000) }

    private func process(_ input: Memo) async -> ProcessOutcome {
        var memo = input
        guard let transcript = memo.transcriptRaw else {
            memo.status = .discarded
            memo.failReason = "no transcript"
            try? await store.save(memo: memo)
            return ProcessOutcome(memo: memo, kind: .unknown, interpretation: nil)
        }

        // A crash between "changes committed" and "memo marked applied" must not apply the phrase twice.
        if let op = try? await store.op(forMemo: memo.id), op.undoneAt == nil {
            memo.status = .applied
            memo.opID = op.id
            try? await store.save(memo: memo)
            return ProcessOutcome(memo: memo, kind: .applied(ApplyResult(op: op, changes: [])), interpretation: nil)
        }

        memo.status = .thinking
        try? await store.save(memo: memo)

        let anchor = Self.parseAnchor(memo.anchorLocal) ?? clock.localNow()
        let timeZone = TimeZone(identifier: memo.tz) ?? clock.timeZone
        let started = Date()
        let result: InterpretResult
        do {
            result = try await interpreter.interpret(InterpretRequest(transcript: transcript, anchor: anchor, timeZone: timeZone))
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
        try? await store.save(memo: memo)

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
        if created == plan.actions.count { return created == 1 ? "Создание записи" : "Создание записей (\(created))" }
        return "Изменение календаря"
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
