import Foundation
import GRDB
import Synchronization
import Testing
@testable import KuzmemoCore

final class IDSequence: Sendable {
    private let counter = Mutex(0)
    func next() -> String { counter.withLock { value in value += 1; return "id-\(value)" } }
}

func makeStore(now: String = "2026-09-28 14:30") throws -> Store {
    let clock = FixedNow(local: now, in: TimeZone(identifier: "Europe/Moscow")!)!
    let ids = IDSequence()
    return Store(writer: try KuzmemoDatabase.inMemory(), clock: clock, makeID: { ids.next() })
}

func reminder(_ title: String, on date: String? = nil, at time: String? = nil, details: String? = nil) -> Item {
    Item(
        id: "", kind: .reminder, title: title, details: details,
        date: date.flatMap(LocalDate.init), time: time.flatMap(LocalTime.init), source: .voice
    )
}

@Suite("Store: writes, journal and undo")
struct StoreJournalTests {
    @Test func insertRoundTripsEveryField() async throws {
        let store = try makeStore()
        var item = reminder("Сказать Дмитрию про доступ", on: "2026-09-30", at: "09:00", details: "по Notion")
        item.recurrence = Recurrence(freq: .weekly, interval: 2, byWeekday: [.mon, .fri], until: LocalDate("2027-01-01"), count: 5)
        item.durationMin = 30
        item.approximate = true
        item.keywords = "доступ notion"
        let seed = item
        let op = try await store.perform(label: "create") { try $0.insert(seed) }
        #expect(op?.label == "create")

        // recurring items are not returned by the one-off day query
        #expect(try await store.items(on: LocalDate("2026-09-30")!).isEmpty)
        let series = try await store.recurringSeries()
        #expect(series.count == 1)
        let fetched = try #require(series.first)
        #expect(fetched.id == "id-1")
        #expect(fetched.recurrence == item.recurrence)
        #expect(fetched.time == LocalTime("09:00"))
        #expect(fetched.durationMin == 30 && fetched.approximate && fetched.keywords == "доступ notion")
        #expect(fetched.createdAt == 1_790_595_000_000 && fetched.version == 1)
    }

    @Test func dayQueryOrdersAllDayFirstThenByTime() async throws {
        let store = try makeStore()
        try await store.perform(label: "seed") { m in
            try m.insert(reminder("вечер", on: "2026-09-30", at: "19:00"))
            try m.insert(reminder("весь день", on: "2026-09-30"))
            try m.insert(reminder("утро", on: "2026-09-30", at: "09:30"))
            try m.insert(reminder("другой день", on: "2026-10-01", at: "08:00"))
        }
        let titles = try await store.items(on: LocalDate("2026-09-30")!).map(\.title)
        #expect(titles == ["весь день", "утро", "вечер"])
        let range = try await store.items(in: LocalDate("2026-09-30")!...LocalDate("2026-10-01")!).map(\.title)
        #expect(range == ["весь день", "утро", "вечер", "другой день"])
    }

    @Test func undoOfCreateRemovesTheItemAndItsSearchEntry() async throws {
        let store = try makeStore()
        let op = try #require(try await store.perform(label: "create") { try $0.insert(reminder("Купить молоко", on: "2026-09-30")) })
        #expect(try await store.search("молоко").count == 1)
        try await store.undo(opID: op.id)
        #expect(try await store.item(id: "id-1") == nil)
        #expect(try await store.search("молоко").isEmpty)
        #expect(try await store.lastUndoableOp() == nil)
    }

    @Test func undoOfUpdateRestoresThePreviousRow() async throws {
        let store = try makeStore()
        try await store.perform(label: "create") { try $0.insert(reminder("Встреча", on: "2026-10-01", at: "15:00")) }
        let op = try #require(try await store.perform(label: "move") { m in
            try m.update(id: "id-1") { $0.date = LocalDate("2026-10-02"); $0.title = "Встреча с Дмитрием" }
        })
        let moved = try #require(try await store.item(id: "id-1"))
        #expect(moved.date == LocalDate("2026-10-02") && moved.version == 2)
        try await store.undo(opID: op.id)
        let restored = try #require(try await store.item(id: "id-1"))
        #expect(restored.date == LocalDate("2026-10-01") && restored.title == "Встреча" && restored.version == 1)
        #expect(try await store.search("Дмитрием").isEmpty)
        #expect(try await store.search("встреча").count == 1)
    }

    @Test func undoRefusesToOverwriteNewerChanges() async throws {
        let store = try makeStore()
        try await store.perform(label: "create") { try $0.insert(reminder("A", on: "2026-10-01")) }
        let first = try #require(try await store.perform(label: "edit 1") { m in try m.update(id: "id-1") { $0.title = "B" } })
        let second = try #require(try await store.perform(label: "edit 2") { m in try m.update(id: "id-1") { $0.title = "C" } })
        await #expect(throws: StoreError.self) { try await store.undo(opID: first.id) }
        try await store.undo(opID: second.id)
        try await store.undo(opID: first.id)
        #expect(try await store.item(id: "id-1")?.title == "A")
        await #expect(throws: StoreError.alreadyUndone(second.id)) { try await store.undo(opID: second.id) }
    }

    @Test func throwingBodyRollsBackEverythingAndLeavesNoOp() async throws {
        let store = try makeStore()
        struct Boom: Error {}
        await #expect(throws: Boom.self) {
            try await store.perform(label: "will fail") { m in
                try m.insert(reminder("half done", on: "2026-10-01"))
                throw Boom()
            }
        }
        #expect(try await store.items(on: LocalDate("2026-10-01")!).isEmpty)
        #expect(try await store.lastUndoableOp() == nil)
    }

    @Test func noChangesProducesNoOp() async throws {
        let store = try makeStore()
        let op = try await store.perform(label: "nothing") { _ in }
        #expect(op == nil)
    }

    @Test func softDeleteHidesFromQueriesAndUndoBringsItBack() async throws {
        let store = try makeStore()
        try await store.perform(label: "create") { try $0.insert(reminder("Оплатить хостинг", on: "2026-10-25")) }
        let op = try #require(try await store.perform(label: "delete") { try $0.softDelete(id: "id-1") })
        #expect(try await store.items(on: LocalDate("2026-10-25")!).isEmpty)
        #expect(try await store.search("хостинг").isEmpty)
        #expect(try await store.item(id: "id-1") == nil)
        #expect(try await store.item(id: "id-1", includeDeleted: true) != nil)
        try await store.undo(opID: op.id)
        #expect(try await store.items(on: LocalDate("2026-10-25")!).count == 1)
        #expect(try await store.search("хостинг").count == 1)
    }

    @Test func undatedItemsLiveInTheInboxNewestFirst() async throws {
        let store = try makeStore()
        try await store.perform(label: "a") { try $0.insert(reminder("первая идея")) }
        try await store.perform(label: "b") { try $0.insert(reminder("вторая идея")) }
        try await store.perform(label: "c") { try $0.insert(reminder("датированная", on: "2026-10-01")) }
        let inbox = try await store.inbox().map(\.title)
        #expect(Set(inbox) == ["первая идея", "вторая идея"])
    }

    @Test func exceptionsAreJournaledAndUndoable() async throws {
        let store = try makeStore()
        var series = reminder("Планёрка", on: "2026-10-05", at: "10:00")
        series.recurrence = Recurrence(freq: .weekly, byWeekday: [.mon])
        let seedSeries = series
        try await store.perform(label: "create") { try $0.insert(seedSeries) }
        let op = try #require(try await store.perform(label: "skip") { m in
            try m.setException(ItemException(itemID: "id-1", occDate: LocalDate("2026-10-12")!, action: .skip))
        })
        #expect(try await store.exceptions(for: ["id-1"]).count == 1)
        try await store.undo(opID: op.id)
        #expect(try await store.exceptions(for: ["id-1"]).isEmpty)

        let removal = try await store.perform(label: "setup") { m in
            try m.setException(ItemException(itemID: "id-1", occDate: LocalDate("2026-10-19")!, action: .done))
        }
        let del = try #require(try await store.perform(label: "remove") { m in
            try m.removeException(itemID: "id-1", occDate: LocalDate("2026-10-19")!)
        })
        #expect(try await store.exceptions(for: ["id-1"]).isEmpty)
        try await store.undo(opID: del.id)
        #expect(try await store.exceptions(for: ["id-1"]).first?.action == .done)
        _ = removal
    }
}

@Suite("Store: search, memos, glossary, files")
struct StoreMiscTests {
    @Test func searchToleratesRussianWordEndingsAndCase() async throws {
        let store = try makeStore()
        try await store.perform(label: "seed") { m in
            try m.insert(reminder("Позвонить Дмитрию по доступу Notion", on: "2026-10-01"))
            try m.insert(reminder("Купить молоко", on: "2026-10-01"))
        }
        for query in ["Дмитрий", "дмитрия", "ДМИТРИЕМ", "доступ", "доступа", "notion", "Notion", "звонить", "позвонил"] {
            let hits = try await store.search(query).map(\.title)
            #expect(hits == ["Позвонить Дмитрию по доступу Notion"], "query \(query)")
        }
        #expect(try await store.search("Акме").isEmpty)
        #expect(try await store.search("дмитрий доступ").count == 1)
        #expect(try await store.search("дмитрий молоко").isEmpty)
        #expect(try await store.search("").isEmpty)
    }

    @Test func searchFoldsYoAndFallsBackForShortWords() async throws {
        let store = try makeStore()
        try await store.perform(label: "seed") { m in
            try m.insert(reminder("Ёлка на праздник", on: "2026-12-30"))
            try m.insert(reminder("Позвонить маме", on: "2026-10-01", details: "до обеда"))
        }
        #expect(try await store.search("елка").count == 1)
        #expect(try await store.search("ЁЛКА").count == 1)
        #expect(try await store.search("до").map(\.title) == ["Позвонить маме"])
    }

    @Test func memosPersistAndUnfinishedOnesAreListed() async throws {
        let store = try makeStore()
        func memo(_ id: String, _ status: MemoStatus, at created: Int64) -> Memo {
            Memo(id: id, createdAt: created, anchorLocal: "2026-09-28 14:30", tz: "Europe/Moscow",
                 inputKind: .voice, status: status, transcriptRaw: "напомни")
        }
        try await store.save(memo: memo("m1", .applied, at: 1))
        try await store.save(memo: memo("m2", .transcribed, at: 3))
        try await store.save(memo: memo("m3", .failed, at: 2))
        try await store.save(memo: memo("m4", .discarded, at: 4))
        #expect(try await store.unfinishedMemos().map(\.id) == ["m3", "m2"])
        var updated = try #require(try await store.memo(id: "m2"))
        updated.status = .applied
        try await store.save(memo: updated)
        #expect(try await store.unfinishedMemos().map(\.id) == ["m3"])
    }

    @Test func glossaryStoresAliasesAndAppliesThemToWholeWordsOnly() async throws {
        let store = try makeStore()
        try await store.save(term: GlossaryTerm(canonical: "Notion", kind: "app", aliases: ["нотион", "ношн", "нотиона"], spoken: "Нотион"))
        try await store.save(term: GlossaryTerm(canonical: "GitHub", aliases: ["гит хаб", "гит"], spoken: "Гитхаб"))
        try await store.save(term: GlossaryTerm(canonical: "Slack", aliases: ["слак"], enabled: false))
        let terms = try await store.glossary()
        #expect(terms.map(\.canonical) == ["GitHub", "Notion", "Slack"]) // by name
        #expect(terms.first { $0.canonical == "Notion" }?.aliases == ["нотион", "ношн", "нотиона"])

        // the longer alias wins, so "гит хаб" ("git hub") is one name and not "гит" ("git") followed by "хаб" ("hub")
        #expect(Glossary.applyAliases(to: "Доступ Нотиона и гит хаб", terms: terms) == "Доступ Notion и GitHub")
        #expect(Glossary.applyAliases(to: "нотионблок и слак", terms: terms) == "нотионблок и слак") // whole words only; disabled terms are ignored
        #expect(Glossary.promptLine(terms: terms) == "GitHub (гит хаб, гит); Notion (нотион, ношн, нотиона)")
        #expect(Glossary.spokenForm(of: "Доступ Notion в GitHub", terms: terms) == "Доступ Нотион в Гитхаб")
    }

    @Test func fileDatabaseUsesWALAndKeepsDataAcrossReopen() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kuzmemo-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("kuzmemo.sqlite")
        let clock = FixedNow(local: "2026-09-28 14:30", in: TimeZone(identifier: "Europe/Moscow")!)!
        do {
            let store = Store(writer: try KuzmemoDatabase.open(at: url), clock: clock)
            try await store.perform(label: "create") { try $0.insert(reminder("Сохранится", on: "2026-10-01")) }
            let mode = try await store.writer.read { try String.fetchOne($0, sql: "PRAGMA journal_mode") }
            #expect(mode == "wal")
        }
        let reopened = Store(writer: try KuzmemoDatabase.open(at: url), clock: clock)
        #expect(try await reopened.items(on: LocalDate("2026-10-01")!).map(\.title) == ["Сохранится"])
    }
}

@Suite("Settings and the glossary")
struct SettingsTests {
    @Test func settingsAreStoredReplacedAndRemoved() async throws {
        let store = try makeStore()
        #expect(try await store.setting("x") == nil)
        try await store.setSetting("1", for: "x")
        try await store.setSetting("2", for: "x")
        #expect(try await store.setting("x") == "2")
        try await store.setSetting(nil, for: "x")
        #expect(try await store.setting("x") == nil)
    }

    @Test func aNewGlossaryIsEmptyAndBelongsToThePerson() async throws {
        let store = try makeStore()
        #expect(try await store.glossary().isEmpty) // nothing about anybody's work is built in
        try await store.save(term: GlossaryTerm(canonical: "Foo", aliases: ["фу"]))
        #expect(try await store.glossary().map(\.canonical) == ["Foo"])
    }

    @Test func theWholeGlossaryCanBeReplacedAtOnce() async throws {
        let store = try makeStore()
        try await store.save(term: GlossaryTerm(canonical: "Old", aliases: ["олд"]))
        try await store.replaceGlossary(with: [
            GlossaryTerm(id: 99, canonical: "Notion", aliases: ["нотион"], spoken: "Ношн"),
            GlossaryTerm(canonical: "Slack", aliases: ["слак"], enabled: false),
        ])
        let terms = try await store.glossary()
        #expect(terms.map(\.canonical) == ["Notion", "Slack"])
        #expect(terms.first?.spoken == "Ношн" && terms.last?.enabled == false)
        #expect(terms.first?.id != 99) // ids are the database's own

        // a duplicate spelling fails and leaves the previous glossary in place
        await #expect(throws: (any Error).self) {
            try await store.replaceGlossary(with: [GlossaryTerm(canonical: "A"), GlossaryTerm(canonical: "A")])
        }
        #expect(try await store.glossary().map(\.canonical) == ["Notion", "Slack"])
    }
}
