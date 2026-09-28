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
        // Only very short words: scan the (small) corpus and filter in Swift.
        let words = SearchText.tokens(query)
        guard !words.isEmpty else { return [] }
        let all = try Item.filter(Column("deleted_at") == nil).limit(5000).fetchAll(db)
        return Array(all.filter { item in
            let haystack = SearchText.normalize([item.title, item.details ?? "", item.keywords].joined(separator: " "))
            return words.allSatisfy { haystack.contains($0) }
        }.prefix(limit))
    }
}
