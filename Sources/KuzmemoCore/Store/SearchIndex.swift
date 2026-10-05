import Foundation
import GRDB

/// Text normalisation and a deliberately crude Russian "stemmer" for substring search.
///
/// The FTS5 `trigram` tokenizer matches substrings of at least three characters, so cutting the
/// inflectional ending off each query word (Дмитрий → дмитри) lets it match every case form
/// (Дмитрию, Дмитрия, Дмитрием) in the index.
public enum SearchText {
    /// Lowercases and folds diacritics so the index and the query agree (ё → е, й → и).
    public static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
    }

    /// Normalised words made of letters and digits.
    public static func tokens(_ text: String) -> [String] {
        normalize(text)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    /// Drops up to two trailing letters of long words and one of medium words; short words are kept.
    public static func stem(_ token: String) -> String {
        let n = token.count
        if n >= 6 { return String(token.dropLast(2)) }
        if n >= 4 { return String(token.dropLast(1)) }
        return token
    }

    /// FTS5 MATCH expression (an AND of quoted stems of at least three characters), or `nil` when the
    /// query has no word long enough for the trigram index.
    public static func matchExpression(for query: String) -> String? {
        let stems = tokens(query).map(stem).filter { $0.count >= 3 }
        guard !stems.isEmpty else { return nil }
        return stems.map { "\"\($0)\"" }.joined(separator: " ")
    }
}

enum SearchIndex {
    static func upsert(_ db: Database, item: Item) throws {
        try db.execute(sql: "DELETE FROM items_fts WHERE item_id = ?", arguments: [item.id])
        guard item.deletedAt == nil else { return }
        try insert(db, item: item)
    }

    private static func insert(_ db: Database, item: Item) throws {
        try db.execute(
            sql: "INSERT INTO items_fts(item_id, title, details, keywords) VALUES (?, ?, ?, ?)",
            arguments: [
                item.id,
                SearchText.normalize(item.title),
                SearchText.normalize(item.details ?? ""),
                SearchText.normalize(item.keywords),
            ]
        )
    }

    /// Throws the index away and builds it again from the entries (it is derived data, so nothing is lost).
    static func rebuild(_ db: Database) throws {
        try db.execute(sql: "DELETE FROM items_fts")
        for item in try Item.filter(Column("deleted_at") == nil).fetchAll(db) { try insert(db, item: item) }
    }

    /// True when the index has exactly one row for each entry that should be in it and nothing else.
    static func isConsistent(_ db: Database) throws -> Bool {
        let live = try Int.fetchOne(db, sql: "SELECT count(*) FROM items WHERE deleted_at IS NULL") ?? 0
        let indexed = try Int.fetchOne(db, sql: "SELECT count(*) FROM items_fts") ?? 0
        let missing = try Int.fetchOne(
            db, sql: "SELECT count(*) FROM items WHERE deleted_at IS NULL AND id NOT IN (SELECT item_id FROM items_fts)"
        ) ?? 0
        // Every live entry present and as many rows as entries: no strays, no duplicates.
        return live == indexed && missing == 0
    }

    static func remove(_ db: Database, id: String) throws {
        try db.execute(sql: "DELETE FROM items_fts WHERE item_id = ?", arguments: [id])
    }

    static func search(_ db: Database, query: String, limit: Int) throws -> [Item] {
        if let match = SearchText.matchExpression(for: query) {
            return try Item.fetchAll(db, sql: """
                SELECT items.* FROM items
                JOIN items_fts ON items_fts.item_id = items.id
                WHERE items_fts MATCH ? AND items.deleted_at IS NULL
                ORDER BY rank LIMIT ?
                """, arguments: [match, limit])
        }
        // Only very short words: the trigram index cannot help, so the index's own (already normalised) text is scanned inside
        // SQLite, every entry of it. The entries were once read into Swift and filtered there, which cost time that grew with
        // the calendar and looked at the first 5 000 entries only. The scan is the outer loop: a join the other way round would
        // read the whole index once per entry.
        let words = SearchText.tokens(query)
        guard !words.isEmpty else { return [] }
        let clauses = words.map { _ in "instr(items_fts.title || ' ' || items_fts.details || ' ' || items_fts.keywords, ?) > 0" }
        return try Item.fetchAll(db, sql: """
            SELECT items.* FROM items
            WHERE items.deleted_at IS NULL AND items.id IN (SELECT item_id FROM items_fts WHERE \(clauses.joined(separator: " AND ")))
            ORDER BY items.created_at DESC, items.id LIMIT ?
            """, arguments: StatementArguments(words.map(\.databaseValue) + [limit.databaseValue]))
    }
}
