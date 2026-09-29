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
    /// The check runs on the writer connection on purpose. SQLite's check of an FTS5 table, run on a reader connection that
    /// searched earlier and has been open since, cries "fts5: checksum mismatch" after the index has been rewritten a few
    /// times, although nothing is wrong (a fresh connection and the writer say "ok", and searching through that reader
    /// still finds the right rows). The pool keeps its readers open for the life of the app, so a check there would raise
    /// a false alarm at every launch. The writer always has the current index structure.
    public func integrityCheck() async throws -> IntegrityReport {
        let checkedAt = clock.now()
        let outcome: (problems: [String], indexConsistent: Bool)
        do {
            outcome = try await writer.writeWithoutTransaction { db in
                var found = try String.fetchAll(db, sql: "PRAGMA integrity_check(20)")
                if found == ["ok"] { found = [] }
                for row in try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").prefix(5) {
                    let table: String = row[0]
                    found.append("foreign key violation in \(table)")
                }
                return (found, found.isEmpty ? try SearchIndex.isConsistent(db) : true)
            }
        } catch let error as DatabaseError {
            return IntegrityReport(checkedAt: checkedAt, problems: [error.description])
        }
        guard outcome.problems.isEmpty else { return IntegrityReport(checkedAt: checkedAt, problems: outcome.problems) }
        if !outcome.indexConsistent { try await rebuildSearchIndex() }
        return IntegrityReport(checkedAt: checkedAt, problems: [], searchIndexRebuilt: !outcome.indexConsistent)
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
    @discardableResult
    public func eraseEntriesAndHistory() async throws -> EraseSummary {
        let summary = try await writer.write { db -> EraseSummary in
            let summary = EraseSummary(
                entries: try Item.filter(Column("deleted_at") == nil).fetchCount(db),
                memos: try Memo.fetchCount(db),
                undoSteps: try Op.fetchCount(db)
            )
            for table in Store.contentTables { try db.execute(sql: "DELETE FROM \(table)") }
            return summary
        }
        try await writer.vacuum()
        return summary
    }
}
