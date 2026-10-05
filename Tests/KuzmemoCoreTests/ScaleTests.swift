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
