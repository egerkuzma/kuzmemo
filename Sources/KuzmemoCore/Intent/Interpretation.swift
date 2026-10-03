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

public struct MutationPlan: Equatable, Codable, Sendable {
    public var actions: [PlannedAction]
    /// Things the validator corrected or dropped; logged, never shown as errors.
    public var warnings: [String]
    public var correctedTranscript: String?
    public var confidence: Double
    /// The version each entry the plan touches had when the plan was made (the entries the model was shown). The plan was
    /// worked out from that state; applying it checks that the entries have not moved on meanwhile (the person edited one
    /// while the model was answering), and refuses with `StoreError.changedMeanwhile` when one has.
    public var expectedVersions: [String: Int]

    public init(
        actions: [PlannedAction], warnings: [String] = [], correctedTranscript: String? = nil, confidence: Double = 1,
        expectedVersions: [String: Int] = [:]
    ) {
        self.actions = actions
        self.warnings = warnings
        self.correctedTranscript = correctedTranscript
        self.confidence = confidence
        self.expectedVersions = expectedVersions
    }
}

public struct NewItem: Equatable, Codable, Sendable {
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
public struct ItemChanges: Equatable, Codable, Sendable {
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

    /// Drops the fields that would set what `item` already has. The model tends to repeat the title or the kind beside the one
    /// thing that differs; a repeated field is not a change, and for a series it would turn the move of one occurrence into a
    /// change of the whole series. The date and the time are left alone: where an occurrence stands is decided separately.
    mutating func removeUnchanged(comparedWith item: Item) {
        if kind == item.kind { kind = nil }
        if title == item.title { title = nil }
        if details == item.details { details = nil }
        if keywords == item.keywords { keywords = nil }
        if durationMin == item.durationMin { durationMin = nil }
        if recurrence == item.recurrence { recurrence = nil }
    }

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

public enum PlannedAction: Equatable, Codable, Sendable {
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
