import Foundation

/// The context of an answer to a clarifying question: the transcript is read together with what was said before
/// and what the app asked, and the guards that make the app ask (an ambiguous "next Friday", "tomorrow" after
/// midnight, a bulk deletion) do not fire a second time.
public struct FollowUp: Equatable, Sendable {
    /// The phrase that caused the question, followed by any earlier answers (oldest first).
    public var previous: String
    public var question: String

    public init(previous: String, question: String) {
        self.previous = previous
        self.question = question
    }

    /// The question asked at what time something happens (the app's own wording, or the model's in either language). An
    /// answer such as "no" or "any" to it means the entry has no time, and is not a reason to ask again.
    public var askedForTime: Bool {
        question.lowercased().range(of: #"во сколько|в какое время|какое время|на какое время|at what time|what time|which time"#, options: .regularExpression) != nil
    }
}

public struct InterpretRequest: Sendable {
    public var transcript: String
    public var anchor: LocalDateTime
    public var timeZone: TimeZone
    public var followUp: FollowUp?

    public init(transcript: String, anchor: LocalDateTime, timeZone: TimeZone, followUp: FollowUp? = nil) {
        self.transcript = transcript
        self.anchor = anchor
        self.timeZone = timeZone
        self.followUp = followUp
    }
}

public struct InterpretResult: Sendable {
    public var interpretation: Interpretation
    /// What the model answered, before validation.
    public var response: ParserResponse
    public var llm: LLMResponse
    /// The numbered entries the model was shown (needed to explain `ref`s in logs).
    public var context: ContextPlan
    /// 1, or 2 when the first answer was structurally invalid and was asked for again.
    public var attempts: Int
    /// The transcript after glossary replacements, as the model saw it.
    public var transcriptSent: String
}

/// Text in, decision out: glossary clean-up, context selection, the model call, strict decoding and
/// validation. Persisting and applying the outcome is the caller's job (the pipeline coordinator).
public struct Interpreter: Sendable {
    public var store: Store
    public var provider: any LLMProvider
    public var promptBuilder: PromptBuilder
    public var planner: ContextPlanner
    public var policy: ValidationPolicy
    public var model: String
    public var effort: String?
    public var timeout: TimeInterval

    public init(
        store: Store, provider: any LLMProvider, promptBuilder: PromptBuilder = PromptBuilder(),
        planner: ContextPlanner = ContextPlanner(), policy: ValidationPolicy = .standard,
        model: String = "sonnet", effort: String? = "low", timeout: TimeInterval = 30
    ) {
        self.store = store
        self.provider = provider
        self.promptBuilder = promptBuilder
        self.planner = planner
        self.policy = policy
        self.model = model
        self.effort = effort
        self.timeout = timeout
    }

    public func interpret(_ request: InterpretRequest) async throws -> InterpretResult {
        let glossary = try await store.glossary()
        let transcript = Glossary.applyAliases(to: request.transcript, terms: glossary)
        let followUp = request.followUp.map {
            FollowUp(previous: Glossary.applyAliases(to: $0.previous, terms: glossary), question: $0.question)
        }
        // Entries are picked from everything that was said, since the earlier phrase may name the target.
        let context = try await planner.plan(
            transcript: [followUp?.previous, transcript].compactMap { $0 }.joined(separator: " "), anchor: request.anchor, store: store
        )
        let message = promptBuilder.userMessage(
            transcript: transcript, anchor: request.anchor, timeZone: request.timeZone, glossary: glossary, context: context,
            followUp: followUp
        )
        let llmRequest = LLMRequest(
            systemPrompt: Prompt.system, userMessage: message, schema: ResponseSchema.compact,
            model: model, effort: effort, timeout: timeout
        )

        var attempts = 0
        while true {
            attempts += 1
            do {
                let llm = try await provider.complete(llmRequest)
                let response = try Self.decode(llm.structuredJSON)
                let validation = ValidationContext(
                    context: context,
                    resolver: RelativeDateResolver(anchor: request.anchor, dayParts: promptBuilder.dayParts),
                    store: store, policy: policy, isFollowUp: followUp != nil, timeWasAsked: followUp?.askedForTime ?? false
                )
                let interpretation = await ActionValidator.validate(response, in: validation)
                return InterpretResult(
                    interpretation: interpretation, response: response, llm: llm, context: context,
                    attempts: attempts, transcriptSent: transcript
                )
            } catch let error as LLMError where attempts < 2 && Self.isStructural(error) {
                continue // one more try for a malformed answer; other failures go to the caller's retry policy
            }
        }
    }

    static func decode(_ json: String) throws -> ParserResponse {
        do {
            return try JSONDecoder().decode(ParserResponse.self, from: Data(json.utf8))
        } catch {
            throw LLMError.schemaViolation("\(error)")
        }
    }

    static func isStructural(_ error: LLMError) -> Bool {
        switch error {
        case .schemaViolation, .missingStructuredOutput, .invalidEnvelope: true
        default: false
        }
    }
}
