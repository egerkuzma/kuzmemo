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
}
