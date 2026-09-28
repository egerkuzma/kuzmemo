/// Swift mirror of the response schema (`ResponseSchema.json`). Decoding is strict on enums and dates so a
/// malformed answer triggers the retry path instead of silently guessing.
public enum Intent: String, Codable, Sendable {
    case create, query, update, delete, clarify, unknown
}

public enum ActionOp: String, Codable, Sendable {
    case create, update, complete, reopen, delete
    case skipOccurrence = "skip_occurrence"
}

public enum QueryScope: String, Codable, Sendable {
    case day, range, next, overdue, inbox, search, recurring
}

public enum NamedRange: String, Codable, Sendable {
    case thisWeek = "this_week"
    case nextWeek = "next_week"
    case thisMonth = "this_month"
    case nextMonth = "next_month"
}

public enum QueryDetail: String, Codable, Sendable {
    case digest, count, first
}

public enum ClarificationReason: String, Codable, Sendable {
    case missingDate = "missing_date"
    case missingTime = "missing_time"
    case ambiguousDate = "ambiguous_date"
    case ambiguousTime = "ambiguous_time"
    case ambiguousTarget = "ambiguous_target"
    case targetNotFound = "target_not_found"
    case unclearSpeech = "unclear_speech"
    case destructiveConfirm = "destructive_confirm"
    case other
}

public struct ParsedItem: Codable, Hashable, Sendable {
    public var kind: ItemKind
    public var title: String
    public var details: String?
    public var when: When?
    public var durationMin: Int?
    public var recurrence: Recurrence?
    public var keywords: [String]?

    enum CodingKeys: String, CodingKey {
        case kind, title, details, when
        case durationMin = "duration_min"
        case recurrence, keywords
    }
}

/// Fields the model wants to change on an existing item; absent fields stay as they are.
public struct ParsedChanges: Codable, Hashable, Sendable {
    public var kind: ItemKind?
    public var title: String?
    public var details: String?
    public var when: When?
    public var durationMin: Int?
    public var recurrence: Recurrence?
    public var keywords: [String]?

    enum CodingKeys: String, CodingKey {
        case kind, title, details, when
        case durationMin = "duration_min"
        case recurrence, keywords
    }
}

public struct ParsedAction: Codable, Hashable, Sendable {
    public var op: ActionOp
    /// Number of the entry in the `<items>` list the prompt carried.
    public var ref: Int?
    public var targetHint: String?
    public var occurrenceDate: LocalDate?
    public var item: ParsedItem?
    public var changes: ParsedChanges?

    enum CodingKeys: String, CodingKey {
        case op, ref
        case targetHint = "target_hint"
        case occurrenceDate = "occurrence_date"
        case item, changes
    }
}

public struct ParsedQuery: Codable, Hashable, Sendable {
    public var scope: QueryScope
    public var when: When?
    public var namedRange: NamedRange?
    public var spanDays: Int?
    public var text: String?
    public var includeDone: Bool?
    public var detail: QueryDetail?

    enum CodingKeys: String, CodingKey {
        case scope, when
        case namedRange = "named_range"
        case spanDays = "span_days"
        case text
        case includeDone = "include_done"
        case detail
    }
}

public struct ParsedClarification: Codable, Hashable, Sendable {
    public var question: String
    public var reason: ClarificationReason
    public var options: [String]?
}

public struct ParserResponse: Codable, Hashable, Sendable {
    public var intent: Intent
    public var confidence: Double
    public var transcriptCorrected: String?
    public var actions: [ParsedAction]?
    public var query: ParsedQuery?
    public var clarification: ParsedClarification?
    public var speech: String?

    enum CodingKeys: String, CodingKey {
        case intent, confidence
        case transcriptCorrected = "transcript_corrected"
        case actions, query, clarification, speech
    }
}
