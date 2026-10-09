import Foundation
import GRDB

/// Forward-only migrations keyed on `PRAGMA user_version`.
///
/// Not GRDB's `DatabaseMigrator`: it reads applied identifiers outside the migration
/// transaction, so two processes racing the first open could both run v1. Here the
/// version check and the DDL share one IMMEDIATE transaction; the loser waits on
/// busy_timeout, then sees the bumped version and does nothing.
enum StoreSchema {
    /// Index i migrates user_version i → i+1. Never edit a shipped entry; append.
    static let migrations: [@Sendable (Database) throws -> Void] = [v1, v2, v3]

    static var latestVersion: Int { migrations.count }

    static func migrate(_ db: Database) throws {
        let version = try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0
        if version > latestVersion { throw StoreError.schemaTooNew(found: version, known: latestVersion) }
        for v in version..<latestVersion {
            try migrations[v](db)
            try db.execute(sql: "PRAGMA user_version = \(v + 1)")
        }
    }

    /// W20: EOD standups. Notes, not proof: unchained, mutable, no triggers.
    private static func v2(_ db: Database) throws {
        try db.execute(sql: """
        CREATE TABLE standup(
          date TEXT PRIMARY KEY,
          body TEXT NOT NULL,
          generated_ms INTEGER,
          edited_ms INTEGER,
          inputs_sha256 TEXT,
          model TEXT) STRICT;
        """)
    }

    /// W24: Jev classification cache. Derived data like rules: unchained, mutable, clearable.
    /// `category_key` NULL = a failed request, asked again after `retry_after_ms`.
    private static func v3(_ db: Database) throws {
        try db.execute(sql: """
        CREATE TABLE jev_class(
          key TEXT PRIMARY KEY,
          app TEXT NOT NULL, host TEXT NOT NULL, path_tpl TEXT NOT NULL, title_norm TEXT NOT NULL,
          category_key TEXT, category_conf REAL, category_probs TEXT,
          project_name TEXT, project_conf REAL,
          model TEXT, created_ms INTEGER NOT NULL, input_tokens INTEGER,
          retry_after_ms INTEGER) STRICT;
        CREATE INDEX jev_class_path ON jev_class(app, host, path_tpl);
        CREATE INDEX jev_class_host ON jev_class(app, host);
        """)
    }

    private static func v1(_ db: Database) throws {
        try db.execute(sql: """
        CREATE TABLE setting(key TEXT PRIMARY KEY, value TEXT NOT NULL) STRICT;

        CREATE TABLE chain_head(
          id INTEGER PRIMARY KEY CHECK(id=1),
          seq INTEGER NOT NULL,
          hash BLOB NOT NULL CHECK(length(hash)=32)) STRICT;

        CREATE TABLE span(
          seq INTEGER PRIMARY KEY,
          start_ms INTEGER NOT NULL, end_ms INTEGER NOT NULL,
          tz_id TEXT NOT NULL, tz_offset_s INTEGER NOT NULL,
          kind TEXT NOT NULL CHECK(kind IN ('active','idle')),
          bundle_id TEXT, app_name TEXT NOT NULL, title TEXT, url TEXT,
          enc_ver INTEGER NOT NULL DEFAULT 1,
          blind BLOB NOT NULL CHECK(length(blind)=16),
          content_hash BLOB NOT NULL CHECK(length(content_hash)=32),
          prev_hash BLOB NOT NULL CHECK(length(prev_hash)=32),
          hash BLOB NOT NULL CHECK(length(hash)=32),
          CHECK(end_ms > start_ms)) STRICT;
        CREATE UNIQUE INDEX span_start ON span(start_ms);

        CREATE TABLE edit(
          seq INTEGER PRIMARY KEY,
          grp INTEGER NOT NULL,
          created_ms INTEGER NOT NULL, tz_id TEXT NOT NULL,
          op TEXT NOT NULL CHECK(op IN ('delete','assign','add','undo','note')),
          lo_ms INTEGER NOT NULL, hi_ms INTEGER NOT NULL,
          target INTEGER,
          payload TEXT NOT NULL CHECK(json_valid(payload)),
          enc_ver INTEGER NOT NULL DEFAULT 1,
          blind BLOB NOT NULL CHECK(length(blind)=16),
          content_hash BLOB NOT NULL CHECK(length(content_hash)=32),
          prev_hash BLOB NOT NULL CHECK(length(prev_hash)=32),
          hash BLOB NOT NULL CHECK(length(hash)=32),
          CHECK(hi_ms > lo_ms),
          CHECK((op IN ('undo','note')) = (target IS NOT NULL)),
          CHECK(grp <= seq)) STRICT;
        CREATE INDEX edit_range ON edit(lo_ms, hi_ms);
        CREATE INDEX edit_grp ON edit(grp);

        CREATE TRIGGER span_chain BEFORE INSERT ON span BEGIN
          SELECT RAISE(ABORT, 'chain fork') WHERE NEW.seq != (SELECT seq FROM chain_head) + 1
             OR NEW.prev_hash != (SELECT hash FROM chain_head);
          SELECT RAISE(ABORT, 'overlap')
            WHERE NEW.start_ms < (SELECT end_ms FROM span ORDER BY start_ms DESC LIMIT 1);
        END;
        CREATE TRIGGER span_head AFTER INSERT ON span BEGIN
          UPDATE chain_head SET seq = NEW.seq, hash = NEW.hash;
        END;
        CREATE TRIGGER span_ro_u BEFORE UPDATE ON span BEGIN SELECT RAISE(ABORT, 'append-only'); END;
        CREATE TRIGGER span_ro_d BEFORE DELETE ON span BEGIN SELECT RAISE(ABORT, 'append-only'); END;

        CREATE TRIGGER edit_chain BEFORE INSERT ON edit BEGIN
          SELECT RAISE(ABORT, 'chain fork') WHERE NEW.seq != (SELECT seq FROM chain_head) + 1
             OR NEW.prev_hash != (SELECT hash FROM chain_head);
          -- a group is a contiguous seq run starting at its own id
          SELECT RAISE(ABORT, 'bad group') WHERE NEW.grp != NEW.seq
             AND NEW.grp IS NOT (SELECT grp FROM edit WHERE seq = NEW.seq - 1);
          -- undo/note target an earlier, existing group
          SELECT RAISE(ABORT, 'bad target') WHERE NEW.target IS NOT NULL
             AND (NEW.target >= NEW.grp
                  OR NOT EXISTS (SELECT 1 FROM edit WHERE seq = NEW.target AND grp = NEW.target));
        END;
        CREATE TRIGGER edit_head AFTER INSERT ON edit BEGIN
          UPDATE chain_head SET seq = NEW.seq, hash = NEW.hash;
        END;
        CREATE TRIGGER edit_ro_u BEFORE UPDATE ON edit BEGIN SELECT RAISE(ABORT, 'append-only'); END;
        CREATE TRIGGER edit_ro_d BEFORE DELETE ON edit BEGIN SELECT RAISE(ABORT, 'append-only'); END;

        CREATE TABLE live_span(
          id INTEGER PRIMARY KEY CHECK(id=1),
          start_ms INTEGER NOT NULL, last_seen_ms INTEGER NOT NULL,
          tz_id TEXT NOT NULL, tz_offset_s INTEGER NOT NULL,
          kind TEXT NOT NULL CHECK(kind IN ('active','idle')),
          bundle_id TEXT, app_name TEXT NOT NULL, title TEXT, url TEXT,
          -- blinding nonce of the row this becomes when chained (priv_hash salt, see ChainCodec)
          blind BLOB NOT NULL CHECK(length(blind)=16)) STRICT;

        -- mutable config, referenced by id from chained payloads: archive, never delete
        CREATE TABLE category(
          id INTEGER PRIMARY KEY,
          key TEXT NOT NULL UNIQUE,
          name TEXT NOT NULL,
          level TEXT NOT NULL CHECK(level IN ('productive','neutral','distracting')),
          is_work INTEGER NOT NULL,
          behavior TEXT NOT NULL CHECK(behavior IN ('normal','meeting','exclude')),
          color_slot INTEGER,
          sort INTEGER NOT NULL DEFAULT 0,
          archived INTEGER NOT NULL DEFAULT 0) STRICT;
        CREATE TABLE project(
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          name TEXT NOT NULL,
          client TEXT,
          archived INTEGER NOT NULL DEFAULT 0) STRICT;
        CREATE TABLE rule(
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          origin TEXT NOT NULL CHECK(origin IN ('seed','user')),
          seed_key TEXT UNIQUE,
          enabled INTEGER NOT NULL DEFAULT 1,
          priority INTEGER NOT NULL DEFAULT 0,
          bundle_id TEXT, app_name TEXT, host TEXT, path_prefix TEXT, title_regex TEXT,
          category_id INTEGER REFERENCES category(id),
          project_id INTEGER REFERENCES project(id),
          created_ms INTEGER NOT NULL, updated_ms INTEGER NOT NULL, deleted_ms INTEGER,
          CHECK(COALESCE(bundle_id, app_name, host, path_prefix, title_regex) IS NOT NULL),
          CHECK(category_id IS NOT NULL OR project_id IS NOT NULL)) STRICT;

        -- not chained; attests the chain (item 9 fills it). Insert-only.
        CREATE TABLE anchor(
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          head_seq INTEGER NOT NULL,
          head_hash BLOB NOT NULL CHECK(length(head_hash)=32),
          method TEXT NOT NULL,
          tsa TEXT,
          requested_ms INTEGER NOT NULL,
          gen_time_ms INTEGER,
          token BLOB,
          nonce BLOB) STRICT;
        CREATE TRIGGER anchor_ro_u BEFORE UPDATE ON anchor BEGIN SELECT RAISE(ABORT, 'insert-only'); END;
        CREATE TRIGGER anchor_ro_d BEFORE DELETE ON anchor BEGIN SELECT RAISE(ABORT, 'insert-only'); END;
        """)
        let installId = UUID().uuidString.lowercased()
        try db.execute(sql: "INSERT INTO setting(key, value) VALUES ('install_id', ?)", arguments: [installId])
        try db.execute(sql: "INSERT INTO chain_head(id, seq, hash) VALUES (1, 0, ?)",
                       arguments: [ChainCodec.genesis(installId: installId)])
    }
}
