import Foundation
import GRDB
import Testing
@testable import KuzmemoCore

@Suite("Review regressions: snapshots, clearing and elapsed time")
struct ReviewRegressionTests {
    private func validate(_ actions: [[String: Any]], context: ContextPlan, store: Store) async throws -> MutationPlan {
        let data = try JSONSerialization.data(withJSONObject: ["intent": "update", "confidence": 0.9, "actions": actions])
        let response = try JSONDecoder().decode(ParserResponse.self, from: data)
        let result = await ActionValidator.validate(response, in: ValidationContext(
            context: context, resolver: RelativeDateResolver(anchor: store.clock.localNow(), timeZone: store.clock.timeZone), store: store
        ))
        switch result {
        case let .mutate(plan): return plan
        case let .clarify(question): return try #require(question.pending)
        default: Issue.record("expected a plan: \(result)"); throw CocoaError(.fileReadUnknown)
        }
    }

    @Test(arguments: [false, true]) func mixedSnapshotsOfOneTargetNeverPassTheGuard(reverse: Bool) async throws {
        let store = try makeStore()
        let made = try await store.create(ItemDraft(kind: .event, title: "Встреча с Дмитрием", date: LocalDate("2026-09-29"), time: LocalTime("10:00")))
        let context = try await ContextPlanner().plan(transcript: "перенеси встречу с Дмитрием", anchor: store.clock.localNow(), store: store)
        var fresh = ItemDraft(made.item); fresh.time = LocalTime("15:00")
        try await store.save(fresh, as: made.item.id)
        let ref: [String: Any] = ["op": "update", "ref": 1, "changes": ["when": ["mode": "none", "time": "11:00"]]]
        let hint: [String: Any] = ["op": "update", "target_hint": "Дмитрием", "changes": ["title": "Встреча с Дмитрием по проекту"]]
        let plan = try await validate(reverse ? [hint, ref] : [ref, hint], context: context, store: store)
        await #expect(throws: StoreError.changedMeanwhile(made.item.id)) {
            try await store.apply(plan, source: .voice, memoID: nil, label: "stale")
        }
        #expect(try await store.item(id: made.item.id)?.time == LocalTime("15:00"))
    }

    @Test func evenAnActionDiscardedBySettleCannotRefreshAnOldDeletion() async throws {
        let store = try makeStore()
        let made = try await store.create(ItemDraft(title: "Дмитрием", date: LocalDate("2026-09-29")))
        let context = try await ContextPlanner().plan(transcript: "удали Дмитрием", anchor: store.clock.localNow(), store: store)
        var fresh = ItemDraft(made.item); fresh.details = "new information"
        try await store.save(fresh, as: made.item.id)
        let plan = try await validate([
            ["op": "delete", "ref": 1], ["op": "complete", "target_hint": "Дмитрием"],
        ], context: context, store: store)
        #expect(plan.actions.count == 1)
        await #expect(throws: StoreError.changedMeanwhile(made.item.id)) {
            try await store.apply(plan, source: .voice, memoID: nil, label: "stale")
        }
        #expect(try await store.item(id: made.item.id) != nil)
    }

    @Test func explicitClearingIsAppliedAndCanBeUndone() async throws {
        let store = try makeStore()
        let made = try await store.create(ItemDraft(kind: .event, title: "Созвон", details: "old", date: LocalDate("2026-09-29"), time: LocalTime("10:00"), durationMin: 30, remindLeadMin: 5))
        let context = try await ContextPlanner().plan(transcript: "убери время созвона", anchor: store.clock.localNow(), store: store)
        let plan = try await validate([["op": "update", "ref": 1, "changes": ["clear": ["time", "details"]]]], context: context, store: store)
        let result = try await store.apply(plan, source: .voice, memoID: nil, label: "clear")
        let item = try #require(try await store.item(id: made.item.id))
        #expect(item.time == nil && item.details == nil && item.durationMin == nil && item.remindLeadMin == 0)
        #expect(item.date == made.item.date)
        try await store.undo(opID: try #require(result.op).id)
        #expect(try await store.item(id: made.item.id)?.time == made.item.time)
        #expect(try await store.item(id: made.item.id)?.details == "old")
        // A saved plan from before `clear` existed still decodes with its original meaning.
        let old = try JSONDecoder().decode(ItemChanges.self, from: Data(#"{"title":"New"}"#.utf8))
        #expect(old.clear == nil && old.title == "New")
    }

    @Test func clearingAnOccurrencesTimeSurvivesDoneReopenMoveAndUndo() async throws {
        let store = try makeStore()
        let made = try await store.create(ItemDraft(kind: .event, title: "Планёрка", date: LocalDate("2026-09-29"), time: LocalTime("10:00"), recurrence: Recurrence(freq: .daily)))
        let context = try await ContextPlanner().plan(transcript: "убери время планёрки", anchor: store.clock.localNow(), store: store)
        let occurrence = try #require(context.entries.first?.occurrenceDate)
        let plan = try await validate([["op": "update", "ref": 1, "changes": ["clear": ["time"]]]], context: context, store: store)
        let result = try await store.apply(plan, source: .voice, memoID: nil, label: "all-day occurrence")
        #expect(try await store.agenda(on: occurrence).first?.time == nil)
        #expect(try await store.item(id: made.item.id)?.time == LocalTime("10:00"))
        var laterOps: [String] = []
        for action in [PlannedAction.complete(itemID: made.item.id, occurrenceDate: occurrence), .reopen(itemID: made.item.id, occurrenceDate: occurrence)] {
            let ticked = try await store.perform(action, label: "tick")
            laterOps.append(try #require(ticked.op).id)
            #expect(try await store.agenda(on: occurrence).first?.time == nil)
        }
        let movedDate = occurrence.adding(days: 2)
        let moved = try await store.perform(.moveOccurrence(itemID: made.item.id, occurrenceDate: occurrence, newDate: movedDate, newTime: nil), label: "move all-day")
        laterOps.append(try #require(moved.op).id)
        #expect(try await store.agenda(on: movedDate).first { $0.occurrenceDate == occurrence }?.time == nil)
        // Undo the later actions first, then the clearing itself.
        for id in laterOps.reversed() { try await store.undo(opID: id) }
        try await store.undo(opID: try #require(result.op).id)
        #expect(try await store.agenda(on: occurrence).first?.time == LocalTime("10:00"))
    }

    @Test func clearingADateAlsoClearsItsTimeAndRecurrence() {
        var item = Item(id: "i", kind: .event, title: "x", date: LocalDate("2026-09-29"), time: LocalTime("10:00"), recurrence: Recurrence(freq: .daily))
        ItemChanges(clear: [.date]).apply(to: &item)
        #expect(item.date == nil && item.time == nil && item.recurrence == nil)
    }

    @Test func contextReservesSpaceForEachFoundTargetBeforeExtraOccurrences() {
        var entries: [AgendaEntry] = []
        for day in 0 ..< 15 {
            for id in ["a", "b", "c"] {
                let date = LocalDate("2026-09-29")!.adding(days: day)
                entries.append(AgendaEntry(item: Item(id: id, kind: .event, title: id), date: date, time: nil, isDone: false, occurrenceDate: date, wasMoved: false))
            }
        }
        entries.append(AgendaEntry(item: Item(id: "d", kind: .event, title: "D"), date: LocalDate("2026-11-01")!, time: nil, isDone: false, occurrenceDate: nil, wasMoved: false))
        let cut = ContextPlanner.cut(entries, to: 40, keeping: ["a", "b", "c", "d"])
        #expect(cut.count == 40 && Set(cut.map(\.item.id)) == ["a", "b", "c", "d"])
        #expect(ContextPlanner.cut(entries, to: 0, keeping: ["a"]).isEmpty)
    }

    @Test(arguments: [("2026-03-29 01:30", 120, "2026-03-29 04:30"), ("2026-10-25 02:30", 30, "2026-10-25 02:00")])
    func minutesAreElapsedTimeAcrossBothClockChanges(input: String, minutes: Int, expected: String) {
        let zone = TimeZone(identifier: "Europe/Berlin")!
        let clock = FixedNow(local: input, in: zone)!
        let resolver = RelativeDateResolver(anchor: clock.localNow(), timeZone: zone)
        let result = resolver.resolve(When(mode: .minutesFromNow, minutesFromNow: minutes))
        let expectedClock = FixedNow(local: expected, in: zone)!
        #expect(result.date == expectedClock.localNow().date && result.time == expectedClock.localNow().time)
        #expect(result.issues.isEmpty)
    }

    @Test func alertLeadIsElapsedTimeAcrossTheSpringClockChange() {
        let zone = TimeZone(identifier: "Europe/Berlin")!
        let item = Item(id: "i", kind: .event, title: "x", date: LocalDate("2026-03-29"), time: LocalTime("03:30"))
        let entry = AgendaEntry(item: item, date: item.date!, time: item.time, isDone: false, occurrenceDate: nil, wasMoved: false)
        var settings = NotificationSettings(); settings.eventLeads = [120, 0]
        let start = FixedNow(local: "2026-03-29 03:30", in: zone)!.now()
        let alerts = AlertPlanner.plan(entries: [entry], settings: settings, now: start.addingTimeInterval(-10800), timeZone: zone)
        #expect(alerts.count == 2 && alerts[0].fireAt == start.addingTimeInterval(-7200))
        #expect(LocalDateTime(date: alerts[0].fireAt, in: zone).time == LocalTime("00:30"))
    }
}

extension ReviewRegressionTests {
    @Test func anElapsedReminderKeepsItsInstantAcrossATimeZoneChangeAndAnEditorSave() async throws {
        let origin = TimeZone(identifier: "Pacific/Honolulu")!
        let destination = TimeZone(identifier: "Pacific/Kiritimati")!
        let moment = FixedNow(local: "2026-09-28 23:50", in: origin)!.now()
        let timestamp = Int64(moment.timeIntervalSince1970 * 1000)
        let clock = FixedNow(moment.addingTimeInterval(-600), timeZone: destination)
        let store = Store(writer: try KuzmemoDatabase.inMemory(), clock: clock)
        let made = try await store.perform(.create(NewItem(kind: .reminder, title: "Перелёт", date: LocalDate("2026-09-28"), time: LocalTime("23:50"), scheduledAt: timestamp)), label: "create")
        let id = try #require(made.changes.first?.item.id)
        let shown = LocalDateTime(date: moment, in: destination)
        let agenda = try await store.agenda(on: shown.date)
        #expect(agenda.count == 1 && agenda.first?.time == shown.time)
        let snapshot = try #require(try await store.itemSnapshot(id: id))
        var draft = ItemDraft(snapshot.item); draft.title = "Перелёт домой"
        try await store.save(draft, as: id, expectingRevision: snapshot.revision)
        #expect(try await store.item(id: id)?.scheduledAt == timestamp)
        let search = try await store.searchSnapshot("Перелёт")
        #expect(search.items.first?.date == shown.date && search.items.first?.time == shown.time)
        draft.time = LocalTime("12:00")
        try await store.save(draft, as: id)
        #expect(try await store.item(id: id)?.scheduledAt == nil)
    }

    @Test(arguments: [(false, 30), (true, 10)])
    func aRelativeReminderKeepsItsInstantThroughStorageQueriesAndPlanning(secondReading: Bool, minutes: Int) async throws {
        let zone = TimeZone(identifier: "Europe/Berlin")!
        let first = FixedNow(local: "2026-10-25 02:30", in: zone)!.now()
        let spoken = first.addingTimeInterval(secondReading ? 3600 : 0)
        let clock = FixedNow(spoken, timeZone: zone)
        let store = Store(writer: try KuzmemoDatabase.inMemory(), clock: clock)
        let json = "{\"intent\":\"create\",\"confidence\":0.9,\"actions\":[{\"op\":\"create\",\"item\":{\"kind\":\"reminder\",\"title\":\"Тест\",\"when\":{\"mode\":\"minutes_from_now\",\"minutes_from_now\":\(minutes)}}}]}"
        let provider = ScriptedProvider([.json(json)])
        let processor = MemoProcessor(store: store, interpreter: Interpreter(store: store, provider: provider), clock: clock)
        let outcome = await processor.submit(text: "напомни через \(minutes) минут", inputKind: .text)
        guard case .applied = outcome.kind else { Issue.record("expected applied: \(outcome.kind)"); return }
        let agenda = try await store.agenda(on: clock.localNow().date)
        let reminder = try #require(agenda.first)
        let expected = spoken.addingTimeInterval(TimeInterval(minutes * 60))
        #expect(reminder.scheduledAt == Int64(expected.timeIntervalSince1970 * 1000))
        var settings = NotificationSettings(); settings.reminderLeads = [0]
        let alerts = AlertPlanner.plan(entries: agenda, settings: settings, now: spoken, timeZone: zone)
        #expect(alerts.first?.fireAt == expected)
        let query = try await store.run(QueryPlan(target: .days(clock.localNow().date...clock.localNow().date)), now: clock.localNow())
        #expect(query.entries.count == 1 && query.passedToday == 0)
        let upcoming = try await store.run(QueryPlan(target: .upcoming(limit: 10)), now: clock.localNow())
        #expect(upcoming.entries.count == 1 && upcoming.entries.first?.scheduledAt == reminder.scheduledAt)
        // Old saved occurrence plans still decode after the optional instant/clear-time fields were added.
        let old = try JSONDecoder().decode(PlannedAction.self, from: Data(#"{"moveOccurrence":{"itemID":"i","occurrenceDate":"2026-10-25","newDate":"2026-10-26","newTime":"10:00"}}"#.utf8))
        #expect(old == .moveOccurrence(itemID: "i", occurrenceDate: LocalDate("2026-10-25")!, newDate: LocalDate("2026-10-26")!, newTime: LocalTime("10:00")))
    }
}
