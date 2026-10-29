import Foundation
import GRDB

/// The `v2-cms` migration (Docs/CMS-ROADMAP.md): companies and projects, per-project status, namespaced tags with
/// merge, uploaded-asset metadata and rights, blob facts (perceptual hash, palette, EXIF/IPTC), and an FTS5 search
/// document per asset kept in sync by triggers. All v1 data is kept.
enum CMSSchema {
    static let migrationID = "v2-cms"

    /// Namespaces whose values are structured facts (columns or memberships). `tag=model:x` and `model:x` in a query
    /// become column filters; these are never stored as tags.
    static let reservedNamespaces: Set<String> = [
        "capability", "model", "license", "source", "kind", "rights", "orientation", "colour", "color",
        "company", "client", "project", "brand", "collection", "status",
    ]

    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration(migrationID) { db in
            try companiesAndProjects(db)
            try assetColumns(db)
            try blobFacts(db)
            try tags(db)
            try searchDocument(db)
            try backfill(db)
        }
        migrator.registerMigration("v3-brand-collections") { db in
            try brandKits(db)
            try collections(db)
        }
        // v2's colour buckets used HSV-style hue ranges on Lab hue angles (red read as orange, blue as purple).
        // Lab values are stored, so re-bucketing is exact.
        migrator.registerMigration("v3b-colour-buckets") { db in
            let rows = try Row.fetchAll(db, sql: "SELECT blob_hash, rank, l, a, b FROM blob_color")
            for row in rows {
                try db.execute(sql: "UPDATE blob_color SET bucket = ? WHERE blob_hash = ? AND rank = ?",
                               arguments: [ImageFacts.bucket(l: row["l"], a: row["a"], b: row["b"]),
                                           row["blob_hash"] as String, row["rank"] as Int])
            }
        }
        // Auto-describe: every description a vision model wrote, with the model and licence (L2).
        migrator.registerMigration("v4-descriptions") { db in
            try db.create(table: "asset_description") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("asset_id", .text).notNull().indexed().references("asset", onDelete: .cascade)
                t.column("job_id", .text)
                t.column("model_id", .text).notNull()
                t.column("license_class", .text).notNull()
                t.column("caption", .text)
                t.column("alt_text", .text)
                t.column("tags_json", .text)
                t.column("raw_text", .text)
                t.column("created_at", .datetime).notNull()
            }
        }
        // Near-duplicates: pairs someone marked "not duplicates" (stored with a < b).
        migrator.registerMigration("v5-duplicate-dismissals") { db in
            try db.create(table: "asset_distinct") { t in
                t.column("a", .text).notNull().references("asset", onDelete: .cascade)
                t.column("b", .text).notNull().references("asset", onDelete: .cascade)
                t.column("created_at", .datetime).notNull()
                t.primaryKey(["a", "b"])
            }
        }
    }

    /// Brand kits: one row per kit, immutable revisions, and the assets each revision references (RESTRICT, so an
    /// asset a published revision uses cannot be deleted out from under it).
    private static func brandKits(_ db: Database) throws {
        try db.create(table: "brand_kit") { t in
            t.primaryKey("id", .text)
            t.column("company_id", .text).notNull().references("company", onDelete: .restrict)
            t.column("slug", .text).notNull().collate(.nocase)
            t.column("name", .text).notNull()
            t.column("current_revision", .integer).notNull().defaults(to: 0)
            t.column("created_at", .datetime).notNull()
            t.column("updated_at", .datetime).notNull()
            t.column("archived_at", .datetime)
            t.uniqueKey(["company_id", "slug"])
        }
        try db.create(table: "brand_kit_revision") { t in
            t.column("kit_id", .text).notNull().references("brand_kit", onDelete: .cascade)
            t.column("revision", .integer).notNull()
            t.column("manifest_json", .text).notNull()
            t.column("note", .text)
            t.column("created_by", .text)
            t.column("created_at", .datetime).notNull()
            t.primaryKey(["kit_id", "revision"])
        }
        try db.create(table: "brand_kit_asset") { t in
            t.column("kit_id", .text).notNull()
            t.column("revision", .integer).notNull()
            t.column("asset_id", .text).notNull().references("asset", onDelete: .restrict)
            t.column("role", .text).notNull()
            t.column("variant", .text)
            t.primaryKey(["kit_id", "revision", "asset_id", "role"])
            t.foreignKey(["kit_id", "revision"], references: "brand_kit_revision", onDelete: .cascade)
        }
        try db.create(index: "brand_kit_asset_asset", on: "brand_kit_asset", columns: ["asset_id"])
        try db.alter(table: "company") { t in
            t.add(column: "default_brand_kit_id", .text).references("brand_kit", onDelete: .setNull)
        }
        try db.alter(table: "project") { t in
            t.add(column: "brand_kit_id", .text).references("brand_kit", onDelete: .setNull)
        }
    }

    /// Collections are views: folders (manual, ordered, nestable) and smart collections (a saved structured query).
    /// Deleting one never deletes assets.
    private static func collections(_ db: Database) throws {
        try db.create(table: "collection") { t in
            t.primaryKey("id", .text)
            t.column("parent_id", .text).references("collection", onDelete: .cascade)
            t.column("company_id", .text).references("company", onDelete: .setNull)
            t.column("slug", .text).notNull().collate(.nocase)
            t.column("name", .text).notNull()
            t.column("kind", .text).notNull()
            t.column("query_json", .text)
            t.column("created_at", .datetime).notNull()
            t.column("updated_at", .datetime).notNull()
        }
        try db.execute(sql: "CREATE UNIQUE INDEX collection_slug ON collection(slug)")
        try db.create(table: "collection_item") { t in
            t.column("collection_id", .text).notNull().references("collection", onDelete: .cascade)
            t.column("asset_id", .text).notNull().references("asset", onDelete: .cascade)
            t.column("position", .double).notNull()
            t.column("added_at", .datetime).notNull()
            t.primaryKey(["collection_id", "asset_id"])
        }
        try db.create(index: "collection_item_asset", on: "collection_item", columns: ["asset_id"])
    }

    private static func companiesAndProjects(_ db: Database) throws {
        try db.create(table: "company") { t in
            t.primaryKey("id", .text)
            t.column("slug", .text).notNull().unique().collate(.nocase)
            t.column("name", .text).notNull()
            t.column("notes", .text)
            t.column("created_at", .datetime).notNull()
            t.column("updated_at", .datetime).notNull()
            t.column("archived_at", .datetime)
        }
        try db.create(table: "project") { t in
            t.primaryKey("id", .text)
            t.column("company_id", .text).references("company", onDelete: .restrict)
            t.column("slug", .text).notNull().collate(.nocase)
            t.column("name", .text).notNull()
            t.column("description", .text)
            t.column("created_at", .datetime).notNull()
            t.column("updated_at", .datetime).notNull()
            t.column("archived_at", .datetime)
            t.uniqueKey(["company_id", "slug"])
        }
        try db.execute(sql: "CREATE UNIQUE INDEX project_slug_loose ON project(slug) WHERE company_id IS NULL")
        try db.create(table: "project_asset") { t in
            t.column("project_id", .text).notNull().references("project", onDelete: .cascade)
            t.column("asset_id", .text).notNull().references("asset", onDelete: .cascade)
            t.column("is_home", .boolean).notNull().defaults(to: false)
            // draft | review | approved | final | rejected — per project: "approved for A" isn't "approved for B".
            t.column("status", .text)
            // hero | moodboard | deliverable | …
            t.column("role", .text)
            t.column("added_at", .datetime).notNull()
            t.column("added_origin", .text)
            t.primaryKey(["project_id", "asset_id"])
        }
        try db.execute(sql: "CREATE UNIQUE INDEX project_asset_home ON project_asset(asset_id) WHERE is_home = 1")
        try db.create(index: "project_asset_asset", on: "project_asset", columns: ["asset_id"])
    }

    private static func assetColumns(_ db: Database) throws {
        try db.alter(table: "asset") { t in
            t.add(column: "original_filename", .text)
            t.add(column: "caption", .text)
            t.add(column: "alt_text", .text)
            t.add(column: "notes", .text)
            t.add(column: "source_detail", .text)
            t.add(column: "creator", .text)
            t.add(column: "credit_line", .text)
            t.add(column: "copyright", .text)
            t.add(column: "uploaded_by", .text)
            t.add(column: "company_id", .text).references("company", onDelete: .setNull)
            // keep | ephemeral (inline job inputs, 24 h unless filed, tagged or referenced)
            t.add(column: "retention", .text).notNull().defaults(to: "keep")
            t.add(column: "expires_at", .datetime)
            t.add(column: "revision", .integer).notNull().defaults(to: 1)
            t.add(column: "updated_at", .datetime)
            // owned < open < licensed < client_owned < unknown (increasing restriction)
            t.add(column: "rights_class", .text).notNull().defaults(to: "unknown")
            t.add(column: "rights_holder", .text)
            t.add(column: "rights_expires_at", .datetime)
            t.add(column: "ai_use", .text).notNull().defaults(to: "unknown")
            t.add(column: "rights_json", .text)
        }
        try db.execute(sql: """
            ALTER TABLE asset ADD COLUMN orientation TEXT GENERATED ALWAYS AS (
                CASE WHEN width IS NULL OR height IS NULL THEN NULL
                     WHEN width > height * 1.05 THEN 'landscape'
                     WHEN height > width * 1.05 THEN 'portrait'
                     ELSE 'square' END) VIRTUAL
            """)
        try db.create(index: "asset_company", on: "asset", columns: ["company_id"])
        try db.create(index: "asset_source_id", on: "asset", columns: ["source", "id"])
        try db.create(index: "asset_rights", on: "asset", columns: ["rights_class"])
        try db.execute(sql: "CREATE INDEX asset_expiry ON asset(expires_at) WHERE retention = 'ephemeral'")
    }

    private static func blobFacts(_ db: Database) throws {
        try db.alter(table: "blob") { t in
            t.add(column: "phash", .integer)
            t.add(column: "meta_json", .text)
            t.add(column: "facts_version", .integer).notNull().defaults(to: 0)
        }
        try db.create(index: "blob_phash", on: "blob", columns: ["phash"])
        try db.create(table: "blob_color") { t in
            t.column("blob_hash", .text).notNull().references("blob", onDelete: .cascade)
            t.column("rank", .integer).notNull()
            t.column("hex", .text).notNull()
            t.column("l", .double).notNull()
            t.column("a", .double).notNull()
            t.column("b", .double).notNull()
            t.column("weight", .double).notNull()
            t.column("bucket", .text).notNull()
            t.primaryKey(["blob_hash", "rank"])
        }
        try db.create(index: "blob_color_bucket", on: "blob_color", columns: ["bucket"])
    }

    private static func tags(_ db: Database) throws {
        try db.alter(table: "tag") { t in
            t.add(column: "namespace", .text).notNull().defaults(to: "")
            t.add(column: "merged_into_id", .integer).references("tag", onDelete: .setNull)
            t.add(column: "color", .text)
            t.add(column: "created_at", .datetime)
        }
        try db.alter(table: "asset_tag") { t in
            t.add(column: "created_at", .datetime)
            t.add(column: "confidence", .double)
            t.add(column: "source_ref", .text)
        }
        try db.create(index: "asset_tag_tag", on: "asset_tag", columns: ["tag_id"])
        try db.create(index: "tag_namespace_idx", on: "tag", columns: ["namespace"])
        try db.create(table: "tag_namespace") { t in
            t.primaryKey("name", .text)
            // controlled (values listed) | open
            t.column("policy", .text).notNull()
            t.column("allowed_json", .text)
            t.column("description", .text)
        }
    }

    /// One search document per asset (not per blob), refreshed from `asset_doc_v` by triggers on every source table,
    /// and an external-content FTS5 index over it. `doc_id` is explicit because `asset` has a TEXT primary key whose
    /// hidden rowid may change on VACUUM.
    private static func searchDocument(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE asset_doc(
                doc_id INTEGER PRIMARY KEY,
                asset_id TEXT NOT NULL UNIQUE REFERENCES asset(id) ON DELETE CASCADE,
                name TEXT, caption TEXT, prompt TEXT, tags TEXT, auto_tags TEXT, places TEXT, credit TEXT, notes TEXT);

            CREATE VIRTUAL TABLE asset_fts USING fts5(
                name, caption, prompt, tags, auto_tags, places, credit, notes,
                content='asset_doc', content_rowid='doc_id',
                tokenize='unicode61 remove_diacritics 2', prefix='2 3');

            CREATE TRIGGER asset_doc_ai AFTER INSERT ON asset_doc BEGIN
                INSERT INTO asset_fts(rowid, name, caption, prompt, tags, auto_tags, places, credit, notes)
                VALUES (new.doc_id, new.name, new.caption, new.prompt, new.tags, new.auto_tags, new.places, new.credit, new.notes);
            END;
            CREATE TRIGGER asset_doc_ad AFTER DELETE ON asset_doc BEGIN
                INSERT INTO asset_fts(asset_fts, rowid, name, caption, prompt, tags, auto_tags, places, credit, notes)
                VALUES ('delete', old.doc_id, old.name, old.caption, old.prompt, old.tags, old.auto_tags, old.places, old.credit, old.notes);
            END;
            CREATE TRIGGER asset_doc_au AFTER UPDATE ON asset_doc BEGIN
                INSERT INTO asset_fts(asset_fts, rowid, name, caption, prompt, tags, auto_tags, places, credit, notes)
                VALUES ('delete', old.doc_id, old.name, old.caption, old.prompt, old.tags, old.auto_tags, old.places, old.credit, old.notes);
                INSERT INTO asset_fts(rowid, name, caption, prompt, tags, auto_tags, places, credit, notes)
                VALUES (new.doc_id, new.name, new.caption, new.prompt, new.tags, new.auto_tags, new.places, new.credit, new.notes);
            END;

            CREATE VIEW asset_doc_v AS
            SELECT a.id AS asset_id,
                trim(coalesce(a.name, '') || ' ' || coalesce(a.original_filename, '')) AS name,
                trim(coalesce(a.caption, '') || ' ' || coalesce(a.alt_text, '')) AS caption,
                coalesce(json_extract(g.info_json, '$.prompt'), '') AS prompt,
                coalesce((SELECT group_concat(t.name, ' ') FROM asset_tag at JOIN tag t ON t.id = at.tag_id
                          WHERE at.asset_id = a.id AND at.origin <> 'auto'), '') AS tags,
                coalesce((SELECT group_concat(t.name, ' ') FROM asset_tag at JOIN tag t ON t.id = at.tag_id
                          WHERE at.asset_id = a.id AND at.origin = 'auto'), '') AS auto_tags,
                trim(coalesce((SELECT group_concat(p.name || ' ' || p.slug, ' ') FROM project_asset pa
                               JOIN project p ON p.id = pa.project_id WHERE pa.asset_id = a.id), '')
                     || ' ' || coalesce((SELECT c.name || ' ' || c.slug FROM company c WHERE c.id = a.company_id), '')) AS places,
                trim(coalesce(a.creator, '') || ' ' || coalesce(a.credit_line, '') || ' ' || coalesce(a.rights_holder, '')
                     || ' ' || coalesce(a.copyright, '')) AS credit,
                coalesce(a.notes, '') AS notes
            FROM asset a LEFT JOIN generation g ON g.id = a.generation_id;
            """)

        // Refresh triggers: every source of a search-document column re-derives the affected rows from the view.
        let upsert = { (filter: String) in """
            INSERT INTO asset_doc(asset_id, name, caption, prompt, tags, auto_tags, places, credit, notes)
            SELECT asset_id, name, caption, prompt, tags, auto_tags, places, credit, notes FROM asset_doc_v WHERE \(filter)
            ON CONFLICT(asset_id) DO UPDATE SET name = excluded.name, caption = excluded.caption, prompt = excluded.prompt,
                tags = excluded.tags, auto_tags = excluded.auto_tags, places = excluded.places, credit = excluded.credit,
                notes = excluded.notes;
            """ }
        try db.execute(sql: """
            CREATE TRIGGER asset_doc_asset_ai AFTER INSERT ON asset BEGIN \(upsert("asset_id = new.id")) END;
            CREATE TRIGGER asset_doc_asset_au AFTER UPDATE OF name, original_filename, caption, alt_text, notes, creator,
                credit_line, copyright, rights_holder, company_id, generation_id ON asset
                BEGIN \(upsert("asset_id = new.id")) END;
            CREATE TRIGGER asset_doc_tag_ai AFTER INSERT ON asset_tag BEGIN \(upsert("asset_id = new.asset_id")) END;
            CREATE TRIGGER asset_doc_tag_ad AFTER DELETE ON asset_tag BEGIN \(upsert("asset_id = old.asset_id")) END;
            CREATE TRIGGER asset_doc_tag_au AFTER UPDATE ON asset_tag BEGIN
                \(upsert("asset_id = old.asset_id")) \(upsert("asset_id = new.asset_id")) END;
            CREATE TRIGGER asset_doc_pa_ai AFTER INSERT ON project_asset BEGIN \(upsert("asset_id = new.asset_id")) END;
            CREATE TRIGGER asset_doc_pa_ad AFTER DELETE ON project_asset BEGIN \(upsert("asset_id = old.asset_id")) END;
            CREATE TRIGGER asset_doc_tagname_au AFTER UPDATE OF name ON tag BEGIN
                \(upsert("asset_id IN (SELECT asset_id FROM asset_tag WHERE tag_id = new.id)")) END;
            CREATE TRIGGER asset_doc_project_au AFTER UPDATE OF name, slug ON project BEGIN
                \(upsert("asset_id IN (SELECT asset_id FROM project_asset WHERE project_id = new.id)")) END;
            CREATE TRIGGER asset_doc_company_au AFTER UPDATE OF name, slug ON company BEGIN
                \(upsert("asset_id IN (SELECT id FROM asset WHERE company_id = new.id)")) END;
            CREATE TRIGGER asset_doc_generation_ai AFTER INSERT ON generation BEGIN
                \(upsert("asset_id IN (SELECT id FROM asset WHERE generation_id = new.id)")) END;
            """)
    }

    private static func backfill(_ db: Database) throws {
        let now = Date()
        // v1 assets: edits start now; generated work is ours, v1 uploads stay unknown (a migration never deletes).
        try db.execute(sql: "UPDATE asset SET updated_at = created_at WHERE updated_at IS NULL")
        try db.execute(sql: "UPDATE asset SET rights_class = 'owned', ai_use = 'allowed' WHERE source = 'generated'")
        // Namespaces from names; reserved-namespace (system) tags are dropped — the columns hold the same facts.
        try db.execute(sql: """
            UPDATE tag SET namespace = CASE WHEN instr(name, ':') > 0 THEN lower(substr(name, 1, instr(name, ':') - 1))
                ELSE '' END, created_at = coalesce(created_at, ?)
            """, arguments: [now])
        try db.execute(sql: "DELETE FROM asset_tag WHERE origin = 'system'")
        try db.execute(sql: "UPDATE asset_tag SET created_at = coalesce(created_at, ?)", arguments: [now])
        // Seed namespace policies.
        try db.execute(sql: """
            INSERT INTO tag_namespace(name, policy, allowed_json, description) VALUES
              ('usage', 'controlled', '["web","social","print","ooh","email","presentation"]', 'Where the asset is meant to be used'),
              ('subject', 'open', NULL, 'What is depicted'),
              ('style', 'open', NULL, 'Visual style'),
              ('campaign', 'open', NULL, 'Campaign or initiative'),
              ('season', 'open', NULL, 'Season or time of year')
            """)
        // Build every search document (the tag clean-up above has already created some, via the triggers).
        try db.execute(sql: """
            INSERT INTO asset_doc(asset_id, name, caption, prompt, tags, auto_tags, places, credit, notes)
            SELECT asset_id, name, caption, prompt, tags, auto_tags, places, credit, notes FROM asset_doc_v WHERE true
            ON CONFLICT(asset_id) DO UPDATE SET name = excluded.name, caption = excluded.caption, prompt = excluded.prompt,
                tags = excluded.tags, auto_tags = excluded.auto_tags, places = excluded.places, credit = excluded.credit,
                notes = excluded.notes
            """)
    }
}
