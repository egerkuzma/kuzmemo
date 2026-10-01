import Foundation
import Synchronization
import Testing
@testable import KuzmemoCore

private func day(_ s: String) -> LocalDate { LocalDate(s)! }
private let now = LocalDateTime(date: LocalDate("2026-09-28")!, time: LocalTime("14:30")!)

private func seeded() async throws -> Store {
    let store = try makeStore()
    var weekly = Item(id: "", kind: .event, title: "Планёрка", date: day("2026-09-28"), time: LocalTime("10:00"), source: .voice)
    weekly.recurrence = Recurrence(freq: .weekly, byWeekday: [.mon])
    let planning = weekly
    try await store.perform(label: "seed") { m in
        try m.insert(planning)
        try m.insert(Item(id: "", kind: .event, title: "Созвон с Акме", date: day("2026-09-28"), time: LocalTime("16:00"), source: .voice))
        try m.insert(Item(id: "", kind: .reminder, title: "Оплатить инвойс", date: day("2026-09-30"), source: .voice))
        try m.insert(Item(id: "", kind: .reminder, title: "Просроченное", date: day("2026-09-20"), source: .voice))
        try m.insert(Item(id: "", kind: .note, title: "Идея про пуши", source: .voice))
        try m.insert(Item(id: "", kind: .event, title: "Встреча", date: day("2026-10-01"), time: LocalTime("12:00"), source: .voice))
    }
    return store
}

@Suite("Store.run (queries)")
struct QueryExecutorTests {
    @Test func aDayShowsWhatIsStillAheadOfOneOffsAndOccurrences() async throws {
        let store = try await seeded()
        let result = try await store.run(QueryPlan(target: .days(day("2026-09-28") ... day("2026-09-28"))), now: now)
        #expect(result.entries.map(\.item.title) == ["Созвон с Акме"]) // the 10:00 stand-up has passed at 14:30
        #expect(result.passedToday == 1)
        #expect(result.title == "сегодня")
        // asking for the whole day, done things included, keeps what has passed
        let whole = try await store.run(QueryPlan(target: .days(day("2026-09-28") ... day("2026-09-28")), includeDone: true), now: now)
        #expect(whole.entries.map(\.item.title) == ["Планёрка", "Созвон с Акме"] && whole.passedToday == 0)
    }

    @Test func whatHasPassedTodayIsLeftOutButAllDayThingsAndEventsInProgressStay() async throws {
        let store = try makeStore()
        var inProgress = Item(id: "", kind: .event, title: "Идёт сейчас", date: day("2026-09-28"), time: LocalTime("14:00"), source: .voice)
        inProgress.durationMin = 60 // until 15:00
        let ongoing = inProgress
        try await store.perform(label: "seed") { m in
            try m.insert(Item(id: "", kind: .reminder, title: "Вчера", date: day("2026-09-27"), time: LocalTime("10:00"), source: .voice))
            try m.insert(Item(id: "", kind: .reminder, title: "Утром", date: day("2026-09-28"), time: LocalTime("09:00"), source: .voice))
            try m.insert(Item(id: "", kind: .reminder, title: "Ровно сейчас", date: day("2026-09-28"), time: LocalTime("14:30"), source: .voice))
            try m.insert(ongoing)
            try m.insert(Item(id: "", kind: .reminder, title: "Вечером", date: day("2026-09-28"), time: LocalTime("18:00"), source: .voice))
            try m.insert(Item(id: "", kind: .reminder, title: "Весь день", date: day("2026-09-28"), source: .voice))
        }
        let today = try await store.run(QueryPlan(target: .days(day("2026-09-28") ... day("2026-09-28"))), now: now)
        #expect(today.entries.map(\.item.title) == ["Весь день", "Идёт сейчас", "Вечером"])
        #expect(today.passedToday == 2)
        // an earlier day in the range is a question about the past: nothing is hidden from it
        let both = try await store.run(QueryPlan(target: .days(day("2026-09-27") ... day("2026-09-28"))), now: now)
        #expect(both.entries.map(\.item.title) == ["Вчера", "Весь день", "Идёт сейчас", "Вечером"] && both.passedToday == 2)
        let tomorrow = try await store.run(QueryPlan(target: .days(day("2026-09-29") ... day("2026-09-29"))), now: now)
        #expect(tomorrow.entries.isEmpty && tomorrow.passedToday == 0)
    }

    @Test func anEntryHasPassedWhenItsTimeIsBehind() {
        func entry(_ time: String?, duration: Int? = nil, date: String = "2026-09-28") -> AgendaEntry {
            var item = Item(id: "x", kind: .event, title: "x", date: day(date), time: time.flatMap(LocalTime.init), source: .voice)
            item.durationMin = duration
            return AgendaEntry(item: item, date: day(date), time: item.time, isDone: false, occurrenceDate: nil, wasMoved: false)
        }
        #expect(entry("14:29").hasPassed(at: now) && entry("14:30").hasPassed(at: now))
        #expect(!entry("14:31").hasPassed(at: now))
        #expect(!entry("14:00", duration: 60).hasPassed(at: now)) // still running until 15:00
        #expect(entry("14:00", duration: 30).hasPassed(at: now)) // ended at 14:30
        #expect(!entry(nil).hasPassed(at: now)) // all-day
        #expect(entry(nil, date: "2026-09-27").hasPassed(at: now)) // an earlier day
        #expect(!entry("09:00", date: "2026-09-29").hasPassed(at: now)) // tomorrow
        #expect(!entry("23:30", duration: 120).hasPassed(at: LocalDateTime(date: day("2026-09-28"), time: LocalTime("23:59")!)))
    }

    @Test func rangesAreLabelled() async throws {
        let store = try await seeded()
        let result = try await store.run(QueryPlan(target: .days(day("2026-09-28") ... day("2026-10-04"))), now: now)
        #expect(result.entries.count == 3 && result.passedToday == 1)
        #expect(result.title == "с 28 сентября по 4 октября")
    }

    @Test func upcomingSkipsWhatAlreadyHappenedToday() async throws {
        let store = try await seeded()
        let result = try await store.run(QueryPlan(target: .upcoming(limit: 3)), now: now)
        #expect(result.entries.map(\.item.title) == ["Созвон с Акме", "Оплатить инвойс", "Встреча"])
        let first = try await store.run(QueryPlan(target: .upcoming(limit: 1), detail: .first), now: now)
        #expect(first.entries.count == 1)
    }

    @Test func overdueInboxAndRecurring() async throws {
        let store = try await seeded()
        #expect(try await store.run(QueryPlan(target: .overdue), now: now).entries.map(\.item.title) == ["Просроченное"])
        #expect(try await store.run(QueryPlan(target: .inbox), now: now).entries.map(\.item.title) == ["Идея про пуши"])
        #expect(try await store.run(QueryPlan(target: .recurring), now: now).entries.map(\.item.title) == ["Планёрка"])
    }

    @Test func searchFindsEntriesTypedInEitherScriptThroughGlossaryAliases() async throws {
        let store = try await seeded()
        try await store.save(term: GlossaryTerm(canonical: "Acme", aliases: ["акме", "акме"]))
        for query in ["Acme", "акме", "про Acme"] {
            let result = try await store.run(QueryPlan(target: .search(query)), now: now)
            #expect(result.entries.map(\.item.title) == ["Созвон с Акме"], "query \(query)")
        }
        try await store.perform(label: "latin") { m in
            try m.insert(Item(id: "", kind: .reminder, title: "Проверить подписку Acme", date: day("2026-10-02"), source: .voice))
        }
        let both = try await store.run(QueryPlan(target: .search("Acme")), now: now)
        #expect(Set(both.entries.map(\.item.title)) == ["Созвон с Акме", "Проверить подписку Acme"])
        #expect(try await store.run(QueryPlan(target: .search("несуществующее")), now: now).entries.isEmpty)
    }

    @Test func changesAreStreamedToObservers() async throws {
        let store = try makeStore()
        let count = Mutex(0)
        let observer = Task {
            for await _ in store.changes() { count.withLock { $0 += 1 } }
        }
        // polled rather than slept: a loaded machine can take a while to deliver the first value
        func wait(until condition: () -> Bool) async throws {
            for _ in 0 ..< 100 where !condition() { try await Task.sleep(for: .milliseconds(30)) }
        }
        try await wait { count.withLock { $0 } >= 1 }
        let initial = count.withLock { $0 }
        #expect(initial >= 1)
        try await store.perform(label: "add") { try $0.insert(Item(id: "", kind: .task, title: "Дело", source: .manual)) }
        try await wait { count.withLock { $0 } > initial }
        #expect(count.withLock { $0 } > initial)
        observer.cancel()
    }

    /// A read that fails ends GRDB's observation. The stream used to end with it, and every window stayed frozen on what it
    /// last showed until the app was restarted.
    @Test func theStreamOfChangesComesBackAfterAFailedRead() async throws {
        let store = try makeStore()
        try await store.writer.write { try $0.execute(sql: "ALTER TABLE memos RENAME TO memos_away") } // the observation cannot read
        let delivered = Mutex(0)
        let ended = Mutex(false)
        let observer = Task {
            for await _ in store.changes(retryAfter: .milliseconds(40)) { delivered.withLock { $0 += 1 } }
            ended.withLock { $0 = true }
        }
        try await Task.sleep(for: .milliseconds(300)) // it has failed by now, and again after each pause
        #expect(delivered.withLock { $0 } == 0)
        #expect(!ended.withLock { $0 }, "the stream ended with the failed read")
        try await store.writer.write { try $0.execute(sql: "ALTER TABLE memos_away RENAME TO memos") }
        for _ in 0 ..< 100 where delivered.withLock({ $0 }) == 0 { try await Task.sleep(for: .milliseconds(30)) }
        #expect(delivered.withLock { $0 } >= 1, "nothing arrived once the read worked again")
        observer.cancel()
    }
}
