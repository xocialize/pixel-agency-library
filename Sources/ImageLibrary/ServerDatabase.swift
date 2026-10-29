import Foundation
import GRDB

/// The app's one SQLite file. The job ledger and the asset library share it so that "job succeeded" and "its outputs
/// exist" commit in one transaction — a crash can leave an orphan blob file (GC removes it), never a succeeded job
/// without outputs or an asset without its generation row.
public final class ServerDatabase: Sendable {
    public let pool: DatabasePool
    public let url: URL

    /// - Parameter migrateUpTo: stop after this migration (tests that exercise an upgrade path). nil = all.
    public init(url: URL, migrateUpTo: String? = nil) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var config = Configuration()
        config.foreignKeysEnabled = true
        config.label = "MLXImageServer"
        config.prepareDatabase { db in
            db.add(function: Self.hammingFunction)
        }
        pool = try DatabasePool(path: url.path, configuration: config)
        self.url = url
        if let migrateUpTo {
            try Self.migrator.migrate(pool, upTo: migrateUpTo)
        } else {
            try Self.migrator.migrate(pool)
        }
    }

    /// Runs any migrations not yet applied (after an upgrade-path test seeded an older schema).
    public func migrateToLatest() throws {
        try Self.migrator.migrate(pool)
    }

    /// `hamming(a, b)`: bit distance between two 64-bit perceptual hashes (near-duplicate search).
    static let hammingFunction = DatabaseFunction("hamming", argumentCount: 2, pure: true) { values in
        guard let a = Int64.fromDatabaseValue(values[0]), let b = Int64.fromDatabaseValue(values[1]) else { return nil }
        return Int64((UInt64(bitPattern: a) ^ UInt64(bitPattern: b)).nonzeroBitCount)
    }

    /// In-memory-equivalent database for tests (a temp file; DatabasePool needs WAL on disk).
    public static func temporary() throws -> ServerDatabase {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("imgsrv-\(UUID().uuidString)")
        return try ServerDatabase(url: dir.appendingPathComponent("library.sqlite"))
    }

    static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()

        m.registerMigration("v1-ledger-library") { db in
            // Job ledger. `snapshot_json` is the source of truth for the public view; the other columns exist to
            // index, order and constrain.
            try db.create(table: "job") { t in
                t.primaryKey("id", .text)
                t.column("seq", .integer).notNull().unique()
                t.column("state", .text).notNull()
                t.column("capability", .text).notNull()
                t.column("model_id", .text)
                t.column("package_id", .text)
                t.column("origin", .text).notNull()
                t.column("client_id", .text).notNull()
                t.column("idempotency_key", .text)
                t.column("priority", .integer).notNull().defaults(to: 0)
                t.column("attempt", .integer).notNull().defaults(to: 0)
                t.column("requeue_count", .integer).notNull().defaults(to: 0)
                t.column("bypass_count", .integer).notNull().defaults(to: 0)
                t.column("license_class", .text)
                t.column("snapshot_json", .text).notNull()
                t.column("enqueued_at", .datetime).notNull()
                t.column("started_at", .datetime)
                t.column("finished_at", .datetime)
            }
            try db.create(index: "job_state_seq", on: "job", columns: ["state", "seq"])
            try db.execute(sql: """
                CREATE UNIQUE INDEX job_idempotency ON job(client_id, idempotency_key)
                WHERE idempotency_key IS NOT NULL
                """)

            // Content-addressed bytes. Many assets may share one blob.
            try db.create(table: "blob") { t in
                t.primaryKey("hash", .text)
                t.column("bytes", .integer).notNull()
                t.column("mime", .text).notNull()
                t.column("ext", .text).notNull()
                t.column("width", .integer)
                t.column("height", .integer)
                t.column("has_alpha", .boolean).notNull().defaults(to: false)
                t.column("created_at", .datetime).notNull()
            }

            try db.create(table: "generation") { t in
                t.primaryKey("id", .text)
                t.column("job_id", .text).notNull().indexed()
                t.column("capability", .text).notNull()
                t.column("model_id", .text).notNull()
                t.column("package_id", .text).notNull()
                t.column("license_class", .text).notNull()
                t.column("info_json", .text).notNull()
                t.column("created_at", .datetime).notNull()
            }

            try db.create(table: "asset") { t in
                t.primaryKey("id", .text)
                t.column("blob_hash", .text).notNull().indexed().references("blob", onDelete: .restrict)
                t.column("kind", .text).notNull()
                t.column("name", .text)
                t.column("mime", .text).notNull()
                t.column("width", .integer)
                t.column("height", .integer)
                t.column("bytes", .integer).notNull()
                t.column("source", .text).notNull()
                t.column("job_id", .text).indexed()
                t.column("generation_id", .text).references("generation", onDelete: .setNull)
                t.column("ordinal", .integer).notNull().defaults(to: 0)
                t.column("license_class", .text).notNull()
                t.column("license_json", .text)
                // Reserved for the multi-user CMS; nil = the machine's owner.
                t.column("owner_principal", .text)
                t.column("search_text", .text)
                t.column("created_at", .datetime).notNull()
                t.column("trashed_at", .datetime)
            }

            try db.create(table: "job_output") { t in
                t.column("job_id", .text).notNull().references("job", onDelete: .cascade)
                t.column("ordinal", .integer).notNull()
                t.column("asset_id", .text).notNull().references("asset", onDelete: .cascade)
                t.primaryKey(["job_id", "ordinal"])
            }
            try db.create(table: "job_input") { t in
                t.column("job_id", .text).notNull().references("job", onDelete: .cascade)
                t.column("name", .text).notNull()
                t.column("ordinal", .integer).notNull()
                t.column("asset_id", .text).notNull().references("asset", onDelete: .restrict)
                t.primaryKey(["job_id", "name", "ordinal"])
            }

            try db.create(table: "tag") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull().unique().collate(.nocase)
            }
            try db.create(table: "asset_tag") { t in
                t.column("asset_id", .text).notNull().references("asset", onDelete: .cascade)
                t.column("tag_id", .integer).notNull().references("tag", onDelete: .cascade)
                // user | system | agent
                t.column("origin", .text).notNull()
                t.primaryKey(["asset_id", "tag_id"])
            }
        }
        // Small durable key/value settings (pinned models, …) that must survive relaunch with the ledger.
        m.registerMigration("v1b-settings") { db in
            try db.create(table: "setting") { t in
                t.primaryKey("key", .text)
                t.column("value", .text).notNull()
                t.column("updated_at", .datetime).notNull()
            }
        }
        CMSSchema.register(in: &m)
        return m
    }
}

/// Durable key/value settings stored beside the ledger.
public final class SettingsStore: Sendable {
    public let database: ServerDatabase

    public init(database: ServerDatabase) {
        self.database = database
    }

    public func string(_ key: String) -> String? {
        try? database.pool.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM setting WHERE key = ?", arguments: [key])
        }
    }

    public func set(_ value: String?, for key: String) throws {
        try database.pool.write { db in
            if let value {
                try db.execute(sql: """
                    INSERT INTO setting(key, value, updated_at) VALUES (?, ?, ?)
                    ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at
                    """, arguments: [key, value, Date()])
            } else {
                try db.execute(sql: "DELETE FROM setting WHERE key = ?", arguments: [key])
            }
        }
    }

    public func stringSet(_ key: String) -> Set<String> {
        guard let raw = string(key), let data = raw.data(using: .utf8),
              let values = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(values)
    }

    public func set(_ values: Set<String>, for key: String) throws {
        let data = try JSONEncoder().encode(values.sorted())
        try set(String(decoding: data, as: UTF8.self), for: key)
    }
}

extension JSONEncoder {
    /// The one encoder for everything stored in or served from the database: ISO-8601 dates, sorted keys.
    public static let imageServer: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()
}

extension JSONDecoder {
    public static let imageServer: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
