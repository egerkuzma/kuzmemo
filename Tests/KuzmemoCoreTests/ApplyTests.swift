import Foundation
import Testing
@testable import KuzmemoCore

private func day(_ text: String) -> LocalDate { LocalDate(text)! }

private func seedWeekly(_ store: Store) async throws {
    var series = Item(id: "", kind: .event, title: "Планёрка", date: day("2026-10-05"), time: LocalTime("10:00"), source: .voice)
    series.recurrence = Recurrence(freq: .weekly, byWeekday: [.mon])
    let seed = series
    try await store.perform(label: "seed") { try $0.insert(seed) }
}

@Suite("Store.apply")
struct ApplyTests {
    @Test func createUsesTheSourceAndMemoAndReturnsASummary() async throws {
        let store = try makeStore()
        try await store.save(memo: Memo(id: "memo-1", createdAt: 1, anchorLocal: "2026-09-28 14:30", tz: "Europe/Moscow",
                                        inputKind: .voice, status: .interpreted, transcriptRaw: "напомни"))
        let plan = MutationPlan(actions: [
            .create(NewItem(kind: .reminder, title: "Сказать Дмитрию", date: day("2026-09-30"))),
            .create(NewItem(kind: .task, title: "Купить молоко")),
        ])
        let result = try await store.apply(plan, source: .voice, memoID: "memo-1", label: "voice")
        #expect(result.op?.memoID == "memo-1" && result.op?.label == "voice")
        #expect(result.changes.map(\.kind) == [.created, .created])
        let saved = try #require(try await store.item(id: result.changes[0].item.id))
        #expect(saved.source == .voice && saved.memoID == "memo-1" && saved.date == day("2026-09-30"))
        #expect(try await store.inbox().map(\.title) == ["Купить молоко"])
    }

    @Test func aMixedPlanIsOneUndoableOperation() async throws {
        let store = try makeStore()
        try await store.perform(label: "seed") { m in
            try m.insert(Item(id: "", kind: .reminder, title: "Старое", date: day("2026-10-01"), source: .manual))
            try m.insert(Item(id: "", kind: .reminder, title: "Лишнее", date: day("2026-10-02"), source: .manual))
        }
        let plan = MutationPlan(actions: [
            .create(NewItem(kind: .task, title: "Новое")),
            .update(itemID: "id-1", changes: ItemChanges(title: "Обновлённое", date: day("2026-10-09"))),
            .delete(itemID: "id-2"),
        ])
        let result = try await store.apply(plan, source: .voice, memoID: nil, label: "mixed")
        #expect(result.changes.map(\.kind) == [.created, .updated, .deleted])
        #expect(try await store.item(id: "id-1")?.title == "Обновлённое")
        #expect(try await store.item(id: "id-2") == nil)

        try await store.undo(opID: try #require(result.op).id)
        #expect(try await store.item(id: "id-1")?.title == "Старое")
        #expect(try await store.item(id: "id-2")?.title == "Лишнее")
        #expect(try await store.inbox().isEmpty)
    }

    @Test func aFailingActionRollsBackTheWholePlan() async throws {
        let store = try makeStore()
        let plan = MutationPlan(actions: [
            .create(NewItem(kind: .task, title: "Не должно сохраниться")),
            .delete(itemID: "does-not-exist"),
        ])
        await #expect(throws: StoreError.itemNotFound("does-not-exist")) {
            try await store.apply(plan, source: .voice, memoID: nil, label: "bad")
        }
        #expect(try await store.inbox().isEmpty)
        #expect(try await store.lastUndoableOp() == nil)
    }

    @Test func oneOffItemsCanBeCompletedAndReopened() async throws {
        let store = try makeStore()
        try await store.perform(label: "seed") { try $0.insert(Item(id: "", kind: .task, title: "Дело", date: day("2026-10-01"), source: .manual)) }
        _ = try await store.apply(MutationPlan(actions: [.complete(itemID: "id-1", occurrenceDate: nil)]), source: .voice, memoID: nil, label: "c")
        let done = try #require(try await store.item(id: "id-1"))
        #expect(done.status == .done && done.doneAt == 1_790_595_000_000)
        _ = try await store.apply(MutationPlan(actions: [.reopen(itemID: "id-1", occurrenceDate: nil)]), source: .voice, memoID: nil, label: "r")
        let open = try #require(try await store.item(id: "id-1"))
        #expect(open.status == .open && open.doneAt == nil)
    }

    @Test func repeatingItemsAreHandledPerOccurrence() async throws {
        let store = try makeStore()
        try await seedWeekly(store)
        let range = day("2026-10-05") ... day("2026-10-26")

        _ = try await store.apply(MutationPlan(actions: [
            .complete(itemID: "id-1", occurrenceDate: day("2026-10-05")),
            .skipOccurrence(itemID: "id-1", occurrenceDate: day("2026-10-12")),
            .moveOccurrence(itemID: "id-1", occurrenceDate: day("2026-10-19"), newDate: day("2026-10-21"), newTime: LocalTime("16:00")),
        ]), source: .voice, memoID: nil, label: "occurrences")

        let agenda = try await store.agenda(in: range)
        #expect(agenda.map { $0.date.description } == ["2026-10-05", "2026-10-21", "2026-10-26"])
        #expect(agenda.map(\.isDone) == [true, false, false])
        #expect(agenda[1].time == LocalTime("16:00") && agenda[1].wasMoved)

        let reopened = try await store.apply(MutationPlan(actions: [.reopen(itemID: "id-1", occurrenceDate: day("2026-10-05"))]),
                                             source: .voice, memoID: nil, label: "reopen")
        #expect(try await store.agenda(in: range).first?.isDone == false)
        try await store.undo(opID: try #require(reopened.op).id)
        #expect(try await store.agenda(in: range).first?.isDone == true)
    }

    /// The key of an override is the day the rule generated, which is also what a moved entry carries as its occurrence date.
    /// Ticking off a moved occurrence must keep the move (the entry stays where it is, done), not replace it by a plain
    /// "done" on the rule's day, which made it vanish from the day it stood on.
    @Test func aMovedOccurrenceIsTickedOffWhereItStands() async throws {
        let store = try makeStore()
        try await seedWeekly(store)
        let range = day("2026-10-05") ... day("2026-10-26")
        _ = try await store.apply(MutationPlan(actions: [
            .moveOccurrence(itemID: "id-1", occurrenceDate: day("2026-10-19"), newDate: day("2026-10-21"), newTime: LocalTime("16:00")),
        ]), source: .voice, memoID: nil, label: "move")

        let done = try await store.apply(MutationPlan(actions: [.complete(itemID: "id-1", occurrenceDate: day("2026-10-19"))]),
                                         source: .voice, memoID: nil, label: "complete")
        var agenda = try await store.agenda(in: range)
        #expect(agenda.map { $0.date.description } == ["2026-10-05", "2026-10-12", "2026-10-21", "2026-10-26"])
        #expect(agenda[2].isDone && agenda[2].wasMoved && agenda[2].time == LocalTime("16:00") && agenda[2].occurrenceDate == day("2026-10-19"))

        let reopened = try await store.apply(MutationPlan(actions: [.reopen(itemID: "id-1", occurrenceDate: day("2026-10-19"))]),
                                             source: .voice, memoID: nil, label: "reopen")
        agenda = try await store.agenda(in: range)
        #expect(agenda[2].date == day("2026-10-21") && !agenda[2].isDone && agenda[2].wasMoved) // still moved, open again

        try await store.undo(opID: try #require(reopened.op).id)
        #expect(try await store.agenda(in: range)[2].isDone)
        try await store.undo(opID: try #require(done.op).id)
        agenda = try await store.agenda(in: range)
        #expect(agenda[2].date == day("2026-10-21") && !agenda[2].isDone && agenda[2].wasMoved)
    }

    @Test func aDoneOccurrenceStaysDoneWhenItIsMoved() async throws {
        let store = try makeStore()
        try await seedWeekly(store)
        let range = day("2026-10-05") ... day("2026-10-26")
        _ = try await store.apply(MutationPlan(actions: [.complete(itemID: "id-1", occurrenceDate: day("2026-10-12"))]), source: .voice, memoID: nil, label: "c")
        let moved = try await store.apply(MutationPlan(actions: [
            .moveOccurrence(itemID: "id-1", occurrenceDate: day("2026-10-12"), newDate: day("2026-10-14"), newTime: nil),
        ]), source: .voice, memoID: nil, label: "m")
        var agenda = try await store.agenda(in: range)
        #expect(agenda.map { $0.date.description } == ["2026-10-05", "2026-10-14", "2026-10-19", "2026-10-26"])
        #expect(agenda[1].isDone && agenda[1].wasMoved)
        try await store.undo(opID: try #require(moved.op).id)
        agenda = try await store.agenda(in: range)
        #expect(agenda[1].date == day("2026-10-12") && agenda[1].isDone && !agenda[1].wasMoved)
    }

    /// An answer can change one entry in two steps ("rename the call and move it to Friday" as two updates). Undo checks a
    /// row against the last change made to it, so the operation can be undone.
    @Test func anOperationThatChangedOneRowTwiceCanBeUndone() async throws {
        let store = try makeStore()
        try await store.perform(label: "seed") { try $0.insert(Item(id: "", kind: .event, title: "Созвон", date: day("2026-10-01"), time: LocalTime("11:00"), source: .manual)) }
        let result = try await store.apply(MutationPlan(actions: [
            .update(itemID: "id-1", changes: ItemChanges(title: "Созвон с Acme")),
            .update(itemID: "id-1", changes: ItemChanges(date: day("2026-10-02"))),
        ]), source: .voice, memoID: nil, label: "two steps")
        let changed = try #require(try await store.item(id: "id-1"))
        #expect(changed.title == "Созвон с Acme" && changed.date == day("2026-10-02"))
        try await store.undo(opID: try #require(result.op).id)
        let back = try #require(try await store.item(id: "id-1"))
        #expect(back.title == "Созвон" && back.date == day("2026-10-01"))
        // a later edit of the row still blocks the undo of an earlier operation
        let again = try await store.apply(MutationPlan(actions: [.update(itemID: "id-1", changes: ItemChanges(title: "Первое"))]), source: .voice, memoID: nil, label: "a")
        _ = try await store.apply(MutationPlan(actions: [.update(itemID: "id-1", changes: ItemChanges(title: "Второе"))]), source: .voice, memoID: nil, label: "b")
        await #expect(throws: StoreError.self) { try await store.undo(opID: try #require(again.op).id) }
    }

    @Test func seriesEditsChangeTheWholeSeries() async throws {
        let store = try makeStore()
        try await seedWeekly(store)
        _ = try await store.apply(MutationPlan(actions: [
            .update(itemID: "id-1", changes: ItemChanges(title: "Стендап", time: LocalTime("09:30"))),
        ]), source: .voice, memoID: nil, label: "series")
        let agenda = try await store.agenda(in: day("2026-10-05") ... day("2026-10-19"))
        #expect(agenda.map(\.item.title) == ["Стендап", "Стендап", "Стендап"])
        #expect(agenda.allSatisfy { $0.time == LocalTime("09:30") })
    }

    @Test func deletedItemsCannotBeEditedAgain() async throws {
        let store = try makeStore()
        try await store.perform(label: "seed") { try $0.insert(Item(id: "", kind: .task, title: "Дело", source: .manual)) }
        _ = try await store.apply(MutationPlan(actions: [.delete(itemID: "id-1")]), source: .voice, memoID: nil, label: "d")
        await #expect(throws: StoreError.itemNotFound("id-1")) {
            try await store.apply(MutationPlan(actions: [.update(itemID: "id-1", changes: ItemChanges(title: "x"))]), source: .voice, memoID: nil, label: "u")
        }
    }
}

@Suite("RussianFormat")
struct RussianFormatTests {
    @Test func formatsDatesAndRelativeDays() {
        let today = day("2026-09-28")
        #expect(RussianFormat.date(day("2026-09-30")) == "30 сентября")
        #expect(RussianFormat.dateWithWeekday(day("2026-09-30")) == "ср, 30 сентября")
        #expect(RussianFormat.relativeDay(today, today: today) == "сегодня")
        #expect(RussianFormat.relativeDay(day("2026-09-29"), today: today) == "завтра")
        #expect(RussianFormat.relativeDay(day("2026-09-30"), today: today) == "послезавтра")
        #expect(RussianFormat.relativeDay(day("2026-10-02"), today: today) == "в пятницу, 2 октября")
        #expect(RussianFormat.relativeDay(day("2026-10-13"), today: today) == "13 октября")
        #expect(RussianFormat.relativeDay(day("2026-09-20"), today: today) == "20 сентября")
    }

    @Test func picksTheRightPluralForm() {
        let forms = ("запись", "записи", "записей")
        for (count, word) in [(1, "запись"), (2, "записи"), (4, "записи"), (5, "записей"), (11, "записей"), (12, "записей"),
                              (21, "запись"), (22, "записи"), (25, "записей"), (101, "запись"), (111, "записей")] {
            #expect(RussianFormat.plural(count, forms) == word, "count \(count)")
        }
    }
}
