import GRDB

/// One captured utterance (or typed command) and its processing state. Persisted before each stage so
/// nothing is lost when Claude is offline or the app quits.
public struct Memo: Codable, Hashable, Sendable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "memos"

    public var id: String
    public var createdAt: Int64
    /// Local wall-clock reading when the phrase was spoken, `YYYY-MM-DD HH:MM`. Relative dates resolve against it.
    public var anchorLocal: String
    public var tz: String
    public var inputKind: MemoInputKind
    public var status: MemoStatus
    public var audioPath: String?
    public var durationMs: Int?
    public var sttModel: String?
    public var sttMs: Int?
    public var transcriptRaw: String?
    public var transcriptCorrected: String?
    public var llmModel: String?
    public var llmMs: Int?
    public var llmUsageJSON: String?
    public var llmResponseJSON: String?
    public var intent: String?
    public var confidence: Double?
    public var failStage: String?
    public var failReason: String?
    public var attempts: Int
    public var nextRetryAt: Int64?
    public var opID: String?
    public var parentMemoID: String?

    public init(
        id: String, createdAt: Int64, anchorLocal: String, tz: String, inputKind: MemoInputKind,
        status: MemoStatus, audioPath: String? = nil, durationMs: Int? = nil, sttModel: String? = nil,
        sttMs: Int? = nil, transcriptRaw: String? = nil, transcriptCorrected: String? = nil,
        llmModel: String? = nil, llmMs: Int? = nil, llmUsageJSON: String? = nil, llmResponseJSON: String? = nil,
        intent: String? = nil, confidence: Double? = nil, failStage: String? = nil, failReason: String? = nil,
        attempts: Int = 0, nextRetryAt: Int64? = nil, opID: String? = nil, parentMemoID: String? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.anchorLocal = anchorLocal
        self.tz = tz
        self.inputKind = inputKind
        self.status = status
        self.audioPath = audioPath
        self.durationMs = durationMs
        self.sttModel = sttModel
        self.sttMs = sttMs
        self.transcriptRaw = transcriptRaw
        self.transcriptCorrected = transcriptCorrected
        self.llmModel = llmModel
        self.llmMs = llmMs
        self.llmUsageJSON = llmUsageJSON
        self.llmResponseJSON = llmResponseJSON
        self.intent = intent
        self.confidence = confidence
        self.failStage = failStage
        self.failReason = failReason
        self.attempts = attempts
        self.nextRetryAt = nextRetryAt
        self.opID = opID
        self.parentMemoID = parentMemoID
    }

    enum CodingKeys: String, CodingKey {
        case id
        case createdAt = "created_at"
        case anchorLocal = "anchor_local"
        case tz
        case inputKind = "input_kind"
        case status
        case audioPath = "audio_path"
        case durationMs = "duration_ms"
        case sttModel = "stt_model"
        case sttMs = "stt_ms"
        case transcriptRaw = "transcript_raw"
        case transcriptCorrected = "transcript_corrected"
        case llmModel = "llm_model"
        case llmMs = "llm_ms"
        case llmUsageJSON = "llm_usage_json"
        case llmResponseJSON = "llm_response_json"
        case intent, confidence
        case failStage = "fail_stage"
        case failReason = "fail_reason"
        case attempts
        case nextRetryAt = "next_retry_at"
        case opID = "op_id"
        case parentMemoID = "parent_memo_id"
    }
}

/// A term the user cares about: canonical spelling, spoken aliases (as the speech recognizer tends to write
/// them) and how a TTS voice should pronounce it.
public struct GlossaryTerm: Codable, Hashable, Sendable, Identifiable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "glossary_terms"

    public var id: Int64?
    public var canonical: String
    public var kind: String?
    public var aliases: [String]
    public var spoken: String?
    public var enabled: Bool

    public init(id: Int64? = nil, canonical: String, kind: String? = nil, aliases: [String] = [], spoken: String? = nil, enabled: Bool = true) {
        self.id = id
        self.canonical = canonical
        self.kind = kind
        self.aliases = aliases
        self.spoken = spoken
        self.enabled = enabled
    }

    enum CodingKeys: String, CodingKey {
        case id, canonical, kind
        case aliases = "aliases_json"
        case spoken, enabled
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}
