import Foundation
import GRDB

/// The entries shown to the model, numbered `[1]...[n]` in chronological order. The model refers to them by
/// number, so it never sees (or invents) database ids.
public struct ContextPlan: Sendable, Equatable {
    public var entries: [AgendaEntry]
    /// True when the phrase looks like an edit or a question and the wider window was used.
    public var expanded: Bool
    /// The revision of every listed entry at the moment the list was made (`Store.revisions`): a plan made from this list is
    /// applied only while the entries it touches still have these.
    public var revisions: [String: Int]

    public init(entries: [AgendaEntry], expanded: Bool, revisions: [String: Int] = [:]) {
        self.entries = entries
        self.expanded = expanded
        self.revisions = revisions
    }

    /// The entry the model meant by `[number]`.
    public func entry(number: Int) -> AgendaEntry? {
        guard number >= 1, number <= entries.count else { return nil }
        return entries[number - 1]
    }
}

/// Chooses which existing entries to show the model: a short window by default, a wider one plus text
/// matches when the phrase looks like an edit, a deletion or a question.
public struct ContextPlanner: Sendable {
    public var baseDays = 7
    public var expandedDays = 14
    public var baseLimit = 25
    public var expandedLimit = 40
    public var searchHitLimit = 8

    public init() {}

    /// Word beginnings (Russian, then English) that mark a phrase as an edit, a deletion or a question.
    static let editCues = [
        "перенес", "передвин", "сдвин", "отмен", "удал", "отмет", "выполн", "готов", "измен", "переимен",
        "поменя", "верни", "верн", "что", "когда", "какие", "какой", "найд", "покаж", "скаж", "есть", "сколько",
        "move", "reschedul", "postpon", "cancel", "delet", "remov", "complet", "finish", "mark", "chang", "renam",
        "reopen", "what", "when", "which", "find", "show", "tell", "list", "how",
    ]

    /// Words that carry no identifying content for the text search.
    static let stopWords: Set<String> = [
        "напомни", "напомнить", "мне", "завтра", "послезавтра", "сегодня", "через", "неделю", "недели",
        "перенеси", "передвинь", "отмени", "удали", "отметь", "выполненным", "запиши", "скажи", "найди",
        "покажи", "когда", "что", "какие", "меня", "будет", "надо", "нужно", "пожалуиста", "ещё", "еще",
        "утром", "днем", "вечером", "ночью", "часов", "часа", "утра", "вечера",
        "remind", "tomorrow", "today", "please", "need", "should", "about", "next", "week", "this", "that", "with",
        "move", "delete", "remove", "cancel", "find", "show", "tell", "what", "when", "which", "have", "will", "morning",
        "evening", "night", "afternoon",
    ]

    /// Everything the model is shown comes from ONE read transaction, revisions included: the entries and the revisions they
    /// are checked against at apply belong to the same moment. Read apart, a change landing between the two gave an old entry
    /// the new revision, and a plan made from the old entry passed the check.
    public func plan(transcript: String, anchor: LocalDateTime, store: Store) async throws -> ContextPlan {
        try await store.writer.read { db in try self.plan(db, transcript: transcript, anchor: anchor) }
    }

    func plan(_ db: Database, transcript: String, anchor: LocalDateTime) throws -> ContextPlan {
        let words = SearchText.tokens(transcript)
        let expanded = words.contains { word in Self.editCues.contains { word.hasPrefix($0) } }
        let days = expanded ? expandedDays : baseDays
        let limit = expanded ? expandedLimit : baseLimit
        let today = anchor.date

        var entries = try Store.agenda(db, in: today...today.adding(days: days), includeDone: false)
        let overdue = try Store.overdue(db, before: today, limit: 10)
        var seen = Set(entries.map(\.id))
        for item in overdue {
            let entry = AgendaEntry(
                item: item, date: item.date ?? today, time: item.time, isDone: false, occurrenceDate: nil, wasMoved: false
            )
            if seen.insert(entry.id).inserted { entries.append(entry) }
        }

        // The entries the phrase's own words point at: whatever the list is cut to, they stay in it.
        var found = Set<String>()
        if expanded {
            var hits: [Item] = []
            for word in words where word.count >= 4 && !Self.stopWords.contains(word) && !Self.editCues.contains(where: { word.hasPrefix($0) }) {
                for item in try SearchIndex.search(db, query: word, limit: 5) where !hits.contains(where: { $0.id == item.id }) {
                    hits.append(item)
                }
                if hits.count >= searchHitLimit { break }
            }
            // A series found by its words but outside the window is listed at its next occurrence: its own date is the day it
            // started, and "complete", "skip" or "move" on that would hit an occurrence from months ago.
            var upcoming: [String: AgendaEntry]?
            found = Set(hits.prefix(searchHitLimit).map(\.id))
            for item in hits.prefix(searchHitLimit) where !entries.contains(where: { $0.item.id == item.id }) {
                let entry: AgendaEntry
                if item.recurrence != nil {
                    if upcoming == nil {
                        let year = try Store.agenda(db, in: today...today.adding(days: 366), includeDone: false)
                        upcoming = Dictionary(year.map { ($0.item.id, $0) }, uniquingKeysWith: { first, _ in first })
                    }
                    // a series with nothing ahead has no occurrence to name: the entry carries none and the validator asks
                    entry = upcoming?[item.id] ?? AgendaEntry(
                        item: item, date: item.date ?? today, time: item.time, isDone: false, occurrenceDate: nil, wasMoved: false
                    )
                } else {
                    entry = AgendaEntry(
                        item: item, date: item.date ?? today, time: item.time, isDone: item.status == .done,
                        occurrenceDate: nil, wasMoved: false
                    )
                }
                if seen.insert(entry.id).inserted { entries.append(entry) }
            }
        }

        entries.sort {
            if $0.date != $1.date { return $0.date < $1.date }
            return ($0.time?.minutesSinceMidnight ?? -1) < ($1.time?.minutesSinceMidnight ?? -1)
        }
        let listed = Self.cut(entries, to: limit, keeping: found)
        return ContextPlan(entries: listed, expanded: expanded, revisions: try Store.revisions(db, of: Array(Set(listed.map(\.item.id)))))
    }

    /// The first `limit` entries, except that an entry of an item the words pointed at is never the one dropped: a full fortnight
    /// of nearer entries used to push "the meeting with Dmitry" in a month out of the list, and the model could not see what it
    /// was asked to change. The latest entries go first; found ones go only when they alone exceed the limit.
    static func cut(_ entries: [AgendaEntry], to limit: Int, keeping found: Set<String>) -> [AgendaEntry] {
        guard entries.count > limit else { return entries }
        var kept = entries
        var index = kept.count - 1
        while kept.count > limit, index >= 0 {
            if !found.contains(kept[index].item.id) { kept.remove(at: index) }
            index -= 1
        }
        return Array(kept.prefix(limit))
    }
}

extension Store {
    /// Open, dated, one-off items whose date is before `date`, newest first.
    public func overdue(before date: LocalDate, limit: Int = 20) async throws -> [Item] {
        try await writer.read { db in try Store.overdue(db, before: date, limit: limit) }
    }

    static func overdue(_ db: Database, before date: LocalDate, limit: Int) throws -> [Item] {
        try Item
            .filter(Column("deleted_at") == nil && Column("recurrence_json") == nil)
            .filter(Column("status") == ItemStatus.open && Column("date") < date)
            .order(Column("date").desc, Column("time").desc)
            .limit(limit)
            .fetchAll(db)
    }
}
