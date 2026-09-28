import Foundation

/// One request to the language model: static instructions, the dynamic message and the response schema.
public struct LLMRequest: Sendable, Equatable {
    public var systemPrompt: String
    public var userMessage: String
    /// Single-line JSON Schema.
    public var schema: String
    public var model: String
    /// Reasoning effort ("low"); ignored for models that do not support it.
    public var effort: String?
    public var timeout: TimeInterval

    public init(
        systemPrompt: String, userMessage: String, schema: String,
        model: String = "sonnet", effort: String? = "low", timeout: TimeInterval = 30
    ) {
        self.systemPrompt = systemPrompt
        self.userMessage = userMessage
        self.schema = schema
        self.model = model
        self.effort = effort
        self.timeout = timeout
    }
}

public struct LLMResponse: Sendable, Equatable {
    /// The structured answer as JSON text.
    public var structuredJSON: String
    /// The full envelope printed by the CLI, kept for audit.
    public var rawEnvelope: String
    public var model: String
    /// Wall-clock time of the whole call in milliseconds.
    public var wallMs: Int
    /// Time the CLI reports for the call in milliseconds.
    public var reportedMs: Int?
    public var usageJSON: String?
    public var costUSD: Double?
}

public enum LLMError: Error, Equatable {
    case executableNotFound(searched: [String])
    /// The installed CLI lacks flags the app depends on.
    case unsupportedCLI(missing: [String])
    case notLoggedIn
    case rateLimited(String)
    case timedOut(seconds: Double)
    case processFailed(exitCode: Int32, stderr: String)
    case invalidEnvelope(String)
    case apiError(String)
    case missingStructuredOutput
    /// The answer parsed as JSON but does not match the response contract.
    case schemaViolation(String)

    /// Whether trying again right away has a fair chance of helping.
    public var isTransient: Bool {
        switch self {
        case .timedOut, .rateLimited, .apiError, .invalidEnvelope, .missingStructuredOutput, .schemaViolation: true
        case .processFailed: true
        case .executableNotFound, .unsupportedCLI, .notLoggedIn: false
        }
    }
}

public protocol LLMProvider: Sendable {
    func complete(_ request: LLMRequest) async throws -> LLMResponse
}
