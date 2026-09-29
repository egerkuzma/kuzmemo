import Foundation
import GRDB

extension Store {
    /// A small persistent setting or flag (the `kv` table).
    public func setting(_ key: String) async throws -> String? {
        try await writer.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM kv WHERE key = ?", arguments: [key])
        }
    }

    public func setSetting(_ value: String?, for key: String) async throws {
        try await writer.write { db in
            if let value {
                try db.execute(sql: "INSERT INTO kv(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value", arguments: [key, value])
            } else {
                try db.execute(sql: "DELETE FROM kv WHERE key = ?", arguments: [key])
            }
        }
    }

    /// Fills an empty glossary with the vocabulary of the user's line of work, once. After that the glossary
    /// belongs to the user: deleting every term does not bring the defaults back.
    @discardableResult
    public func seedGlossaryIfNeeded(_ terms: [GlossaryTerm] = Glossary.defaults) async throws -> Bool {
        let flag = "glossary.seeded.v1"
        guard try await setting(flag) == nil else { return false }
        if try await glossary().isEmpty {
            for term in terms { try await save(term: term) }
        }
        try await setSetting("1", for: flag)
        return true
    }
}

extension Glossary {
    /// Ad networks the user talks about, with the ways a speech recognizer tends to write them and how a voice
    /// should say them.
    public static let defaults: [GlossaryTerm] = [
        GlossaryTerm(canonical: "Notion", kind: "network", aliases: ["нотион", "ношн", "нотиона"], spoken: "Нотион"),
        GlossaryTerm(canonical: "GitHub", kind: "network", aliases: ["гитхаб", "гит"], spoken: "Гитхаб"),
        GlossaryTerm(canonical: "Figma", kind: "network", aliases: ["фигма", "фигмы", "Фигма"], spoken: "Фигма"),
        GlossaryTerm(canonical: "Slack", kind: "network", aliases: ["слак"], spoken: "Слак"),
        GlossaryTerm(canonical: "Zoom", kind: "network", aliases: ["зум", "клик аду"], spoken: "Зум"),
    ]
}
