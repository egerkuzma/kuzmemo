import Foundation
import Testing
@testable import KuzmemoCore

private func date(_ text: String) -> LocalDate { LocalDate(text)! }

@Suite("MonthGrid")
struct MonthGridTests {
    @Test func septemberStartsOnTheMondayBeforeTheFirst() {
        let grid = MonthGrid(containing: date("2026-09-28"))
        #expect(grid.month == date("2026-09-01"))
        #expect(grid.weeks.count == 6 && grid.weeks.allSatisfy { $0.count == 7 })
        #expect(grid.weeks[0][0] == date("2026-08-31")) // 1 Sep 2026 is a Tuesday
        #expect(grid.range == date("2026-08-31") ... date("2026-10-11"))
        #expect(grid.weeks.map { $0[0].weekday } == Array(repeating: Weekday.mon, count: 6))
        #expect(grid.isInMonth(date("2026-09-30")) && !grid.isInMonth(date("2026-10-01")) && !grid.isInMonth(date("2026-08-31")))
    }

    @Test func aMonthThatStartsOnAMondayHasNoLeadingDays() {
        let grid = MonthGrid(containing: date("2027-02-15")) // 1 Feb 2027 is a Monday
        #expect(grid.weeks[0][0] == date("2027-02-01"))
        #expect(grid.range.upperBound == date("2027-03-14"))
    }

    @Test func pagingKeepsTheSameDayOrTheLastOne() {
        #expect(MonthGrid.date(date("2026-09-28"), movedBy: 1) == date("2026-10-28"))
        #expect(MonthGrid.date(date("2026-09-28"), movedBy: -9) == date("2025-12-28"))
        #expect(MonthGrid.date(date("2027-01-31"), movedBy: 1) == date("2027-02-28"))
        #expect(MonthGrid.date(date("2028-01-31"), movedBy: 1) == date("2028-02-29"))
        #expect(MonthGrid(containing: date("2026-12-10")).adding(months: 1).month == date("2027-01-01"))
    }

    @Test func markersCountOpenAndDoneEntriesPerDay() {
        func entry(_ id: String, _ day: String, done: Bool = false, repeating: Bool = false) -> AgendaEntry {
            let item = Item(id: id, kind: .reminder, title: id, date: date(day))
            return AgendaEntry(item: item, date: date(day), time: nil, isDone: done, occurrenceDate: repeating ? date(day) : nil, wasMoved: false)
        }
        let markers = CalendarSummary.markers([
            entry("a", "2026-09-29"), entry("b", "2026-09-29", done: true), entry("c", "2026-09-29", repeating: true), entry("d", "2026-09-30", done: true),
        ])
        #expect(markers[date("2026-09-29")] == DayMarker(open: 2, done: 1, hasRecurring: true))
        #expect(markers[date("2026-09-30")]?.total == 1 && markers[date("2026-09-30")]?.open == 0)
        #expect(markers[date("2026-10-01")] == nil)
    }
}

@Suite("ItemDraft and manual edits")
struct ManualEditTests {
    @Test func aDraftIsCleanedBeforeSaving() throws {
        var draft = ItemDraft(kind: .task, title: "  Позвонить\n  Дмитрию  ", details: "  подробности \n", date: date("2026-10-01"), time: LocalTime("10:00"))
        draft.durationMin = 5000
        draft.remindLeadMin = -5
        let clean = try draft.validated()
        #expect(clean.title == "Позвонить Дмитрию" && clean.details == "подробности")
        #expect(clean.durationMin == 1440 && clean.remindLeadMin == 0)
        #expect(clean.time == LocalTime("10:00"))
    }

    @Test func aTimeWithoutADateIsDroppedAndARepeatNeedsOne() throws {
        let timeOnly = try ItemDraft(kind: .task, title: "Идея", time: LocalTime("10:00")).validated()
        #expect(timeOnly.time == nil && timeOnly.date == nil)
        #expect(throws: ItemDraft.Problem.repeatWithoutDate) {
            try ItemDraft(kind: .task, title: "Зарядка", recurrence: Recurrence(freq: .daily)).validated()
        }
        #expect(throws: ItemDraft.Problem.emptyTitle) { try ItemDraft(title: " \n ").validated() }
    }

    @Test func aRepeatRuleIsClamped() throws {
        let wild = Recurrence(freq: .weekly, interval: 500, byWeekday: [.tue, .mon, .mon], until: date("2026-01-01"), count: 5000)
        let clean = try ItemDraft(kind: .event, title: "Планёрка", date: date("2026-10-05"), recurrence: wild).validated()
        #expect(clean.recurrence?.interval == 99 && clean.recurrence?.count == 1000 && clean.recurrence?.until == nil)
        #expect(clean.recurrence?.byWeekday == [.mon, .tue])
    }

    @Test func createdItemsAreManualAndCanBeUndone() async throws {
        let store = try makeStore()
        let made = try await store.create(ItemDraft(kind: .task, title: "Купить молоко", date: date("2026-09-29")))
        #expect(made.item.source == .manual && made.item.memoID == nil && made.item.date == date("2026-09-29"))
        #expect(try await store.items(on: date("2026-09-29")).map(\.title) == ["Купить молоко"])
        #expect(try await store.search("молоко").count == 1)
        try await store.undo(opID: try #require(made.op).id)
        #expect(try await store.items(on: date("2026-09-29")).isEmpty)
    }

    @Test func savingCanClearFieldsAndUndoRestoresThem() async throws {
        let store = try makeStore()
        let made = try await store.create(ItemDraft(
            kind: .event, title: "Планёрка", details: "в переговорной", date: date("2026-10-05"), time: LocalTime("10:00"),
            durationMin: 30, recurrence: Recurrence(freq: .weekly, byWeekday: [.mon])
        ))
        let id = made.item.id

        // to the Inbox, all-day, no repeat, no details
        var draft = ItemDraft(try #require(try await store.item(id: id)))
        draft.date = nil; draft.time = nil; draft.recurrence = nil; draft.details = ""; draft.title = "Идея"
        let op = try #require(try await store.save(draft, as: id))
        let saved = try #require(try await store.item(id: id))
        #expect(saved.date == nil && saved.time == nil && saved.recurrence == nil && saved.details == nil && saved.title == "Идея")
        #expect(saved.version == made.item.version + 1)
        #expect(try await store.inbox().map(\.id) == [id])
        let foundNew = try await store.search("идея")
        let foundOld = try await store.search("планёрка")
        #expect(foundNew.count == 1 && foundOld.isEmpty) // the search index follows the edit

        try await store.undo(opID: op.id)
        let restored = try #require(try await store.item(id: id))
        #expect(restored.date == date("2026-10-05") && restored.time == LocalTime("10:00") && restored.recurrence != nil && restored.details == "в переговорной")
    }

    @Test func editingADateMakesAnApproximateItemExact() async throws {
        let store = try makeStore()
        let id = try await store.perform(label: "seed") { m in
            try m.insert(Item(id: "x", kind: .reminder, title: "Обсудить бюджет", date: date("2026-10-05"), approximate: true))
        }.map { _ in "x" }!
        var draft = ItemDraft(try #require(try await store.item(id: id)))
        draft.date = date("2026-10-07")
        try await store.save(draft, as: id)
        #expect(try await store.item(id: id)?.approximate == false)
    }

    @Test func uiActionsGoThroughTheSameJournal() async throws {
        let store = try makeStore()
        let made = try await store.create(ItemDraft(kind: .event, title: "Планёрка", date: date("2026-09-28"), time: LocalTime("10:00"), recurrence: Recurrence(freq: .weekly, byWeekday: [.mon])))
        let done = try await store.perform(.complete(itemID: made.item.id, occurrenceDate: date("2026-10-05")), label: "Выполнено")
        #expect(done.changes.first?.kind == .completed)
        let week = try await store.agenda(in: date("2026-10-05") ... date("2026-10-05"))
        #expect(week.first?.isDone == true)
        try await store.undo(opID: try #require(done.op).id)
        #expect(try await store.agenda(in: date("2026-10-05") ... date("2026-10-05")).first?.isDone == false)
    }

    @Test func failedMemosAreListedNewestFirst() async throws {
        let store = try makeStore()
        for (id, status, created) in [("a", MemoStatus.failed, Int64(1)), ("b", .applied, 2), ("c", .failed, 3)] {
            try await store.save(memo: Memo(id: id, createdAt: created, anchorLocal: "2026-09-28 14:30", tz: "Europe/Moscow", inputKind: .voice, status: status))
        }
        #expect(try await store.failedMemos().map(\.id) == ["c", "a"])
    }

    @Test func recurrenceIsDescribedWithItsEnd() {
        #expect(RussianFormat.recurrenceDetailed(Recurrence(freq: .weekly, byWeekday: [.wed], until: date("2026-12-31"))) == "Каждую среду, до 31 декабря")
        #expect(RussianFormat.recurrenceDetailed(Recurrence(freq: .daily, count: 10)) == "Каждый день, 10 раз")
        #expect(RussianFormat.recurrenceDetailed(Recurrence(freq: .daily, count: 3)) == "Каждый день, 3 раза")
        #expect(RussianFormat.recurrenceDetailed(Recurrence(freq: .weekly, byWeekday: [.mon, .tue, .wed, .thu, .fri])) == "По будням")
    }
}
