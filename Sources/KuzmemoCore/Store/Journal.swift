import Foundation
import GRDB

/// One undoable operation (a voice command, a manual edit, ...).
public struct Op: Codable, Hashable, Sendable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "ops"

    public var id: String
    public var memoID: String?
    public var createdAt: Int64
    public var label: String
    public var undoneAt: Int64?

    public init(id: String, memoID: String?, createdAt: Int64, label: String, undoneAt: Int64? = nil) {
        self.id = id
        self.memoID = memoID
        self.createdAt = createdAt
        self.label = label
        self.undoneAt = undoneAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case memoID = "memo_id"
        case createdAt = "created_at"
        case label
        case undoneAt = "undone_at"
    }
}

/// Before/after snapshot of one row touched by an operation. `nil` before = the row was created;
/// `nil` after = the row was removed.
struct OpChange: Codable, Hashable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "op_changes"

    var opID: String
    var seq: Int
    var tbl: String
    var rowID: String
    var beforeJSON: String?
    var afterJSON: String?

    enum CodingKeys: String, CodingKey {
        case opID = "op_id"
        case seq, tbl
        case rowID = "row_id"
        case beforeJSON = "before_json"
        case afterJSON = "after_json"
    }
}

public enum StoreError: Error, Equatable {
    case itemNotFound(String)
    case opNotFound(String)
    case alreadyUndone(String)
    /// A later change touched a row this operation modified, so undoing it would overwrite newer data.
    case undoConflict(String)
}

enum Snapshot {
    static func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    static func decode<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }
}

/// Collects row changes made inside one write transaction so they can be journaled and undone.
public final class Mutator {
    struct Pending {
        let table: String
        let rowID: String
        let before: String?
        let after: String?
    }

    let db: Database
    let nowMs: Int64
    let makeID: @Sendable () -> String
    private(set) var pending: [Pending] = []

    init(db: Database, nowMs: Int64, makeID: @escaping @Sendable () -> String) {
        self.db = db
        self.nowMs = nowMs
        self.makeID = makeID
    }

    /// Inserts a new item. An empty `id` is replaced by a generated one; timestamps are set here.
    @discardableResult
    public func insert(_ item: Item) throws -> Item {
        var row = item
        if row.id.isEmpty { row.id = makeID() }
        row.createdAt = nowMs
        row.updatedAt = nowMs
        row.version = 1
        try row.insert(db)
        try SearchIndex.upsert(db, item: row)
        pending.append(.init(table: "items", rowID: row.id, before: nil, after: try Snapshot.encode(row)))
        return row
    }

    /// Edits an existing item in place and bumps `version` and `updatedAt`.
    @discardableResult
    public func update(id: String, _ edit: (inout Item) throws -> Void) throws -> Item {
        guard var row = try Item.fetchOne(db, key: id) else { throw StoreError.itemNotFound(id) }
        let before = try Snapshot.encode(row)
        try edit(&row)
        row.id = id
        row.updatedAt = nowMs
        row.version += 1
        try row.update(db)
        try SearchIndex.upsert(db, item: row)
        pending.append(.init(table: "items", rowID: id, before: before, after: try Snapshot.encode(row)))
        return row
    }

    /// Soft delete: the row stays (so Undo works and sync-style tools can see the tombstone).
    @discardableResult
    public func softDelete(id: String) throws -> Item {
        try update(id: id) { $0.deletedAt = nowMs }
    }

    /// Creates or replaces a per-occurrence override of a recurring item.
    public func setException(_ exception: ItemException) throws {
        let key = Mutator.exceptionKey(exception.itemID, exception.occDate)
        let before = try ItemException.fetchOne(db, key: ["item_id": exception.itemID, "occ_date": exception.occDate])
            .map(Snapshot.encode)
        try exception.save(db)
        pending.append(.init(table: "item_exceptions", rowID: key, before: before, after: try Snapshot.encode(exception)))
    }

    public func removeException(itemID: String, occDate: LocalDate) throws {
        guard let existing = try ItemException.fetchOne(db, key: ["item_id": itemID, "occ_date": occDate]) else { return }
        try existing.delete(db)
        pending.append(.init(
            table: "item_exceptions", rowID: Mutator.exceptionKey(itemID, occDate),
            before: try Snapshot.encode(existing), after: nil
        ))
    }

    static func exceptionKey(_ itemID: String, _ date: LocalDate) -> String { "\(itemID)|\(date)" }
}
