import Foundation
import GRDB

/// The entries shown to the model, numbered `[1]...[n]` in chronological order. The model refers to them by
/// number, so it never sees (or invents) database ids.
public struct ContextPlan: Sendable, Equatable {
    public var entries: [AgendaEntry]
    /// True when the phrase looks like an edit or a question and the wider window was used.
    public var expanded: Bool

    public init(entries: [AgendaEntry], expanded: Bool) {
        self.entries = entries
        self.expanded = expanded
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

    public func plan(transcript: String, anchor: LocalDateTime, store: Store) async throws -> ContextPlan {
        let words = SearchText.tokens(transcript)
        let expanded = words.contains { word in Self.editCues.contains { word.hasPrefix($0) } }
        let days = expanded ? expandedDays : baseDays
        let limit = expanded ? expandedLimit : baseLimit
        let today = anchor.date

        var entries = try await store.agenda(in: today...today.adding(days: days), includeDone: false)
        let overdue = try await store.overdue(before: today, limit: 10)
        var seen = Set(entries.map(\.id))
        for item in overdue {
            let entry = AgendaEntry(
                item: item, date: item.date ?? today, time: item.time, isDone: false, occurrenceDate: nil, wasMoved: false
            )
            if seen.insert(entry.id).inserted { entries.append(entry) }
        }

        if expanded {
            var hits: [Item] = []
            for word in words where word.count >= 4 && !Self.stopWords.contains(word) && !Self.editCues.contains(where: { word.hasPrefix($0) }) {
                for item in try await store.search(word, limit: 5) where !hits.contains(where: { $0.id == item.id }) {
                    hits.append(item)
                }
                if hits.count >= searchHitLimit { break }
            }
            for item in hits.prefix(searchHitLimit) {
                let date = item.date ?? today
                let entry = AgendaEntry(
                    item: item, date: date, time: item.time, isDone: item.status == .done,
                    occurrenceDate: item.recurrence == nil ? nil : date, wasMoved: false
                )
                if !entries.contains(where: { $0.item.id == item.id }), seen.insert(entry.id).inserted { entries.append(entry) }
            }
        }

        entries.sort {
            if $0.date != $1.date { return $0.date < $1.date }
            return ($0.time?.minutesSinceMidnight ?? -1) < ($1.time?.minutesSinceMidnight ?? -1)
        }
        return ContextPlan(entries: Array(entries.prefix(limit)), expanded: expanded)
    }
}

extension Store {
    /// Open, dated, one-off items whose date is before `date`, newest first.
    public func overdue(before date: LocalDate, limit: Int = 20) async throws -> [Item] {
        try await writer.read { db in
            try Item
                .filter(Column("deleted_at") == nil && Column("recurrence_json") == nil)
                .filter(Column("status") == ItemStatus.open && Column("date") < date)
                .order(Column("date").desc, Column("time").desc)
                .limit(limit)
                .fetchAll(db)
        }
    }
}
