import Foundation
import GRDB

/// The fields the editor works with. Unlike `ItemChanges` (where `nil` means "leave as it is"), `nil` here means
/// "no value": a date removed moves the item to the Inbox, a time removed makes it all-day.
public struct ItemDraft: Equatable, Sendable {
    public var kind: ItemKind
    public var title: String
    public var details: String
    public var date: LocalDate?
    public var time: LocalTime?
    public var durationMin: Int?
    public var recurrence: Recurrence?
    public var remindLeadMin: Int

    public init(
        kind: ItemKind = .task, title: String = "", details: String = "", date: LocalDate? = nil, time: LocalTime? = nil,
        durationMin: Int? = nil, recurrence: Recurrence? = nil, remindLeadMin: Int = 0
    ) {
        self.kind = kind
        self.title = title
        self.details = details
        self.date = date
        self.time = time
        self.durationMin = durationMin
        self.recurrence = recurrence
        self.remindLeadMin = remindLeadMin
    }

    public init(_ item: Item) {
        self.init(
            kind: item.kind, title: item.title, details: item.details ?? "", date: item.date, time: item.time,
            durationMin: item.durationMin, recurrence: item.recurrence, remindLeadMin: item.remindLeadMin
        )
    }

    public enum Problem: Error, Equatable, Sendable {
        case emptyTitle
        /// A repeating item needs the date it starts on.
        case repeatWithoutDate
    }

    /// The draft cleaned up for saving: trimmed text, a time only together with a date, sane repeat and duration.
    public func validated() throws(Problem) -> ItemDraft {
        var draft = self
        draft.title = Self.oneLine(title)
        guard !draft.title.isEmpty else { throw .emptyTitle }
        draft.details = details.trimmingCharacters(in: .whitespacesAndNewlines)
        if draft.date == nil {
            if recurrence != nil { throw .repeatWithoutDate }
            draft.time = nil
        }
        draft.recurrence = recurrence?.normalized(start: draft.date)
        draft.durationMin = durationMin.flatMap { $0 > 0 ? min($0, 24 * 60) : nil }
        draft.remindLeadMin = min(max(remindLeadMin, 0), 7 * 24 * 60)
        return draft
    }

    static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

extension Store {
    /// Adds an item made in the editor or the quick-add field. Journaled like any other change, so it can be undone.
    public func create(_ draft: ItemDraft, source: ItemSource = .manual, label: String = "New entry") async throws -> (op: Op?, item: Item) {
        let clean = try draft.validated()
        let result = try await performReturning(label: label) { mutator -> Item in
            try mutator.insert(Item(
                id: "", kind: clean.kind, title: clean.title, details: clean.details.isEmpty ? nil : clean.details,
                date: clean.date, time: clean.time, durationMin: clean.durationMin, recurrence: clean.recurrence,
                remindLeadMin: clean.remindLeadMin, source: source
            ))
        }
        return (result.op, result.value)
    }

    /// Saves the editor's changes to an existing item (the whole series when it repeats). `expectingRevision` is the revision
    /// the editor read (`Store.revision(of:)`): when the item has moved on since (a voice command, a notification's Done, an
    /// undo), the save is refused with `StoreError.changedMeanwhile` instead of quietly putting the editor's older copy back.
    @discardableResult
    public func save(_ draft: ItemDraft, as itemID: String, expectingRevision: Int? = nil, label: String = "Edit entry") async throws -> Op? {
        let clean = try draft.validated()
        return try await perform(label: label) { mutator in
            if let expectingRevision { try mutator.require(revisions: [itemID: expectingRevision]) }
            _ = try mutator.update(id: itemID) { item in
                item.kind = clean.kind
                item.title = clean.title
                item.details = clean.details.isEmpty ? nil : clean.details
                item.date = clean.date
                item.time = clean.time
                item.durationMin = clean.durationMin
                item.recurrence = clean.recurrence
                item.remindLeadMin = clean.remindLeadMin
                item.approximate = false // a person who edits the date has made it exact
            }
        }
    }

    /// Runs one calendar action from the UI (done, skip, move, delete) through the same journal as voice commands.
    @discardableResult
    public func perform(_ action: PlannedAction, label: String) async throws -> ApplyResult {
        try await apply(MutationPlan(actions: [action]), source: .manual, memoID: nil, label: label)
    }

    /// Memos that failed and are waiting for the person: the Inbox shows them as cards.
    public func failedMemos() async throws -> [Memo] {
        try await writer.read { db in
            try Memo.filter(Column("status") == MemoStatus.failed).order(Column("created_at").desc).fetchAll(db)
        }
    }
}
