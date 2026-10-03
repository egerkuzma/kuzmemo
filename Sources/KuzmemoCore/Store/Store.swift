import Foundation
import GRDB

/// The single entry point for reading and changing calendar data. Every change goes through
/// `perform`, which journals before/after snapshots so it can be undone atomically.
public struct Store: Sendable {
    public let writer: any DatabaseWriter
    public let clock: any NowProvider
    private let makeID: @Sendable () -> String
    /// The saved phrases an erase has removed, shared by every copy of this store (see `ErasedMemos`).
    let erased = ErasedMemos()

    public init(
        writer: any DatabaseWriter,
        clock: any NowProvider = SystemNow(),
        makeID: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() }
    ) {
        self.writer = writer
        self.clock = clock
        self.makeID = makeID
    }

    /// Opens (creating and migrating if needed) the SQLite database at `url`.
    public init(databaseAt url: URL, clock: any NowProvider = SystemNow()) throws {
        self.init(writer: try KuzmemoDatabase.open(at: url), clock: clock)
    }

    private var nowMs: Int64 { Int64(clock.now().timeIntervalSince1970 * 1000) }

    // MARK: - Reads

    public func item(id: String, includeDeleted: Bool = false) async throws -> Item? {
        try await writer.read { db in
            guard let item = try Item.fetchOne(db, key: id) else { return nil }
            return (item.deletedAt == nil || includeDeleted) ? item : nil
        }
    }

    /// One-off (non-recurring) dated items of a single day: all-day first, then by time.
    public func items(on date: LocalDate) async throws -> [Item] {
        try await items(in: date...date)
    }

    /// One-off (non-recurring) dated items within a date range, ordered by date, time (all-day first), creation.
    public func items(in range: ClosedRange<LocalDate>) async throws -> [Item] {
        try await writer.read { db in
            try Item
                .filter(Column("deleted_at") == nil)
                .filter(Column("recurrence_json") == nil)
                .filter(Column("date") >= range.lowerBound && Column("date") <= range.upperBound)
                .order(Column("date"), Column("time"), Column("created_at"))
                .fetchAll(db)
        }
    }

    /// Open items without a date, newest first.
    public func inbox() async throws -> [Item] {
        try await writer.read { db in
            try Item
                .filter(Column("deleted_at") == nil && Column("date") == nil && Column("status") == ItemStatus.open)
                .order(Column("created_at").desc)
                .fetchAll(db)
        }
    }

    public func recurringSeries() async throws -> [Item] {
        try await writer.read { db in
            try Item
                .filter(Column("deleted_at") == nil && Column("recurrence_json") != nil)
                .order(Column("date"), Column("created_at"))
                .fetchAll(db)
        }
    }

    public func exceptions(for itemIDs: [String]) async throws -> [ItemException] {
        guard !itemIDs.isEmpty else { return [] }
        return try await writer.read { db in
            try ItemException.filter(itemIDs.contains(Column("item_id"))).fetchAll(db)
        }
    }

    /// Substring search over title, details and keywords that tolerates Russian word endings.
    public func search(_ text: String, limit: Int = 50) async throws -> [Item] {
        try await writer.read { db in try SearchIndex.search(db, query: text, limit: limit) }
    }

    // MARK: - Writes

    /// Runs `body` in one transaction and journals every row it touches. Returns `nil` when nothing changed. With a `memoID`
    /// the change is what that phrase meant, and the phrase is marked as applied in the same transaction.
    @discardableResult
    public func perform(
        label: String, memoID: String? = nil, _ body: @escaping @Sendable (Mutator) throws -> Void
    ) async throws -> Op? {
        try await performReturning(label: label, memoID: memoID) { mutator -> Void in try body(mutator) }.op
    }

    /// Like `perform`, but also returns whatever `body` produced (for example a summary for the UI).
    public func performReturning<Value: Sendable>(
        label: String, memoID: String? = nil, _ body: @escaping @Sendable (Mutator) throws -> Value
    ) async throws -> (op: Op?, value: Value) {
        let stamp = nowMs
        let makeID = self.makeID
        let erased = self.erased
        return try await writer.write { db in
            // A change that came out of a phrase which has been erased since is not made (its entries would be the erased
            // words all over again). Checked in the transaction, after any erase that was ahead of it in the queue.
            if let memoID, erased.contains(memoID) { throw StoreError.memoErased(memoID) }
            let mutator = Mutator(db: db, nowMs: stamp, makeID: makeID)
            let value = try body(mutator)
            var op: Op?
            if !mutator.pending.isEmpty {
                let made = Op(id: makeID(), memoID: memoID, createdAt: stamp, label: label)
                try made.insert(db)
                for (index, change) in mutator.pending.enumerated() {
                    try OpChange(
                        opID: made.id, seq: index, tbl: change.table, rowID: change.rowID,
                        beforeJSON: change.before, afterJSON: change.after
                    ).insert(db)
                }
                op = made
            }
            // The phrase and its changes land together. Marked afterwards, in a write of its own, a phrase whose marking failed
            // looked unfinished: recovery ran it again, and when the person had undone its changes meanwhile, made them anew.
            if let memoID {
                try db.execute(
                    sql: "UPDATE memos SET status = ?, op_id = ? WHERE id = ?", arguments: [MemoStatus.applied.rawValue, op?.id, memoID]
                )
            }
            return (op, value)
        }
    }

    /// The most recent operation that has not been undone.
    public func lastUndoableOp() async throws -> Op? {
        try await writer.read { db in
            try Op.filter(Column("undone_at") == nil).order(Column("created_at").desc, Column("rowid").desc).fetchOne(db)
        }
    }

    /// Restores every row the operation touched to its previous state, atomically. Throws
    /// `StoreError.undoConflict` when a later change modified one of those rows.
    public func undo(opID: String) async throws {
        let stamp = nowMs
        try await writer.write { db in
            guard var op = try Op.fetchOne(db, key: opID) else { throw StoreError.opNotFound(opID) }
            guard op.undoneAt == nil else { throw StoreError.alreadyUndone(opID) }
            let changes = try OpChange
                .filter(Column("op_id") == opID)
                .order(Column("seq").desc)
                .fetchAll(db)
            // An operation may change one row more than once (an answer that renames and moves the same entry as two
            // updates): only its last change can match what the row is now, and restoring newest-first walks back through
            // the earlier ones.
            var checked = Set<String>()
            for change in changes {
                guard checked.insert("\(change.tbl)|\(change.rowID)").inserted else { continue }
                if try !Store.currentState(db, matches: change) { throw StoreError.undoConflict("\(change.tbl) \(change.rowID)") }
            }
            // Undoing a creation removes the row, and with it (by cascade) every per-occurrence override the row has. Ticking an
            // occurrence off, skipping or moving it writes only to those overrides, so the series' own row looks untouched and
            // the check above lets the undo through; an override that this operation did not make is a later change to the
            // series, and is refused like any other.
            let ownOverrides = Set(changes.filter { $0.tbl == "item_exceptions" }.map(\.rowID))
            for change in changes where change.tbl == "items" && change.beforeJSON == nil {
                let overrides = try ItemException.filter(Column("item_id") == change.rowID).fetchAll(db)
                if overrides.contains(where: { !ownOverrides.contains(Mutator.exceptionKey($0.itemID, $0.occDate)) }) {
                    throw StoreError.undoConflict("item_exceptions \(change.rowID)")
                }
            }
            for change in changes { try Store.restore(db, change) }
            op.undoneAt = stamp
            try op.update(db)
        }
    }

    private static func currentState(_ db: Database, matches change: OpChange) throws -> Bool {
        switch change.tbl {
        case "items":
            let current = try Item.fetchOne(db, key: change.rowID).map(Snapshot.encode)
            return current == change.afterJSON
        case "item_exceptions":
            let (itemID, date) = try parseExceptionKey(change.rowID)
            let current = try ItemException.fetchOne(db, key: ["item_id": itemID, "occ_date": date]).map(Snapshot.encode)
            return current == change.afterJSON
        default:
            return true
        }
    }

    private static func restore(_ db: Database, _ change: OpChange) throws {
        switch change.tbl {
        case "items":
            if let before = change.beforeJSON {
                let item = try Snapshot.decode(Item.self, from: before)
                try item.save(db)
                try SearchIndex.upsert(db, item: item)
            } else {
                _ = try Item.deleteOne(db, key: change.rowID)
                try SearchIndex.remove(db, id: change.rowID)
            }
        case "item_exceptions":
            let (itemID, date) = try parseExceptionKey(change.rowID)
            if let before = change.beforeJSON {
                try Snapshot.decode(ItemException.self, from: before).save(db)
            } else {
                _ = try ItemException.deleteOne(db, key: ["item_id": itemID, "occ_date": date])
            }
        default:
            break
        }
    }

    private static func parseExceptionKey(_ key: String) throws -> (String, LocalDate) {
        let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2, let date = LocalDate(parts[1]) else { throw StoreError.opNotFound(key) }
        return (parts[0], date)
    }

    // MARK: - Memos

    /// Saves (inserts or updates) a phrase. Nothing is written for a phrase that "erase all" has removed since it was read:
    /// whatever was still working on it (a model call takes seconds) must not bring it back. A step that has to know whether its
    /// write happened (to stop working on an erased phrase) uses `saveUnlessErased`.
    public func save(memo: Memo) async throws {
        _ = try await saveUnlessErased(memo: memo)
    }

    /// Like `save(memo:)`, and says whether the phrase was written: `false` means it has been erased.
    public func saveUnlessErased(memo: Memo) async throws -> Bool {
        let erased = self.erased
        return try await writer.write { db in
            guard !erased.contains(memo.id) else { return false }
            try memo.save(db)
            return true
        }
    }

    public func memo(id: String) async throws -> Memo? {
        try await writer.read { db in try Memo.fetchOne(db, key: id) }
    }

    /// Memos that never reached a final state; the pipeline resumes them after a restart.
    public func unfinishedMemos() async throws -> [Memo] {
        let final: [MemoStatus] = [.applied, .answered, .discarded, .superseded]
        return try await writer.read { db in
            try Memo.filter(!final.contains(Column("status"))).order(Column("created_at")).fetchAll(db)
        }
    }

    // MARK: - Glossary

    public func glossary() async throws -> [GlossaryTerm] {
        try await writer.read { db in try GlossaryTerm.order(Column("canonical")).fetchAll(db) }
    }

    @discardableResult
    public func save(term: GlossaryTerm) async throws -> GlossaryTerm {
        try await writer.write { db in
            var row = term
            try row.save(db)
            return row
        }
    }

    public func deleteTerm(id: Int64) async throws {
        try await writer.write { db in _ = try GlossaryTerm.deleteOne(db, key: id) }
    }

    /// Replaces the whole glossary in one transaction (a duplicate spelling rolls everything back). For test setups.
    public func replaceGlossary(with terms: [GlossaryTerm]) async throws {
        try await writer.write { db in
            _ = try GlossaryTerm.deleteAll(db)
            for term in terms {
                var row = term
                row.id = nil
                try row.insert(db)
            }
        }
    }
}
