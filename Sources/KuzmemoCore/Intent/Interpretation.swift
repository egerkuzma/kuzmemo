/// What the app decided to do with a validated model answer.
public enum Interpretation: Equatable, Sendable {
    /// Changes to apply (all of them, or none: partial application never happens).
    case mutate(MutationPlan)
    /// A question the app answers from its own data.
    case query(QueryPlan)
    /// The model or the validator needs one more piece of information from the user.
    case clarify(Clarification)
    /// Noise or something that is not a calendar command. The text is a short reason for logs.
    case unknown(String?)
}

public struct Clarification: Equatable, Sendable {
    public var question: String
    public var reason: ClarificationReason
    public var options: [String]

    public init(question: String, reason: ClarificationReason, options: [String] = []) {
        self.question = question
        self.reason = reason
        self.options = options
    }
}

public struct MutationPlan: Equatable, Sendable {
    public var actions: [PlannedAction]
    /// Things the validator corrected or dropped; logged, never shown as errors.
    public var warnings: [String]
    public var correctedTranscript: String?
    public var confidence: Double

    public init(actions: [PlannedAction], warnings: [String] = [], correctedTranscript: String? = nil, confidence: Double = 1) {
        self.actions = actions
        self.warnings = warnings
        self.correctedTranscript = correctedTranscript
        self.confidence = confidence
    }
}

public struct NewItem: Equatable, Sendable {
    public var kind: ItemKind
    public var title: String
    public var details: String?
    public var keywords: String
    public var date: LocalDate?
    public var time: LocalTime?
    public var durationMin: Int?
    public var approximate: Bool
    public var recurrence: Recurrence?

    public init(
        kind: ItemKind, title: String, details: String? = nil, keywords: String = "", date: LocalDate? = nil,
        time: LocalTime? = nil, durationMin: Int? = nil, approximate: Bool = false, recurrence: Recurrence? = nil
    ) {
        self.kind = kind
        self.title = title
        self.details = details
        self.keywords = keywords
        self.date = date
        self.time = time
        self.durationMin = durationMin
        self.approximate = approximate
        self.recurrence = recurrence
    }
}

/// Fields to change on an existing item. `nil` leaves a field as it is.
public struct ItemChanges: Equatable, Sendable {
    public var kind: ItemKind?
    public var title: String?
    public var details: String?
    public var keywords: String?
    public var date: LocalDate?
    public var time: LocalTime?
    public var durationMin: Int?
    public var recurrence: Recurrence?

    public init(
        kind: ItemKind? = nil, title: String? = nil, details: String? = nil, keywords: String? = nil,
        date: LocalDate? = nil, time: LocalTime? = nil, durationMin: Int? = nil, recurrence: Recurrence? = nil
    ) {
        self.kind = kind
        self.title = title
        self.details = details
        self.keywords = keywords
        self.date = date
        self.time = time
        self.durationMin = durationMin
        self.recurrence = recurrence
    }

    public var isEmpty: Bool { self == ItemChanges() }

    func apply(to item: inout Item) {
        if let kind { item.kind = kind }
        if let title { item.title = title }
        if let details { item.details = details }
        if let keywords { item.keywords = keywords }
        if let date { item.date = date }
        if let time { item.time = time }
        if let durationMin { item.durationMin = durationMin }
        if let recurrence { item.recurrence = recurrence }
    }
}

public enum PlannedAction: Equatable, Sendable {
    case create(NewItem)
    /// Edits a one-off item, or the whole series of a recurring one.
    case update(itemID: String, changes: ItemChanges)
    /// Moves one occurrence of a recurring item to another date/time.
    case moveOccurrence(itemID: String, occurrenceDate: LocalDate, newDate: LocalDate, newTime: LocalTime?)
    case complete(itemID: String, occurrenceDate: LocalDate?)
    case reopen(itemID: String, occurrenceDate: LocalDate?)
    case delete(itemID: String)
    case skipOccurrence(itemID: String, occurrenceDate: LocalDate)
}

/// A question about the calendar, resolved to concrete dates; the app runs it and composes the answer.
public struct QueryPlan: Equatable, Sendable {
    public enum Target: Equatable, Sendable {
        case days(ClosedRange<LocalDate>)
        case upcoming(limit: Int)
        case overdue
        case inbox
        case search(String)
        case recurring
    }

    public var target: Target
    public var includeDone: Bool
    public var detail: QueryDetail

    public init(target: Target, includeDone: Bool = false, detail: QueryDetail = .digest) {
        self.target = target
        self.includeDone = includeDone
        self.detail = detail
    }
}
