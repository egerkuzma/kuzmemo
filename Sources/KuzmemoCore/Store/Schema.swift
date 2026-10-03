import GRDB

/// Forward-only migrations. `items_fts` is a self-contained FTS5 table maintained from Swift (normalized text,
/// keyed by `item_id`) instead of an external-content table, because `items` has a TEXT primary key and its
/// implicit rowid is not stable across VACUUM.
public enum Schema {
    public static func migrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
            CREATE TABLE memos(
             id TEXT PRIMARY KEY, created_at INTEGER NOT NULL, anchor_local TEXT NOT NULL, tz TEXT NOT NULL,
             input_kind TEXT NOT NULL CHECK(input_kind IN('voice','text')),
             status TEXT NOT NULL,
             audio_path TEXT,
             duration_ms INTEGER, stt_model TEXT, stt_ms INTEGER,
             transcript_raw TEXT, transcript_corrected TEXT,
             llm_model TEXT, llm_ms INTEGER, llm_usage_json TEXT, llm_response_json TEXT,
             intent TEXT, confidence REAL, fail_stage TEXT, fail_reason TEXT,
             attempts INTEGER NOT NULL DEFAULT 0, next_retry_at INTEGER,
             op_id TEXT, parent_memo_id TEXT);
            CREATE INDEX memos_status ON memos(status, next_retry_at);

            CREATE TABLE items(
             id TEXT PRIMARY KEY,
             kind TEXT NOT NULL CHECK(kind IN('reminder','event','task','note')),
             title TEXT NOT NULL, details TEXT, keywords TEXT NOT NULL DEFAULT '',
             date TEXT, time TEXT, duration_min INTEGER, tz TEXT,
             approximate INTEGER NOT NULL DEFAULT 0,
             recurrence_json TEXT,
             remind_lead_min INTEGER NOT NULL DEFAULT 0,
             status TEXT NOT NULL DEFAULT 'open' CHECK(status IN('open','done')),
             done_at INTEGER,
             source TEXT NOT NULL CHECK(source IN('voice','quickadd','manual','mcp')),
             memo_id TEXT REFERENCES memos(id) ON DELETE SET NULL,
             version INTEGER NOT NULL DEFAULT 1,
             created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL,
             deleted_at INTEGER);
            CREATE INDEX items_day ON items(date, time) WHERE deleted_at IS NULL;
            CREATE INDEX items_inbox ON items(created_at) WHERE date IS NULL AND deleted_at IS NULL AND status = 'open';
            CREATE INDEX items_series ON items(date) WHERE recurrence_json IS NOT NULL AND deleted_at IS NULL;

            CREATE TABLE item_exceptions(
             item_id TEXT NOT NULL REFERENCES items(id) ON DELETE CASCADE,
             occ_date TEXT NOT NULL,
             action TEXT NOT NULL CHECK(action IN('done','skip','moved')),
             moved_date TEXT, moved_time TEXT,
             PRIMARY KEY(item_id, occ_date));

            CREATE TABLE ops(id TEXT PRIMARY KEY, memo_id TEXT, created_at INTEGER NOT NULL, label TEXT NOT NULL, undone_at INTEGER);
            CREATE TABLE op_changes(
             op_id TEXT NOT NULL REFERENCES ops(id) ON DELETE CASCADE,
             seq INTEGER NOT NULL, tbl TEXT NOT NULL, row_id TEXT NOT NULL,
             before_json TEXT, after_json TEXT,
             PRIMARY KEY(op_id, seq));

            CREATE TABLE glossary_terms(
             id INTEGER PRIMARY KEY, canonical TEXT UNIQUE NOT NULL, kind TEXT,
             aliases_json TEXT NOT NULL DEFAULT '[]', spoken TEXT, enabled INTEGER NOT NULL DEFAULT 1);

            CREATE TABLE notification_state(
             item_id TEXT NOT NULL, occ_date TEXT NOT NULL, fire_at INTEGER, delivered_at INTEGER,
             PRIMARY KEY(item_id, occ_date));

            CREATE TABLE kv(key TEXT PRIMARY KEY, value TEXT);

            CREATE VIRTUAL TABLE items_fts USING fts5(
             item_id UNINDEXED, title, details, keywords, tokenize = 'trigram');
            """)
        }

        // A spoken answer to a clarifying question is interpreted together with the phrase that caused the
        // question; the question is stored with the answer so a retry after a failure still has the context.
        migrator.registerMigration("v2-followup-question") { db in
            try db.execute(sql: "ALTER TABLE memos ADD COLUMN followup_question TEXT")
        }

        // A plan the app itself stopped to ask about ("Delete 3 entries?") is kept with the question, so that a plain yes
        // applies exactly that plan, to the entries as they were, without asking the model to make it up again.
        migrator.registerMigration("v3-pending-plan") { db in
            try db.execute(sql: "ALTER TABLE memos ADD COLUMN pending_plan_json TEXT")
        }

        // A revision of every entry that only ever grows: kept by the database itself, so that every write to the entry's row
        // and to its per-occurrence overrides counts, including the writes an undo makes. `items.version` is restored by an
        // undo and does not see an occurrence moved, so it cannot tell a plan (or an editor) that the entry has moved on.
        migrator.registerMigration("v4-item-revisions") { db in
            try db.execute(sql: """
            CREATE TABLE item_revisions(item_id TEXT PRIMARY KEY NOT NULL, revision INTEGER NOT NULL);
            INSERT INTO item_revisions(item_id, revision) SELECT id, version FROM items;
            CREATE TRIGGER items_revision_insert AFTER INSERT ON items BEGIN
              INSERT INTO item_revisions(item_id, revision) VALUES (NEW.id, 1) ON CONFLICT(item_id) DO UPDATE SET revision = revision + 1;
            END;
            CREATE TRIGGER items_revision_update AFTER UPDATE ON items BEGIN
              INSERT INTO item_revisions(item_id, revision) VALUES (NEW.id, 1) ON CONFLICT(item_id) DO UPDATE SET revision = revision + 1;
            END;
            CREATE TRIGGER items_revision_delete AFTER DELETE ON items BEGIN
              DELETE FROM item_revisions WHERE item_id = OLD.id;
            END;
            CREATE TRIGGER item_exceptions_revision_insert AFTER INSERT ON item_exceptions BEGIN
              UPDATE item_revisions SET revision = revision + 1 WHERE item_id = NEW.item_id;
            END;
            CREATE TRIGGER item_exceptions_revision_update AFTER UPDATE ON item_exceptions BEGIN
              UPDATE item_revisions SET revision = revision + 1 WHERE item_id = NEW.item_id;
            END;
            CREATE TRIGGER item_exceptions_revision_delete AFTER DELETE ON item_exceptions BEGIN
              UPDATE item_revisions SET revision = revision + 1 WHERE item_id = OLD.item_id;
            END;
            """)
        }

        return migrator
    }
}
