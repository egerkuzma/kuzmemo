import Foundation
import GRDB
import Testing
@testable import KuzmemoCore

/// Things that were fine on a handful of entries and went wrong on a large calendar: nothing here measures time (a loaded
/// machine would make that flaky), it checks what was read and what was found.
@Suite("Scale: search")
struct ScaleSearchTests {
    /// Entries are put in with plain inserts and the index is built once: a mutator insert looks the entry up in the index first,
    /// which makes a seed of ten thousand entries slow for no reason that matters here.
    private func crowded(_ count: Int) async throws -> Store {
        let store = try makeStore()
        try await store.writer.write { db in
            for index in 0 ..< count {
                try Item(
                    id: "i\(index)", kind: .task, title: "Задача номер \(index) xq", date: LocalDate("2026-10-01"),
                    source: .voice, createdAt: Int64(index), updatedAt: Int64(index)
                ).insert(db)
            }
            try SearchIndex.rebuild(db)
        }
        return store
    }

    /// A word of one or two letters is not in the trigram index, so it was looked for among the first 5 000 entries only.
    @Test func aShortWordIsFoundAmongAllEntriesNotJustTheFirstFiveThousand() async throws {
        let store = try await crowded(6_000)
        try await store.writer.write { db in
            // dated last, so that no ordering of the table puts it among the first thousands
            try Item(id: "needle", kind: .task, title: "zz редкий", date: LocalDate("2030-01-01"), source: .voice, createdAt: 1, updatedAt: 1).insert(db)
            try SearchIndex.upsert(db, item: try #require(try Item.fetchOne(db, key: "needle")))
        }
        #expect(try await store.search("zz").map(\.id) == ["needle"])
    }

    @Test func shortWordsMatchTitleDetailsAndKeywordsAndEveryWordHasToMatch() async throws {
        let store = try makeStore()
        try await store.perform(label: "seed") { m in
            try m.insert(reminder("Позвонить маме", on: "2026-10-01", details: "до обеда"))
            var tagged = reminder("Купить хлеб", on: "2026-10-01")
            tagged.keywords = "ям магазин"
            try m.insert(tagged)
            try m.insert(reminder("Ёлка на праздник", on: "2026-12-30"))
        }
        #expect(try await store.search("до").map(\.title) == ["Позвонить маме"]) // details
        #expect(try await store.search("ям").map(\.title) == ["Купить хлеб"]) // keywords
        #expect(try await store.search("ЁЛ").map(\.title) == ["Ёлка на праздник"]) // folded like the index
        #expect(try await store.search("до ма").map(\.title) == ["Позвонить маме"])
        #expect(try await store.search("до ям").isEmpty) // no entry has both
        #expect(try await store.search("  ").isEmpty)
    }

    @Test func aDeletedEntryIsNotFoundByAShortWordAndTheLimitHolds() async throws {
        let store = try await crowded(300)
        #expect(try await store.search("xq", limit: 25).count == 25)
        try await store.perform(label: "delete") { try $0.softDelete(id: "i7") }
        let all = try await store.search("xq", limit: 1000).map(\.id)
        #expect(all.count == 299 && !all.contains("i7"))
    }

    /// With more matches than the limit, the newest ones are kept (the order does not depend on how the table happens to be walked).
    @Test func theLimitKeepsTheNewestMatches() async throws {
        let store = try await crowded(50)
        #expect(try await store.search("xq", limit: 3).map(\.id) == ["i49", "i48", "i47"])
    }
}

private func day(_ s: String) -> LocalDate { LocalDate(s)! }

private func series(
    _ id: String, from start: String, _ rule: Recurrence, at time: String? = "09:00", title: String? = nil
) -> Item {
    var item = Item(id: id, kind: .event, title: title ?? "Series \(id)", date: day(start), time: time.flatMap(LocalTime.init), source: .voice, createdAt: 1, updatedAt: 1)
    item.recurrence = rule
    return item
}

/// The overrides of a series are read for the range that is shown, not all of them: a daily habit ticked off for years leaves a
/// row a day, and every view of the calendar used to read and sift all of them for every series.
@Suite("Scale: overrides of repeating entries")
struct ScaleExceptionsTests {
    private func store(with items: [Item], exceptions: [ItemException]) async throws -> Store {
        let store = try makeStore()
        try await store.writer.write { db in
            for item in items { try item.insert(db) }
            for exception in exceptions { try exception.insert(db) }
            try SearchIndex.rebuild(db)
        }
        return store
    }

    private let range = day("2026-10-05") ... day("2026-10-11")

    private var marks: [ItemException] {
        // a year of old ticks, and the few overrides that matter to the week of 5-11 October
        (0 ..< 200).map { ItemException(itemID: "habit", occDate: day("2026-01-01").adding(days: $0), action: .done) } + [
            ItemException(itemID: "habit", occDate: day("2026-10-07"), action: .skip),
            ItemException(itemID: "habit", occDate: day("2026-10-08"), action: .moved, movedDate: day("2026-10-20"), movedTime: LocalTime("18:00")),
            ItemException(itemID: "habit", occDate: day("2026-09-20"), action: .moved, movedDate: day("2026-10-09"), movedTime: LocalTime("14:00")),
            ItemException(itemID: "habit", occDate: day("2026-09-25"), action: .done, movedDate: day("2026-10-10"), movedTime: LocalTime("10:30")),
        ]
    }

    @Test func onlyTheOverridesThatTouchTheRangeAreRead() async throws {
        let habit = series("habit", from: "2026-01-01", Recurrence(freq: .daily))
        let store = try await store(with: [habit], exceptions: marks)
        let read = try await store.writer.read { try Store.exceptions($0, for: ["habit"], in: range) }
        // the skip and the move away (their day is in the range), the move in from before it and the tick moved in: no old ticks
        #expect(Set(read.map(\.occDate)) == [day("2026-10-07"), day("2026-10-08"), day("2026-09-20"), day("2026-09-25")])
        #expect(try await store.writer.read { try Store.exceptions($0, for: [], in: range) }.isEmpty)
    }

    /// The week as it is shown must not change because the old ticks are no longer read.
    @Test func theWeekIsShownAsBeforeWithAYearOfOldTicks() async throws {
        let habit = series("habit", from: "2026-01-01", Recurrence(freq: .daily))
        let store = try await store(with: [habit], exceptions: marks)
        let entries = try await store.agenda(in: range)
        let shown = entries.map { "\($0.date) \($0.time.map(String.init(describing:)) ?? "-") \($0.occurrenceDate.map(String.init(describing:)) ?? "-") \($0.isDone ? "done" : "open") \($0.wasMoved ? "moved" : "")" }
        #expect(shown == [
            "2026-10-05 09:00 2026-10-05 open ",
            "2026-10-06 09:00 2026-10-06 open ",
            // the 7th is skipped and the 8th moved away to the 20th
            "2026-10-09 09:00 2026-10-09 open ",
            "2026-10-09 14:00 2026-09-20 open moved",
            "2026-10-10 09:00 2026-10-10 open ",
            "2026-10-10 10:30 2026-09-25 done moved",
            "2026-10-11 09:00 2026-10-11 open ",
        ])
    }

    @Test func aMoveIntoTheRangeFromBeforeTheSeriesStartedIsStillShown() async throws {
        let late = series("late", from: "2026-11-01", Recurrence(freq: .weekly))
        let move = ItemException(itemID: "late", occDate: day("2026-11-01"), action: .moved, movedDate: day("2026-10-08"))
        let store = try await store(with: [late], exceptions: [move])
        #expect(try await store.agenda(in: range).map(\.date) == [day("2026-10-08")])
    }
}

/// The next occurrence of a series: found for each series on its own (a month first, the year only where needed) and equal to what
/// the first line of the year's agenda says, which is how the "Repeating" list and the model's context used to get it.
@Suite("Scale: the next occurrence of a series")
struct ScaleUpcomingTests {
    private let today = day("2026-09-28") // a Monday
    private var horizon: ClosedRange<LocalDate> { today ... today.adding(days: 366) }

    private func scenario() async throws -> (Store, [Item]) {
        let store = try makeStore()
        let items = [
            series("daily", from: "2026-01-01", Recurrence(freq: .daily)),
            series("weekly", from: "2026-01-05", Recurrence(freq: .weekly, byWeekday: [.mon, .thu])),
            series("finished", from: "2025-01-01", Recurrence(freq: .daily, until: day("2026-06-01"))),
            series("exhausted", from: "2026-09-19", Recurrence(freq: .weekly, count: 3)), // Saturdays: the 19th, 26th and 3 October
            series("yearly", from: "2025-12-01", Recurrence(freq: .yearly)), // 2 December, far from the month ahead
            series("not-yet", from: "2027-12-01", Recurrence(freq: .daily)), // starts after the year ahead
            series("ticked", from: "2026-09-01", Recurrence(freq: .weekly, byWeekday: [.mon]), at: nil),
            series("pulled-in", from: "2026-09-01", Recurrence(freq: .weekly, byWeekday: [.fri])),
            series("pushed-out", from: "2026-09-01", Recurrence(freq: .monthly, byMonthday: 1)),
            series("only-skipped", from: "2026-09-28", Recurrence(freq: .daily, until: day("2026-09-29"))),
        ]
        try await store.writer.write { db in
            for item in items { try item.insert(db) }
            // today's and the next Monday's occurrences are ticked off, so the next open one is the Monday after
            for date in ["2026-09-28", "2026-10-05"] { try ItemException(itemID: "ticked", occDate: day(date), action: .done).insert(db) }
            // the Friday of 9 October is brought forward to Tuesday the 29th, nearer than the regular Friday the 2nd
            try ItemException(itemID: "pulled-in", occDate: day("2026-10-09"), action: .moved, movedDate: day("2026-09-29"), movedTime: LocalTime("08:00")).insert(db)
            // 1 October goes far away: the next first of the month is 1 November
            try ItemException(itemID: "pushed-out", occDate: day("2026-10-01"), action: .moved, movedDate: day("2027-03-01")).insert(db)
            for date in ["2026-09-28", "2026-09-29"] { try ItemException(itemID: "only-skipped", occDate: day(date), action: .skip).insert(db) }
            try SearchIndex.rebuild(db)
        }
        return (store, items)
    }

    @Test func eachSeriesGetsTheSameNextOccurrenceTheYearsAgendaListsFirst() async throws {
        let (store, items) = try await scenario()
        let found = try await store.writer.read { db in try Store.upcoming(db, of: items, from: horizon.lowerBound, through: horizon.upperBound) }
        let year = try await store.agenda(in: horizon, includeDone: false)
        var reference: [String: AgendaEntry] = [:]
        for entry in year where reference[entry.item.id] == nil { reference[entry.item.id] = entry }
        #expect(found == reference)
        // …and the reference is not trivially empty
        #expect(Set(found.keys) == ["daily", "weekly", "exhausted", "yearly", "ticked", "pulled-in", "pushed-out"])
    }

    @Test func theNextOccurrenceOfEachKindOfSeries() async throws {
        let (store, items) = try await scenario()
        let found = try await store.writer.read { db in try Store.upcoming(db, of: items, from: horizon.lowerBound, through: horizon.upperBound) }
        func next(_ id: String) -> String? { found[id].map { "\($0.date) \($0.time.map(String.init(describing:)) ?? "-")" } }
        #expect(next("daily") == "2026-09-28 09:00")
        #expect(next("weekly") == "2026-09-28 09:00")
        #expect(next("exhausted") == "2026-10-03 09:00") // the last of its three
        #expect(next("yearly") == "2026-12-01 09:00") // found by the second, year-wide pass
        #expect(next("ticked") == "2026-10-12 -") // the 28th and the 5th are ticked off
        #expect(next("pulled-in") == "2026-09-29 08:00") // moved to a nearer day than its own
        #expect(next("pushed-out") == "2026-11-01 09:00") // the 1st of October went to March
        #expect(next("finished") == nil && next("not-yet") == nil && next("only-skipped") == nil)
    }

    @Test func theRepeatingListReadsTheSeriesAndTheirNextOccurrenceInOneGo() async throws {
        let (store, _) = try await scenario()
        let list = try await store.recurringWithNext(from: today)
        #expect(list.count == 10)
        #expect(list.first { $0.id == "yearly" }?.next == day("2026-12-01"))
        #expect(list.first { $0.id == "finished" }?.next == nil)
        #expect(list.first { $0.id == "ticked" }?.next == day("2026-10-12"))
    }
}

@Suite("Scale: the model's context")
struct ScaleContextTests {
    private let anchor = LocalDateTime(date: day("2026-09-28"), time: LocalTime("14:30")!)

    /// A series the words found, outside the fortnight shown, is named at its next occurrence (not the day it started): that is
    /// worked out for the found series alone, whatever else the calendar holds.
    @Test func aFoundSeriesOutsideTheWindowIsListedAtItsNextOccurrence() async throws {
        let store = try makeStore()
        try await store.writer.write { db in
            for n in 0 ..< 120 { try series("busy\(n)", from: "2026-01-01", Recurrence(freq: .daily), title: "Ежедневное \(n)").insert(db) }
            try series("review", from: "2025-12-01", Recurrence(freq: .yearly), title: "Годовой отчёт").insert(db)
            try series("old", from: "2025-01-01", Recurrence(freq: .daily, until: day("2026-06-01")), title: "Прежняя планёрка").insert(db)
            try ItemException(itemID: "review", occDate: day("2026-12-01"), action: .moved, movedDate: day("2026-12-03"), movedTime: LocalTime("11:00")).insert(db)
            try SearchIndex.rebuild(db)
        }
        let plan = try await ContextPlanner().plan(transcript: "перенеси годовой отчёт и прежняя планёрка", anchor: anchor, store: store)
        let review = try #require(plan.entries.first { $0.item.id == "review" })
        #expect(review.date == day("2026-12-03") && review.occurrenceDate == day("2026-12-01") && review.wasMoved)
        // a series with nothing ahead is listed without an occurrence: the validator asks which one is meant
        let old = try #require(plan.entries.first { $0.item.id == "old" })
        #expect(old.occurrenceDate == nil)
        #expect(plan.entries.count == 40)
    }
}
