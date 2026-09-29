import Foundation
import GRDB
import Synchronization
import Testing
@testable import KuzmemoCore

/// A clock a test can move from one day to the next.
final class MovableNow: NowProvider, Sendable {
    private let instant: Mutex<Date>
    let timeZone: TimeZone

    init(_ local: String, in zone: TimeZone = TimeZone(identifier: "Europe/Moscow")!) {
        timeZone = zone
        instant = Mutex(FixedNow(local: local, in: zone)!.now())
    }

    func now() -> Date { instant.withLock { $0 } }

    func set(_ local: String) {
        let moved = FixedNow(local: local, in: timeZone)!.now()
        instant.withLock { $0 = moved }
    }
}

/// A database file in a folder of its own, a backups folder next to it, and a clock.
private struct Workshop {
    let root: URL
    let databaseURL: URL
    let clock: MovableNow
    let store: Store
    let backups: BackupService

    init(now: String = "2026-09-28 14:30") throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("kuzmemo-maintenance-\(UUID().uuidString)")
        databaseURL = root.appendingPathComponent("kuzmemo.sqlite")
        clock = MovableNow(now)
        let ids = IDSequence()
        store = Store(writer: try KuzmemoDatabase.open(at: databaseURL), clock: clock, makeID: { ids.next() })
        backups = BackupService(store: store, directory: root.appendingPathComponent("backups"))
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    func names() -> [String] { backups.list().map(\.url.lastPathComponent) }

    func filesInBackupsFolder() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: backups.directory.path)) ?? []).sorted()
    }

    /// Opens a copy on its own, read-only, the way the person (or a script) would.
    func entriesInCopy(_ file: BackupFile) throws -> [String] {
        var configuration = Configuration()
        configuration.readonly = true
        let queue = try DatabaseQueue(path: file.url.path, configuration: configuration)
        return try queue.read { db in try String.fetchAll(db, sql: "SELECT title FROM items ORDER BY title") }
    }
}

@Suite("Backups")
struct BackupTests {
    @Test func aCopyIsAPlainSqliteFileWithTheEntriesInIt() async throws {
        let shop = try Workshop()
        defer { shop.remove() }
        try await shop.store.perform(label: "seed") { m in
            try m.insert(reminder("Первое", on: "2026-09-30"))
            try m.insert(reminder("Второе", on: "2026-10-01"))
        }
        let file = try await shop.backups.run(.manual)
        #expect(file.reason == .manual)
        #expect(file.bytes > 0)
        #expect(file.url.lastPathComponent == "kuzmemo-2026-09-28-143000-manual.sqlite")
        #expect(file.day == LocalDate("2026-09-28") && file.time == LocalTime("14:30"))
        #expect(try shop.entriesInCopy(file) == ["Второе", "Первое"])
        // an ordinary file: no write-ahead log next to it, nothing half-written left behind
        #expect(shop.filesInBackupsFolder() == ["kuzmemo-2026-09-28-143000-manual.sqlite"])
        let mode = try await DatabaseQueue(path: file.url.path).read { try String.fetchOne($0, sql: "PRAGMA journal_mode") }
        #expect(mode == "delete")
    }

    @Test func aCopyDoesNotChangeWhatIsInTheDatabase() async throws {
        let shop = try Workshop()
        defer { shop.remove() }
        try await shop.store.perform(label: "seed") { try $0.insert(reminder("Остаётся", on: "2026-09-30")) }
        _ = try await shop.backups.run(.daily)
        try await shop.store.perform(label: "later") { try $0.insert(reminder("Позже", on: "2026-10-02")) }
        #expect(try await shop.store.overview().entries == 2)
        // the copy is a snapshot of the moment it was made
        #expect(try shop.entriesInCopy(shop.backups.list()[0]) == ["Остаётся"])
    }

    @Test func theDailyCopyIsMadeOncePerLocalDay() async throws {
        let shop = try Workshop(now: "2026-09-28 14:30")
        defer { shop.remove() }
        #expect(await shop.backups.isDailyDue())
        // a copy asked for by hand is not the daily one
        try await shop.backups.run(.manual)
        #expect(await shop.backups.isDailyDue())

        let first = try await shop.backups.runDailyIfDue()
        #expect(first?.reason == .daily)
        #expect(await shop.backups.isDailyDue() == false)
        #expect(try await shop.backups.runDailyIfDue() == nil) // later the same day: nothing to do
        shop.clock.set("2026-09-28 23:59")
        #expect(try await shop.backups.runDailyIfDue() == nil)

        shop.clock.set("2026-09-29 00:01") // past midnight by the wall clock
        #expect(await shop.backups.isDailyDue())
        #expect(try await shop.backups.runDailyIfDue() != nil)
        #expect(shop.backups.list().filter { $0.reason == .daily }.count == 2)
    }

    @Test func onlyTheLast14DailyCopiesAreKept() async throws {
        let shop = try Workshop(now: "2026-09-01 09:00")
        defer { shop.remove() }
        for day in 1 ... 17 {
            shop.clock.set(String(format: "2026-09-%02ld 09:00", day))
            try await shop.backups.runDailyIfDue()
        }
        let daily = shop.backups.list().filter { $0.reason == .daily }
        #expect(daily.count == BackupService.dailyKeep)
        #expect(daily.first?.day == LocalDate("2026-09-17")) // newest first
        #expect(daily.last?.day == LocalDate("2026-09-04")) // days 1 to 3 are gone
    }

    @Test func eachKindKeepsItsOwnShare() async throws {
        let shop = try Workshop()
        defer { shop.remove() }
        for minute in 0 ..< 8 {
            shop.clock.set(String(format: "2026-09-28 10:%02ld", minute))
            try await shop.backups.run(.manual)
        }
        for minute in 0 ..< 2 {
            shop.clock.set(String(format: "2026-09-28 11:%02ld", minute))
            try await shop.backups.run(.beforeErase)
        }
        shop.clock.set("2026-09-28 12:00")
        try await shop.backups.run(.daily)
        let files = shop.backups.list()
        #expect(files.filter { $0.reason == .manual }.count == BackupService.otherKeep)
        #expect(files.filter { $0.reason == .beforeErase }.count == 2) // busy manual copies did not push these out
        #expect(files.filter { $0.reason == .daily }.count == 1)
        // the oldest manual copies are the ones that went
        #expect(files.filter { $0.reason == .manual }.last?.time == LocalTime("10:03"))
    }

    @Test func copiesMadeInTheSameSecondGetDifferentNamesAndKeepTheirOrder() async throws {
        let shop = try Workshop()
        defer { shop.remove() }
        try await shop.backups.run(.manual)
        try await shop.store.perform(label: "seed") { try $0.insert(reminder("Между", on: "2026-09-30")) }
        try await shop.backups.run(.manual)
        #expect(shop.names() == ["kuzmemo-2026-09-28-143000-2-manual.sqlite", "kuzmemo-2026-09-28-143000-manual.sqlite"])
        let files = shop.backups.list()
        #expect(try shop.entriesInCopy(files[0]) == ["Между"]) // the newer one comes first and holds the newer state
        #expect(try shop.entriesInCopy(files[1]).isEmpty)
    }

    @Test func fileNamesRoundTripAndForeignNamesAreIgnored() throws {
        for reason in BackupReason.allCases {
            let name = BackupService.fileName(stamp: "2026-01-05-070809", counter: 1, reason: reason)
            let parsed = try #require(BackupService.parse(name))
            #expect(parsed.reason == reason)
            #expect(parsed.day == LocalDate("2026-01-05") && parsed.time == LocalTime("07:08"))
        }
        let counted = try #require(BackupService.parse("kuzmemo-2026-01-05-070809-3-before-erase.sqlite"))
        #expect(counted.reason == .beforeErase)
        for foreign in [
            "notes.txt", "kuzmemo.sqlite", "kuzmemo-2026-01-05-070809-weird.sqlite", "kuzmemo-2026-13-05-070809.sqlite",
            "kuzmemo-2026-01-05-070809.sqlite.partial", "kuzmemo-2026-1-5-7089.sqlite",
        ] {
            #expect(BackupService.parse(foreign) == nil, "\(foreign)")
        }
    }

    @Test func otherFilesInTheFolderAreNeverTouched() async throws {
        let shop = try Workshop(now: "2026-09-01 09:00")
        defer { shop.remove() }
        let folder = shop.backups.directory
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let mine = ["notes.txt", "kuzmemo-old.sqlite", "kuzmemo-2026-09-01-090000-weird.sqlite"]
        for name in mine { try Data("x".utf8).write(to: folder.appendingPathComponent(name)) }
        for day in 1 ... 20 {
            shop.clock.set(String(format: "2026-09-%02ld 09:00", day))
            try await shop.backups.runDailyIfDue()
        }
        #expect(mine.allSatisfy { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) })
        #expect(shop.backups.list().count == BackupService.dailyKeep)
    }

    @Test func aHalfWrittenLeftoverIsCleanedUpAndNotCounted() async throws {
        let shop = try Workshop()
        defer { shop.remove() }
        let folder = shop.backups.directory
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("torn".utf8).write(to: folder.appendingPathComponent("kuzmemo-2026-09-27-101010.sqlite.partial"))
        #expect(shop.backups.list().isEmpty)
        try await shop.backups.run(.manual)
        #expect(shop.filesInBackupsFolder() == ["kuzmemo-2026-09-28-143000-manual.sqlite"])
    }

    @Test func aCopyThatCannotBeReadBackIsNotKept() async throws {
        // A database without the calendar tables: the copy is written but fails the read-back.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kuzmemo-badcopy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let empty = Store(writer: try DatabaseQueue(), clock: MovableNow("2026-09-28 14:30"))
        let service = BackupService(store: empty, directory: root)
        await #expect(throws: (any Error).self) { try await service.run(.manual) }
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).isEmpty)
    }
}

@Suite("Database maintenance")
struct MaintenanceTests {
    @Test func aFreshDatabaseIsHealthyAndTheOverviewCountsWhatIsThere() async throws {
        let store = try makeStore()
        let report = try await store.integrityCheck()
        #expect(report.isHealthy && report.problems.isEmpty && !report.searchIndexRebuilt)

        try await store.perform(label: "seed") { m in
            try m.insert(reminder("Живая", on: "2026-09-30"))
            try m.insert(reminder("Ещё", on: "2026-10-01"))
        }
        try await store.save(memo: Memo(id: "m1", createdAt: 1, anchorLocal: "2026-09-28 14:30", tz: "Europe/Moscow", inputKind: .voice, status: .applied))
        try await store.save(term: GlossaryTerm(canonical: "Foo"))
        let deleted = try #require(try await store.items(on: LocalDate("2026-09-30")!).first)
        try await store.perform(label: "delete") { try $0.softDelete(id: deleted.id) }
        let overview = try await store.overview()
        #expect(overview == DataOverview(entries: 1, memos: 1, undoSteps: 2, glossaryTerms: 1)) // a deleted entry is not counted
    }

    @Test func aSearchIndexThatDriftedIsRebuiltFromTheEntries() async throws {
        let store = try makeStore()
        try await store.perform(label: "seed") { m in
            try m.insert(reminder("Оплатить хостинг", on: "2026-09-30"))
            try m.insert(reminder("Позвонить Анне", on: "2026-10-01"))
        }
        #expect(try await store.search("хостинг").count == 1)
        // What hand-cleaning the database did once: a stray row for an entry that is gone, and a real entry that lost its row.
        try await store.writer.write { db in
            try db.execute(sql: "INSERT INTO items_fts(item_id, title, details, keywords) VALUES('ghost', 'привидение', '', '')")
            try db.execute(sql: "DELETE FROM items_fts WHERE title LIKE '%хостинг%'")
        }
        #expect(try await store.search("хостинг").isEmpty)

        let report = try await store.integrityCheck()
        #expect(report.isHealthy && report.searchIndexRebuilt)
        #expect(try await store.search("хостинг").count == 1)
        #expect(try await store.search("привидение").isEmpty)
        #expect(try await store.integrityCheck().searchIndexRebuilt == false) // consistent now: nothing more to do
    }

    /// SQLite's own check, run on a reader connection that searched earlier and was left open, cries "fts5: checksum mismatch"
    /// after the writer has rewritten the index a few times, although nothing is wrong (a fresh connection and the writer
    /// both say "ok", and searching through that reader still gives the right rows). The app's pool keeps its readers
    /// open for its whole life, so the check must not run on one.
    @Test func aReaderThatSearchedEarlierDoesNotRaiseAFalseAlarm() async throws {
        let shop = try Workshop()
        defer { shop.remove() }
        try await shop.store.perform(label: "seed") { m in
            for n in 0 ..< 5 { try m.insert(reminder("Запись номер \(n) про хостинг", on: "2026-09-30")) }
        }
        #expect(try await shop.store.search("хостинг").count == 5) // the pool's reader now has the index structure cached
        for round in 0 ..< 30 { // what the demo data and the E2E scripts do: erase everything and write it again
            try await shop.store.eraseAllData()
            for n in 0 ..< 12 {
                try await shop.store.perform(label: "again") { try $0.insert(reminder("Запись \(n) круг \(round) доступ", on: "2026-09-30")) }
            }
        }
        let report = try await shop.store.integrityCheck() // no search in between: the reader's cache is still the old one
        #expect(report.problems == [], "\(report.problems)")
        #expect(report.isHealthy)
        #expect(try await shop.store.search("доступ").count == 12) // and searching was right all along
    }

    @Test func aDamagedFileIsReportedAndNothingIsRepairedBehindThePersonsBack() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kuzmemo-damaged-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("kuzmemo.sqlite")
        do {
            let store = Store(writer: try KuzmemoDatabase.open(at: url), clock: MovableNow("2026-09-28 14:30"))
            try await store.perform(label: "seed") { m in
                for n in 1 ... 400 { try m.insert(reminder("Запись номер \(n) с довольно длинным названием, чтобы заполнить страницы", on: "2026-09-30")) }
            }
            try await store.checkpoint() // everything is in the main file
        }
        // Trash the last quarter of the file: table data, not the schema, so the file still opens.
        try Self.trash(url, from: 0.75)

        let damaged = Store(writer: try DatabasePool(path: url.path), clock: MovableNow("2026-09-28 14:30"))
        let report = try await damaged.integrityCheck()
        #expect(!report.isHealthy && !report.problems.isEmpty)
        #expect(!report.searchIndexRebuilt)
    }

    @Test func eraseRemovesEntriesAndHistoryButKeepsTheGlossaryAndTheSettings() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kuzmemo-erase-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("kuzmemo.sqlite")
        let store = Store(writer: try KuzmemoDatabase.open(at: url), clock: MovableNow("2026-09-28 14:30"))
        try await store.perform(label: "seed") { m in
            try m.insert(reminder("Тайное слово: фиолетовый кенгуру", on: "2026-09-30"))
            try m.insert(reminder("Другая запись", on: "2026-10-01"))
        }
        try await store.save(memo: Memo(
            id: "m1", createdAt: 1, anchorLocal: "2026-09-28 14:30", tz: "Europe/Moscow", inputKind: .voice,
            status: .applied, transcriptRaw: "напомни про фиолетового кенгуру"
        ))
        try await store.save(term: GlossaryTerm(canonical: "Notion", aliases: ["нотион"]))
        try await store.setSetting("{\"rate\":0.4}", for: "settings.speech")

        let summary = try await store.eraseEntriesAndHistory()
        #expect(summary == EraseSummary(entries: 2, memos: 1, undoSteps: 1))
        #expect(try await store.overview() == DataOverview(entries: 0, memos: 0, undoSteps: 0, glossaryTerms: 1))
        #expect(try await store.search("кенгуру").isEmpty)
        #expect(try await store.writer.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM items_fts") } == 0)
        #expect(try await store.glossary().map(\.canonical) == ["Notion"])
        #expect(try await store.setting("settings.speech") == "{\"rate\":0.4}")
        #expect(try await store.integrityCheck().isHealthy)

        // The erased words are not left lying in the file either.
        try await store.checkpoint()
        let bytes = try Data(contentsOf: url)
        #expect(bytes.range(of: Data("кенгуру".utf8)) == nil)
        #expect(bytes.range(of: Data("Notion".utf8)) != nil) // what stays is still there
    }

    @Test func checkpointFoldsTheLogIntoTheDatabaseFile() async throws {
        let shop = try Workshop()
        defer { shop.remove() }
        try await shop.store.perform(label: "seed") { try $0.insert(reminder("В журнале", on: "2026-09-30")) }
        let log = URL(fileURLWithPath: shop.databaseURL.path + "-wal")
        #expect(((try? FileManager.default.attributesOfItem(atPath: log.path)[.size] as? Int) ?? 0) > 0)
        try await shop.store.checkpoint()
        #expect(((try? FileManager.default.attributesOfItem(atPath: log.path)[.size] as? Int) ?? 0) == 0)
        #expect(try Data(contentsOf: shop.databaseURL).range(of: Data("В журнале".utf8)) != nil)
    }
}

extension MaintenanceTests {
    /// Overwrites the file from the given fraction of its length (rounded down to a page) to the end.
    static func trash(_ url: URL, from fraction: Double) throws {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        let start = UInt64(Double(size) * fraction) / 4096 * 4096
        try handle.seek(toOffset: start)
        try handle.write(contentsOf: Data(repeating: 0xFF, count: Int(size - start)))
    }
}

@Suite("Opening a damaged database")
struct RecoveryTests {
    /// A database with one entry and one copy of it, closed again. Then one more entry, which the copy does not have.
    private func prepare(makeCopy: Bool = true) async throws -> (root: URL, database: URL, backups: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kuzmemo-recovery-\(UUID().uuidString)")
        let database = root.appendingPathComponent("kuzmemo.sqlite")
        let backups = root.appendingPathComponent("backups")
        let clock = MovableNow("2026-09-28 14:30")
        let store = Store(writer: try KuzmemoDatabase.open(at: database), clock: clock)
        try await store.perform(label: "seed") { try $0.insert(reminder("Из копии", on: "2026-09-30")) }
        if makeCopy { try await BackupService(store: store, directory: backups).run(.daily) }
        try await store.perform(label: "later") { try $0.insert(reminder("После копии", on: "2026-10-01")) }
        try await store.checkpoint()
        return (root, database, backups)
    }

    private func titles(_ pool: DatabasePool) throws -> [String] {
        try pool.read { try String.fetchAll($0, sql: "SELECT title FROM items ORDER BY title") }
    }

    private func names(in root: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).sorted()
    }

    @Test func aSoundDatabaseJustOpens() async throws {
        let (root, database, backups) = try await prepare()
        defer { try? FileManager.default.removeItem(at: root) }
        let (pool, outcome) = try DatabaseRecovery.open(at: database, backups: backups)
        #expect(outcome == .opened)
        #expect(try titles(pool) == ["Из копии", "После копии"])
    }

    @Test func aFileTooDamagedToOpenIsSetAsideAndTheNewestCopyTakesItsPlace() async throws {
        let (root, database, backups) = try await prepare()
        defer { try? FileManager.default.removeItem(at: root) }
        // Pages of 0xFF: SQLite reports a malformed image (the file is a database by its size, not by its content).
        try Data(repeating: 0xFF, count: 4096 * 3).write(to: database)

        let (pool, outcome) = try DatabaseRecovery.open(at: database, backups: backups, now: FixedNow(local: "2026-09-29 09:15", in: TimeZone(identifier: "Europe/Moscow")!)!.now(), zone: TimeZone(identifier: "Europe/Moscow")!)
        guard case let .restored(copy, aside) = outcome else { Issue.record("expected .restored, got \(outcome)"); return }
        #expect(copy.reason == .daily && copy.day == LocalDate("2026-09-28"))
        #expect(aside.lastPathComponent == "kuzmemo-damaged-2026-09-29-091500.sqlite")
        #expect(FileManager.default.fileExists(atPath: aside.path)) // kept, never deleted
        #expect(try titles(pool) == ["Из копии"]) // what was made after the copy is the price
        #expect(FileManager.default.fileExists(atPath: copy.url.path)) // the copy itself is untouched
        #expect(try await pool.read { try String.fetchOne($0, sql: "PRAGMA journal_mode") } == "wal") // a normal database again
        #expect(names(in: root).contains("kuzmemo-damaged-2026-09-29-091500.sqlite"))
    }

    @Test func anUnusableNewestCopyFallsBackToAnOlderOne() async throws {
        let (root, database, backups) = try await prepare()
        defer { try? FileManager.default.removeItem(at: root) }
        // a newer copy that is garbage (a torn write, a full disk)
        let newer = backups.appendingPathComponent("kuzmemo-2026-09-28-235959.sqlite")
        try Data(repeating: 0xAB, count: 9000).write(to: newer)
        try Data(repeating: 0xFF, count: 4096 * 3).write(to: database)

        let (pool, outcome) = try DatabaseRecovery.open(at: database, backups: backups)
        guard case let .restored(copy, _) = outcome else { Issue.record("expected .restored, got \(outcome)"); return }
        #expect(copy.url.lastPathComponent != newer.lastPathComponent)
        #expect(try titles(pool) == ["Из копии"])
        #expect(FileManager.default.fileExists(atPath: newer.path)) // the bad copy is left for the person to see
    }

    @Test func withoutACopyItStartsEmptyAndKeepsTheDamagedFile() async throws {
        let (root, database, backups) = try await prepare(makeCopy: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("this is not a database at all".utf8).write(to: database) // "file is not a database"

        let (pool, outcome) = try DatabaseRecovery.open(at: database, backups: backups)
        guard case let .startedEmpty(aside) = outcome else { Issue.record("expected .startedEmpty, got \(outcome)"); return }
        #expect(try titles(pool).isEmpty)
        #expect(try Data(contentsOf: aside) == Data("this is not a database at all".utf8))
        #expect(try await pool.read { try String.fetchOne($0, sql: "PRAGMA integrity_check") } == "ok")
    }

    @Test func troubleThatIsNotDamageIsPassedOnAndNothingIsMoved() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kuzmemo-notdamage-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appendingPathComponent("kuzmemo.sqlite")
        try FileManager.default.createDirectory(at: database, withIntermediateDirectories: true) // a folder where the file should be
        #expect(throws: (any Error).self) { try DatabaseRecovery.open(at: database, backups: root.appendingPathComponent("backups")) }
        #expect(names(in: root) == ["kuzmemo.sqlite"])
    }
}
