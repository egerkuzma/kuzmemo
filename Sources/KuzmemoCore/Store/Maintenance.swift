import Foundation
import GRDB

/// What the database check found.
public struct IntegrityReport: Equatable, Sendable {
    public var checkedAt: Date
    /// What SQLite reported; empty when the database is sound.
    public var problems: [String]
    /// The search index did not match the entries and was rebuilt from them.
    public var searchIndexRebuilt: Bool

    public var isHealthy: Bool { problems.isEmpty }

    public init(checkedAt: Date, problems: [String], searchIndexRebuilt: Bool = false) {
        self.checkedAt = checkedAt
        self.problems = problems
        self.searchIndexRebuilt = searchIndexRebuilt
    }
}

/// How much the database holds (for the Data page of the settings).
public struct DataOverview: Equatable, Sendable {
    public var entries: Int
    public var memos: Int
    public var undoSteps: Int
    public var glossaryTerms: Int
}

/// What "erase all entries and history" removed.
public struct EraseSummary: Equatable, Sendable {
    public var entries: Int
    public var memos: Int
    public var undoSteps: Int
    /// The file was shrunk and its log folded in, so that none of the removed text is left in it. `false` when that step
    /// failed (a full disk, a lock): the rows are gone all the same, and the file is cleaned at the next quit.
    public var fileShrunk = true
}

extension Store {
    /// The tables that hold what the person said and did. The glossary and the settings (`kv`) are not among them.
    static let contentTables = ["items_fts", "op_changes", "ops", "item_exceptions", "items", "memos", "notification_state"]

    public func overview() async throws -> DataOverview {
        try await writer.read { db in
            DataOverview(
                entries: try Item.filter(Column("deleted_at") == nil).fetchCount(db),
                memos: try Memo.fetchCount(db),
                undoSteps: try Op.fetchCount(db),
                glossaryTerms: try GlossaryTerm.fetchCount(db)
            )
        }
    }

    /// Runs SQLite's own consistency check, then compares the search index with the entries and rebuilds the index when
    /// they disagree (it is derived data, so that loses nothing). A damaged file is reported, never "repaired".
    ///
    /// The answer is a verdict on the file or an error, nothing in between: a file that was busy or could not be read
    /// (`SQLITE_BUSY`, an I/O error, a full disk, a cancelled task) throws, because that says nothing about the data, and
    /// reporting it as a problem would raise an alarm over a database that is fine.
    ///
    /// The check runs on the writer connection on purpose. SQLite's check of an FTS5 table, run on a reader connection that
    /// searched earlier and has been open since, cries "fts5: checksum mismatch" after the index has been rewritten a few
    /// times, although nothing is wrong (a fresh connection and the writer say "ok", and searching through that reader
    /// still finds the right rows). The pool keeps its readers open for the life of the app, so a check there would raise
    /// a false alarm at every launch. The writer always has the current index structure.
    ///
    /// The writer can be stale too: after another process has rewritten the index, the long-lived connection still holds the
    /// old picture of it and says the same thing. So when the only complaints are about the search index, the check is
    /// repeated on a connection opened just now, which has no picture of anything yet; and if that one still complains, the
    /// index is built again from the entries and checked once more.
    public func integrityCheck() async throws -> IntegrityReport {
        let checkedAt = clock.now()
        let first = try await complaints(of: writer)
        let (found, rebuilt) = try await Store.settle(
            first,
            onFreshConnection: { try await self.complaintsOfFreshConnection() },
            rebuildIndex: { try await self.rebuildSearchIndex() },
            checkAgain: { try await self.complaints(of: self.writer) }
        )
        guard found.isEmpty else { return IntegrityReport(checkedAt: checkedAt, problems: found) }
        let consistent = try await writer.writeWithoutTransaction { db in try SearchIndex.isConsistent(db) }
        if !consistent { try await rebuildSearchIndex() }
        return IntegrityReport(checkedAt: checkedAt, problems: [], searchIndexRebuilt: rebuilt || !consistent)
    }

    /// What to do about SQLite's complaints `first`, as far as the search index goes (the operations are passed in so that
    /// each branch can be tested). Complaints about anything else stand as they are. When all of them concern the index, they
    /// may come from a stale picture of it on the long-lived connection, so a connection opened now is asked; if that one
    /// still complains, the index is built again from the entries (unless that fails, and then the complaint stands) and the
    /// check is repeated. Returns the complaints that remain.
    static func settle(
        _ first: [String],
        onFreshConnection: () async throws -> [String]?,
        rebuildIndex: () async throws -> Void,
        checkAgain: () async throws -> [String]
    ) async throws -> (problems: [String], rebuilt: Bool) {
        guard concernsOnlyTheSearchIndex(first) else { return (first, false) }
        var found = first
        if let fresh = try? await onFreshConnection() { found = fresh } // no answer from it (no file, cannot open): keep the first
        guard concernsOnlyTheSearchIndex(found) else { return (found, false) }
        do { try await rebuildIndex() } catch { return (found, false) }
        return (try await checkAgain(), true)
    }

    /// What SQLite's checks say about the file through `writer`: empty when it is sound. Damage is an answer; every other
    /// failure is thrown (see `integrityCheck`).
    private func complaints(of writer: any DatabaseWriter) async throws -> [String] {
        do {
            return try await writer.writeWithoutTransaction { db in try Store.complaints(in: db) }
        } catch let error as DatabaseError where Store.isDamage(error) {
            return [error.description]
        }
    }

    /// The same checks on a read-only connection opened now. Nothing when the database has no file of its own (in memory).
    private func complaintsOfFreshConnection() async throws -> [String]? {
        let path = writer.path
        guard !path.isEmpty, path != ":memory:", FileManager.default.fileExists(atPath: path) else { return nil }
        var configuration = Configuration()
        configuration.readonly = true
        let queue = try DatabaseQueue(path: path, configuration: configuration)
        do {
            return try await queue.read { db in try Store.complaints(in: db) }
        } catch let error as DatabaseError where Store.isDamage(error) {
            return [error.description]
        }
    }

    private static func complaints(in db: Database) throws -> [String] {
        var found = try String.fetchAll(db, sql: "PRAGMA integrity_check(20)")
        if found == ["ok"] { found = [] }
        for row in try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").prefix(5) {
            let table: String = row[0]
            found.append("foreign key violation in \(table)")
        }
        return found
    }

    /// A file that is not a database, or whose pages do not hold together. A busy, locked, unreadable or full file is not.
    static func isDamage(_ error: DatabaseError) -> Bool {
        error.resultCode == .SQLITE_CORRUPT || error.resultCode == .SQLITE_NOTADB
    }

    /// Every complaint is about the full-text index (which can be rebuilt), none about the entries themselves. No complaints
    /// at all is not "only the index".
    static func concernsOnlyTheSearchIndex(_ complaints: [String]) -> Bool {
        !complaints.isEmpty && complaints.allSatisfy {
            $0.localizedCaseInsensitiveContains("fts5") || $0.localizedCaseInsensitiveContains("items_fts")
        }
    }

    public func rebuildSearchIndex() async throws {
        try await writer.write { db in try SearchIndex.rebuild(db) }
    }

    /// Folds the write-ahead log into the database file, so that the file alone holds everything. Done when the app quits.
    public func checkpoint() async throws {
        try await writer.writeWithoutTransaction { db in _ = try db.checkpoint(.truncate) }
    }

    /// Removes every entry, saved phrase and undo step, then shrinks the file so that the removed text is not left lying in
    /// it. The glossary and the settings stay.
    ///
    /// Two steps with different outcomes: once the rows are deleted the erase has happened, and it is reported as such even
    /// if the shrinking fails (`fileShrunk` says so). In write-ahead mode the vacuum only writes the new file image into the
    /// log; the old pages (and their text) stay in the file and the log until a checkpoint copies the new image over them, so
    /// the checkpoint is part of the erase.
    @discardableResult
    public func eraseEntriesAndHistory() async throws -> EraseSummary {
        var summary = try await writer.write { db -> EraseSummary in
            let summary = EraseSummary(
                entries: try Item.filter(Column("deleted_at") == nil).fetchCount(db),
                memos: try Memo.fetchCount(db),
                undoSteps: try Op.fetchCount(db)
            )
            for table in Store.contentTables { try db.execute(sql: "DELETE FROM \(table)") }
            return summary
        }
        do {
            try await writer.vacuum()
            try await checkpoint()
        } catch {
            summary.fileShrunk = false
        }
        return summary
    }
}
