import Foundation
import Synchronization
import Testing
@testable import KuzmemoCore

private let moscow = TimeZone(identifier: "Europe/Moscow")!

private func day(_ text: String) -> LocalDate { LocalDate(text)! }

/// A clock a test can move.
private final class TickingNow: NowProvider, Sendable {
    private let instant: Mutex<Date>
    let timeZone: TimeZone

    init(local: String) {
        let fixed = FixedNow(local: local, in: moscow)!
        instant = Mutex(fixed.now())
        timeZone = moscow
    }

    func now() -> Date { instant.withLock { $0 } }
    func advance(days: Int) { instant.withLock { $0 = $0.addingTimeInterval(Double(days) * 86_400) } }
}

@MainActor
private func rig(now: String = "2026-09-28 14:30") throws -> (model: CalendarModel, store: Store) {
    let store = try makeStore(now: now)
    return (CalendarModel(store: store, clock: FixedNow(local: now, in: moscow)!), store)
}

@Suite("CalendarModel")
@MainActor
struct CalendarModelTests {
    @Test func startsOnTodayAndShowsItsEntriesAndTheMonthMarkers() async throws {
        let (model, store) = try rig()
        try await store.create(ItemDraft(kind: .task, title: "Купить молоко", date: day("2026-09-28")))
        try await store.create(ItemDraft(kind: .event, title: "Созвон", date: day("2026-09-28"), time: LocalTime("10:00")))
        try await store.create(ItemDraft(kind: .reminder, title: "Оплатить хостинг", date: day("2026-09-29")))
        await model.reload()

        #expect(model.today == day("2026-09-28") && model.selectedDate == day("2026-09-28") && model.mode == .day)
        #expect(model.grid.month == day("2026-09-01"))
        #expect(model.dayEntries.map(\.item.title) == ["Купить молоко", "Созвон"]) // all-day first
        #expect(model.markers[day("2026-09-28")]?.open == 2 && model.markers[day("2026-09-29")]?.open == 1)
        #expect(model.markers[day("2026-09-30")] == nil)
    }

    /// A reload that is cancelled (the next one was scheduled: an arrow key held down) throws inside the database read. That
    /// used to be turned into "no entries" and blanked the window; now the window keeps what it showed.
    @Test func aCancelledReloadLeavesTheWindowAsItWas() async throws {
        let (model, store) = try rig()
        try await store.create(ItemDraft(kind: .task, title: "Купить молоко", date: day("2026-09-28")))
        try await store.create(ItemDraft(kind: .task, title: "Без даты"))
        await model.reload()
        #expect(model.dayEntries.count == 1 && model.inboxItems.count == 1 && model.markers[day("2026-09-28")]?.open == 1)

        let cancelled = Task { @MainActor in await model.reload() }
        cancelled.cancel()
        await cancelled.value
        #expect(model.dayEntries.map(\.item.title) == ["Купить молоко"])
        #expect(model.inboxItems.count == 1 && model.markers[day("2026-09-28")]?.open == 1)

        // a search that is cancelled keeps the list too
        model.setSearchText("молоко")
        await model.settled()
        #expect(model.searchResults.map(\.title) == ["Купить молоко"])
        let search = Task { @MainActor in await model.reload() }
        search.cancel()
        await search.value
        #expect(model.searchResults.map(\.title) == ["Купить молоко"])
    }

    @Test func selectingAnotherDayShowsItsEntries() async throws {
        let (model, store) = try rig()
        try await store.create(ItemDraft(kind: .reminder, title: "Оплатить хостинг", date: day("2026-09-29")))
        model.show(.inbox)
        model.select(day("2026-09-29"))
        await model.settled()
        #expect(model.mode == .day && model.dayEntries.map(\.item.title) == ["Оплатить хостинг"])
        #expect(model.overdueEntries.isEmpty)
    }

    @Test func aDayInAnotherMonthMovesTheGrid() async throws {
        let (model, _) = try rig()
        model.select(day("2026-11-05"))
        await model.settled()
        #expect(model.grid.month == day("2026-11-01") && model.selectedDate == day("2026-11-05"))
        model.select(day("2026-11-06")) // same month: the grid stays
        #expect(model.grid.month == day("2026-11-01"))
    }

    @Test func pagingKeepsTheDayAndTodayIsOneStepAway() async throws {
        let (model, _) = try rig()
        model.moveMonth(by: 1)
        #expect(model.selectedDate == day("2026-10-28") && model.grid.month == day("2026-10-01"))
        model.moveMonth(by: -2)
        #expect(model.selectedDate == day("2026-08-28"))
        model.moveSelection(byDays: 7)
        #expect(model.selectedDate == day("2026-09-04") && model.grid.month == day("2026-09-01"))
        model.goToToday()
        #expect(model.selectedDate == day("2026-09-28") && model.grid.month == day("2026-09-01"))
    }

    @Test func overdueEntriesAppearOnlyWhileTodayIsSelected() async throws {
        let (model, store) = try rig()
        try await store.create(ItemDraft(kind: .task, title: "Старое дело", date: day("2026-09-20")))
        await model.reload()
        #expect(model.overdueEntries.map(\.item.title) == ["Старое дело"])
        model.select(day("2026-09-29"))
        await model.settled()
        #expect(model.overdueEntries.isEmpty)
    }

    @Test func markingDoneAndBackWorksForOneOffsAndForOneOccurrence() async throws {
        let (model, store) = try rig()
        try await store.create(ItemDraft(kind: .task, title: "Купить молоко", date: day("2026-09-28")))
        try await store.create(ItemDraft(
            kind: .event, title: "Планёрка", date: day("2026-09-28"), time: LocalTime("10:00"),
            recurrence: Recurrence(freq: .weekly, byWeekday: [.mon])
        ))
        await model.reload()
        let milk = try #require(model.dayEntries.first { $0.item.title == "Купить молоко" })
        let standup = try #require(model.dayEntries.first { $0.item.title == "Планёрка" })

        let done = try await model.toggleDone(milk)
        try await model.toggleDone(standup)
        await model.reload()
        #expect(model.dayEntries.allSatisfy(\.isDone) && model.markers[day("2026-09-28")] == DayMarker(open: 0, done: 2, openRecurring: 0, hasRecurring: true))
        #expect(done.lines.first?.hasPrefix("Выполнено") == true)

        // the first action can be undone through its op while nothing else touched that item
        try await store.undo(opID: try #require(done.op).id)
        #expect(try await store.item(id: milk.item.id)?.status == .open)

        // next Monday is untouched: only that occurrence was done
        model.select(day("2026-10-05"))
        await model.settled()
        #expect(model.dayEntries.map(\.isDone) == [false])

        // and the occurrence that is still done can be reopened
        model.select(day("2026-09-28"))
        await model.settled()
        let doneStandup = try #require(model.dayEntries.first { $0.item.title == "Планёрка" })
        #expect(doneStandup.isDone)
        let reopened = try await model.toggleDone(doneStandup)
        #expect(reopened.lines.first?.hasPrefix("Возвращено") == true)
        await model.reload()
        #expect(model.dayEntries.first { $0.item.title == "Планёрка" }?.isDone == false)
    }

    @Test func anOldActionCannotBeUndoneOverALaterEditOfTheSameItem() async throws {
        let (model, store) = try rig()
        try await store.create(ItemDraft(kind: .task, title: "Купить молоко", date: day("2026-09-28")))
        await model.reload()
        let milk = try #require(model.dayEntries.first)
        let done = try await model.toggleDone(milk)
        await model.reload()
        try await model.toggleDone(try #require(model.dayEntries.first)) // reopened: a later change to the same row
        await #expect(throws: StoreError.self) { try await store.undo(opID: try #require(done.op).id) }
    }

    @Test func movingToTomorrowMovesAOneOffButOnlyOneOccurrenceOfASeries() async throws {
        let (model, store) = try rig()
        try await store.create(ItemDraft(kind: .task, title: "Купить молоко", date: day("2026-09-28")))
        try await store.create(ItemDraft(kind: .event, title: "Планёрка", date: day("2026-09-28"), time: LocalTime("10:00"), recurrence: Recurrence(freq: .weekly, byWeekday: [.mon])))
        await model.reload()
        for entry in model.dayEntries { try await model.moveToTomorrow(entry) }

        model.select(day("2026-09-29"))
        await model.settled()
        #expect(model.dayEntries.map(\.item.title) == ["Купить молоко", "Планёрка"])
        #expect(model.dayEntries.last?.wasMoved == true && model.dayEntries.last?.time == LocalTime("10:00"))
        model.select(day("2026-10-05"))
        await model.settled()
        #expect(model.dayEntries.map(\.item.title) == ["Планёрка"]) // the series carries on
    }

    @Test func skippingLeavesOneOccurrenceOut() async throws {
        let (model, store) = try rig()
        try await store.create(ItemDraft(kind: .event, title: "Планёрка", date: day("2026-09-28"), time: LocalTime("10:00"), recurrence: Recurrence(freq: .weekly, byWeekday: [.mon])))
        await model.reload()
        let outcome = try await model.skip(try #require(model.dayEntries.first))
        #expect(outcome.op != nil)
        await model.reload()
        #expect(model.dayEntries.isEmpty)
        model.select(day("2026-10-05"))
        await model.settled()
        #expect(model.dayEntries.count == 1)

        let oneOff = try await store.create(ItemDraft(kind: .task, title: "Разовое", date: day("2026-10-05"))).item
        await model.reload()
        let entry = try #require(model.dayEntries.first { $0.item.id == oneOff.id })
        #expect(try await model.skip(entry).op == nil) // nothing to skip in a one-off
    }

    @Test func deletingRemovesTheItemAndUndoBringsItBack() async throws {
        let (model, store) = try rig()
        let made = try await store.create(ItemDraft(kind: .task, title: "Купить молоко", date: day("2026-09-28"))).item
        await model.reload()
        let outcome = try await model.delete(made)
        await model.reload()
        #expect(model.dayEntries.isEmpty && outcome.lines == ["Удалено · «Купить молоко»"])
        try await store.undo(opID: try #require(outcome.op).id)
        await model.reload()
        #expect(model.dayEntries.count == 1)
    }

    @Test func creatingSavingAndQuickAddingGoThroughTheJournal() async throws {
        let (model, store) = try rig()
        model.select(day("2026-09-30"))
        let quick = try await model.quickAdd("  Позвонить в банк ")
        #expect(quick.lines == ["Создано · «Позвонить в банк»"])
        await model.reload()
        #expect(model.dayEntries.map(\.item.title) == ["Позвонить в банк"] && model.dayEntries.first?.item.source == .manual)

        var draft = ItemDraft(model.dayEntries[0].item)
        draft.time = LocalTime("16:00"); draft.title = "Позвонить в банк Тинькофф"
        let saved = try await model.save(draft, as: model.dayEntries[0].item.id)
        #expect(saved.lines == ["Сохранено · «Позвонить в банк Тинькофф»"])
        await model.reload()
        #expect(model.dayEntries.first?.time == LocalTime("16:00"))

        // with the Inbox showing, quick add makes an undated task
        model.show(.inbox)
        try await model.quickAdd("Идея без даты")
        await model.reload()
        #expect(model.inboxItems.map(\.title) == ["Идея без даты"])
        _ = store
    }

    @Test func theInboxCountsUndatedItemsAndFailedMemos() async throws {
        let (model, store) = try rig()
        try await store.create(ItemDraft(kind: .note, title: "Идея про пуши"))
        try await store.save(memo: Memo(id: "m1", createdAt: 1, anchorLocal: "2026-09-28 14:30", tz: "Europe/Moscow", inputKind: .voice, status: .failed, transcriptRaw: "напомни"))
        try await store.save(memo: Memo(id: "m2", createdAt: 2, anchorLocal: "2026-09-28 14:30", tz: "Europe/Moscow", inputKind: .voice, status: .applied))
        await model.reload()
        #expect(model.inboxItems.count == 1 && model.failedMemos.map(\.id) == ["m1"] && model.inboxCount == 2)
    }

    @Test func searchFindsWordFormsAndClearsWhenTheFieldIsEmptied() async throws {
        let (model, store) = try rig()
        try await store.create(ItemDraft(kind: .reminder, title: "Сказать Дмитрию про доступ", date: day("2026-09-30")))
        try await store.create(ItemDraft(kind: .task, title: "Купить молоко", date: day("2026-09-29")))
        model.setSearchText("Дмитрий")
        #expect(model.mode == .search)
        await model.settled()
        #expect(model.searchResults.map(\.title) == ["Сказать Дмитрию про доступ"])

        model.setSearchText("  ")
        await model.settled()
        #expect(model.searchResults.isEmpty)
    }

    @Test func searchResultsShowWhatIsComingFirst() async throws {
        let (model, store) = try rig()
        for (title, date) in [("Отчёт прошлый", "2026-09-10"), ("Отчёт поздний", "2026-10-20"), ("Отчёт ближайший", "2026-09-29"), ("Отчёт без даты", nil), ("Отчёт давний", "2026-08-01")] {
            try await store.create(ItemDraft(kind: .task, title: title, date: date.map(day)))
        }
        model.setSearchText("Отчёт")
        await model.settled()
        #expect(model.searchResults.map(\.title) == ["Отчёт ближайший", "Отчёт поздний", "Отчёт прошлый", "Отчёт давний", "Отчёт без даты"])
    }

    @Test func aFastTyperOnlyRunsTheLastQuery() async throws {
        let (model, store) = try rig()
        try await store.create(ItemDraft(kind: .task, title: "Купить молоко", date: day("2026-09-29")))
        model.setSearchText("Куп")
        model.setSearchText("Купить")
        model.setSearchText("Купить мол")
        await model.settled()
        #expect(model.searchText == "Купить мол" && model.searchResults.count == 1)
    }

    @Test func theRepeatingListShowsTheNextOpenOccurrence() async throws {
        let (model, store) = try rig()
        try await store.create(ItemDraft(kind: .event, title: "Планёрка", date: day("2026-09-21"), time: LocalTime("10:00"), recurrence: Recurrence(freq: .weekly, byWeekday: [.mon])))
        try await store.create(ItemDraft(kind: .task, title: "Разовое", date: day("2026-09-29")))
        model.show(.recurring)
        await model.settled()
        #expect(model.recurring.map(\.item.title) == ["Планёрка"] && model.recurring.first?.next == day("2026-09-28"))

        await model.reload()
        let today = try #require(model.dayEntries.first)
        try await model.toggleDone(today)
        await model.reload()
        #expect(model.recurring.first?.next == day("2026-10-05")) // today's occurrence is done, so the next open one
    }

    @Test func changesMadeElsewhereReloadTheWindow() async throws {
        let (model, store) = try rig()
        model.startObserving()
        defer { model.stopObserving() }
        try await store.create(ItemDraft(kind: .task, title: "Купить молоко", date: day("2026-09-28")))
        try await store.save(memo: Memo(id: "m1", createdAt: 1, anchorLocal: "2026-09-28 14:30", tz: "Europe/Moscow", inputKind: .voice, status: .failed))
        for _ in 0 ..< 100 where model.dayEntries.isEmpty || model.failedMemos.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        #expect(model.dayEntries.count == 1 && model.failedMemos.count == 1)
    }

    @Test func whenTheDayChangesTodayMovesAlongAndFollowsTheSelection() async throws {
        let clock = TickingNow(local: "2026-09-28 23:50")
        let store = try makeStore(now: "2026-09-28 23:50")
        let model = CalendarModel(store: store, clock: clock)
        try await store.create(ItemDraft(kind: .task, title: "Утреннее дело", date: day("2026-09-29")))
        await model.reload()
        #expect(model.dayEntries.isEmpty)

        clock.advance(days: 1)
        await model.rolloverIfNeeded()
        #expect(model.today == day("2026-09-29") && model.selectedDate == day("2026-09-29"))
        #expect(model.dayEntries.map(\.item.title) == ["Утреннее дело"])

        // a selection the person moved elsewhere stays where it is
        model.select(day("2026-10-15"))
        clock.advance(days: 1)
        await model.rolloverIfNeeded()
        #expect(model.today == day("2026-09-30") && model.selectedDate == day("2026-10-15"))
    }

    /// After midnight the database observer (or a reopened window) may reload before the day timer fires. That reload used to
    /// move "today" without the selection, and the rollover that followed saw nothing left to do: the window stayed on yesterday.
    @Test func aReloadThatCrossesMidnightMovesTheSelectionAlongWithToday() async throws {
        let clock = TickingNow(local: "2026-09-28 23:50")
        let store = try makeStore(now: "2026-09-28 23:50")
        let model = CalendarModel(store: store, clock: clock)
        await model.reload()
        #expect(model.selectedDate == day("2026-09-28"))

        clock.advance(days: 1)
        await model.reload() // a write landed just after midnight
        #expect(model.today == day("2026-09-29") && model.selectedDate == day("2026-09-29"))
        await model.rolloverIfNeeded() // the timer, later: nothing more to do, and nothing undone
        #expect(model.today == day("2026-09-29") && model.selectedDate == day("2026-09-29"))

        // a selection the person moved elsewhere stays where it is; one on today follows it across a month boundary too
        model.select(day("2026-10-15"))
        clock.advance(days: 1)
        await model.reload()
        #expect(model.today == day("2026-09-30") && model.selectedDate == day("2026-10-15"))
        model.goToToday()
        clock.advance(days: 1)
        await model.reload()
        #expect(model.today == day("2026-10-01") && model.selectedDate == day("2026-10-01") && model.grid.isInMonth(day("2026-10-01")))
    }
}
