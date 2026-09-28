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
        try m.insert(Item(id: "", kind: .event, title: "Созвон с Фигма", date: day("2026-09-28"), time: LocalTime("16:00"), source: .voice))
        try m.insert(Item(id: "", kind: .reminder, title: "Оплатить инвойс", date: day("2026-09-30"), source: .voice))
        try m.insert(Item(id: "", kind: .reminder, title: "Просроченное", date: day("2026-09-20"), source: .voice))
        try m.insert(Item(id: "", kind: .note, title: "Идея про пуши", source: .voice))
        try m.insert(Item(id: "", kind: .event, title: "Встреча", date: day("2026-10-01"), time: LocalTime("12:00"), source: .voice))
    }
    return store
}

@Suite("Store.run (queries)")
struct QueryExecutorTests {
    @Test func aDayShowsOneOffsAndOccurrencesInOrder() async throws {
        let store = try await seeded()
        let result = try await store.run(QueryPlan(target: .days(day("2026-09-28") ... day("2026-09-28"))), now: now)
        #expect(result.entries.map(\.item.title) == ["Планёрка", "Созвон с Фигма"])
        #expect(result.title == "сегодня")
    }

    @Test func rangesAreLabelled() async throws {
        let store = try await seeded()
        let result = try await store.run(QueryPlan(target: .days(day("2026-09-28") ... day("2026-10-04"))), now: now)
        #expect(result.entries.count == 4)
        #expect(result.title == "с 28 сентября по 4 октября")
    }

    @Test func upcomingSkipsWhatAlreadyHappenedToday() async throws {
        let store = try await seeded()
        let result = try await store.run(QueryPlan(target: .upcoming(limit: 3)), now: now)
        #expect(result.entries.map(\.item.title) == ["Созвон с Фигма", "Оплатить инвойс", "Встреча"])
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
        try await store.save(term: GlossaryTerm(canonical: "Figma", aliases: ["фигма", "фигмы"]))
        for query in ["Figma", "фигма", "про Figma"] {
            let result = try await store.run(QueryPlan(target: .search(query)), now: now)
            #expect(result.entries.map(\.item.title) == ["Созвон с Фигма"], "query \(query)")
        }
        try await store.perform(label: "latin") { m in
            try m.insert(Item(id: "", kind: .reminder, title: "Проверить подписку Figma", date: day("2026-10-02"), source: .voice))
        }
        let both = try await store.run(QueryPlan(target: .search("Figma")), now: now)
        #expect(Set(both.entries.map(\.item.title)) == ["Созвон с Фигма", "Проверить подписку Figma"])
        #expect(try await store.run(QueryPlan(target: .search("несуществующее")), now: now).entries.isEmpty)
    }

    @Test func changesAreStreamedToObservers() async throws {
        let store = try makeStore()
        let count = Mutex(0)
        let observer = Task {
            for await _ in store.changes() { count.withLock { $0 += 1 } }
        }
        try await Task.sleep(for: .milliseconds(200))
        let initial = count.withLock { $0 }
        #expect(initial >= 1)
        try await store.perform(label: "add") { try $0.insert(Item(id: "", kind: .task, title: "Дело", source: .manual)) }
        try await Task.sleep(for: .milliseconds(300))
        #expect(count.withLock { $0 } > initial)
        observer.cancel()
    }
}
