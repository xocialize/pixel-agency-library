import Foundation
import GRDB
import ImageServerAPI

/// The retention sweeper: what the library promises about time, actually kept.
///
/// - Ephemeral uploads (inline job inputs) move to the trash when they expire.
/// - The trash is kept `trashRetention` (30 days), then purged.
/// - Blob rows nothing holds are deleted with their files, and files with no row at all (a write interrupted before
///   its database row) are deleted after `orphanGrace`.
///
/// **What holds a row** is read from the schema, not listed here: any foreign key to `asset` or `blob` that would
/// refuse the delete (`RESTRICT` or `NO ACTION`). A job's inputs and a brand kit's files therefore keep their assets
/// (they stay in the trash, held), and an app that adds its own table referencing `blob` (Pixel Agency Desktop's
/// variants) keeps those bytes without telling the sweeper. Cascading children (tags, memberships, colours) go with
/// their parent.
extension AssetLibrary {
    public struct SweepPolicy: Sendable, Equatable {
        public var trashRetention: TimeInterval
        public var orphanGrace: TimeInterval
        /// Most assets purged per sweep (the rest wait for the next one).
        public var batch: Int

        public init(trashRetention: TimeInterval = 30 * 86_400, orphanGrace: TimeInterval = 3_600, batch: Int = 1_000) {
            self.trashRetention = trashRetention
            self.orphanGrace = orphanGrace
            self.batch = batch
        }
    }

    public struct SweepReport: Sendable, Equatable {
        /// Ephemeral uploads moved to the trash.
        public var expired = 0
        /// Trashed assets deleted for good.
        public var purged = 0
        /// Trashed past retention but still held (a job input, a brand kit file).
        public var held = 0
        public var blobsRemoved = 0
        public var bytesFreed: Int64 = 0
        /// Files under `blobs/` with no database row, removed after the grace period.
        public var orphanFilesRemoved = 0

        public init() {}
    }

    /// Runs every step once. Safe at any time: it shares the database's write lock with imports and job commits.
    @discardableResult
    public func sweep(now: Date = Date(), policy: SweepPolicy = SweepPolicy()) throws -> SweepReport {
        var report = SweepReport()
        try database.pool.write { db in
            try db.execute(sql: """
                UPDATE asset SET trashed_at = ? WHERE retention = 'ephemeral' AND expires_at < ? AND trashed_at IS NULL
                """, arguments: [now, now])
            report.expired = db.changesCount

            let horizon = now.addingTimeInterval(-policy.trashRetention)
            let due = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset WHERE trashed_at IS NOT NULL AND trashed_at < ?",
                                       arguments: [horizon]) ?? 0
            let holds = try Self.blockingReferences(to: "asset", in: db).map { ref in
                "NOT EXISTS (SELECT 1 FROM \(ref.table.quotedDatabaseIdentifier) h WHERE h.\(ref.column.quotedDatabaseIdentifier) = asset.id)"
            }
            let unheld = "trashed_at IS NOT NULL AND trashed_at < ? " + holds.map { "AND " + $0 }.joined(separator: " ")
            report.held = due - (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset WHERE " + unheld, arguments: [horizon]) ?? 0)
            let purgeable = try String.fetchAll(db, sql: "SELECT id FROM asset WHERE \(unheld) LIMIT ?",
                                                arguments: [horizon, policy.batch])
            for id in purgeable { try db.execute(sql: "DELETE FROM asset WHERE id = ?", arguments: [id]) }
            report.purged = purgeable.count
        }
        let collected = try collectBlobs()
        report.blobsRemoved = collected.count
        report.bytesFreed = collected.bytes
        report.orphanFilesRemoved = try removeOrphanFiles(olderThan: now.addingTimeInterval(-policy.orphanGrace))
        return report
    }

    /// Deletes blob rows nothing holds, and their files. `only` limits it to these hashes (a replaced variant's old
    /// bytes, released as soon as the new ones are stored); nil considers every blob.
    @discardableResult
    public func collectBlobs(_ only: [String]? = nil) throws -> (count: Int, bytes: Int64) {
        if let only, only.isEmpty { return (0, 0) }
        var moved: [(from: URL, to: URL)] = []
        let result: (Int, Int64)
        do {
            result = try database.pool.write { db -> (Int, Int64) in
                let free = try Self.blockingReferences(to: "blob", in: db).map { ref in
                    "NOT EXISTS (SELECT 1 FROM \(ref.table.quotedDatabaseIdentifier) h WHERE h.\(ref.column.quotedDatabaseIdentifier) = blob.hash)"
                }
                var sql = "SELECT hash, ext, bytes FROM blob WHERE " + (free.isEmpty ? "1" : free.joined(separator: " AND "))
                var arguments: StatementArguments = []
                if let only {
                    sql += " AND hash IN (\(databaseQuestionMarks(count: only.count)))"
                    arguments = StatementArguments(only)
                }
                let rows = try Row.fetchAll(db, sql: sql, arguments: arguments)
                var bytes: Int64 = 0
                for row in rows {
                    let hash: String = row["hash"]
                    try db.execute(sql: "DELETE FROM blob WHERE hash = ?", arguments: [hash])
                    bytes += row["bytes"] ?? 0
                    // Moved aside inside the transaction (a write that wants these bytes again waits for it, then finds
                    // the file missing and stores it afresh); deleted only once the rows are gone for good.
                    let file = blobs.url(forHash: hash, ext: row["ext"])
                    let aside = blobs.tmpRoot.appendingPathComponent("gc-" + file.lastPathComponent)
                    if (try? FileManager.default.moveItem(at: file, to: aside)) != nil { moved.append((file, aside)) }
                }
                return (rows.count, bytes)
            }
        } catch {
            for (from, to) in moved { try? FileManager.default.moveItem(at: to, to: from) }
            throw error
        }
        for (_, aside) in moved { try? FileManager.default.removeItem(at: aside) }
        return result
    }

    /// Files under `blobs/` that no blob row names, older than `cutoff` (younger ones may belong to a write still in
    /// flight: the file is written before its row).
    func removeOrphanFiles(olderThan cutoff: Date) throws -> Int {
        let known = Set(try database.pool.read { db in try String.fetchAll(db, sql: "SELECT hash FROM blob") })
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: blobs.blobsRoot, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey])
        else { return 0 }
        var removed = 0
        for case let file as URL in walker {
            let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            let hash = "sha256:" + file.deletingPathExtension().lastPathComponent
            guard !known.contains(hash), let modified = values?.contentModificationDate, modified < cutoff else { continue }
            if (try? fm.removeItem(at: file)) != nil { removed += 1 }
        }
        return removed
    }

    /// Foreign keys to `table` that refuse a delete: the rows that hold it.
    static func blockingReferences(to table: String, in db: Database) throws -> [(table: String, column: String)] {
        let tables = try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'")
        var references: [(String, String)] = []
        for name in tables {
            for key in try Row.fetchAll(db, sql: "PRAGMA foreign_key_list(\(name.quotedDatabaseIdentifier))") {
                let target: String = key["table"]
                let onDelete = (key["on_delete"] as String? ?? "NO ACTION").uppercased()
                guard target == table, onDelete == "RESTRICT" || onDelete == "NO ACTION" else { continue }
                references.append((name, key["from"]))
            }
        }
        return references
    }

    // MARK: - Bytes for rows other than assets

    /// Records stored bytes as a blob row, inside the caller's transaction, so the row that references it (a variant)
    /// commits with it and the sweeper never sees the blob unheld. Re-stores the file if a sweep removed it after
    /// `stored` was written.
    public func recordBlob(_ stored: BlobStore.Stored, restoringFrom source: URL? = nil, data: Data? = nil, mime: String,
                           fileExtension ext: String, width: Int?, height: Int?, hasAlpha: Bool?, at date: Date = Date(),
                           in db: Database) throws {
        if !FileManager.default.fileExists(atPath: stored.url.path) {
            if let data { _ = try blobs.store(data, fileExtension: ext) }
            else if let source { _ = try blobs.store(fileAt: source, fileExtension: ext) }
        }
        try db.execute(sql: """
            INSERT OR IGNORE INTO blob(hash, bytes, mime, ext, width, height, has_alpha, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [stored.hash, stored.bytes, mime, ext, width, height, hasAlpha, date])
    }

    // MARK: - Trash and lineage

    /// An asset in the trash, and when it was trashed (it is purged `trashRetention` later unless restored).
    public struct TrashedAsset: Sendable, Equatable, Identifiable {
        public var asset: AssetInfo
        public var trashedAt: Date
        public var id: AssetID { asset.id }
    }

    /// The trash, most recently trashed first.
    public func trashed(limit: Int = 500) throws -> [TrashedAsset] {
        try database.pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT a.*, g.info_json, c.slug AS company_slug FROM asset a
                LEFT JOIN generation g ON g.id = a.generation_id
                LEFT JOIN company c ON c.id = a.company_id
                WHERE a.trashed_at IS NOT NULL ORDER BY a.trashed_at DESC LIMIT ?
                """, arguments: [limit]).map { row in
                TrashedAsset(asset: try Self.info(from: row, in: db), trashedAt: row["trashed_at"])
            }
        }
    }

    /// Assets made from `id` (its versions: their generation names it as an input), newest first. Covers this
    /// server's jobs and runs stored with `storeOutputs` alike.
    public func derivatives(of id: AssetID, limit: Int = 50) throws -> [AssetInfo] {
        try database.pool.read { db in
            try String.fetchAll(db, sql: """
                SELECT DISTINCT a.id FROM asset a JOIN generation g ON g.id = a.generation_id, json_each(g.info_json, '$.inputs') i
                WHERE i.value = ? AND a.id <> ? AND a.trashed_at IS NULL ORDER BY a.id DESC LIMIT ?
                """, arguments: [id.rawValue, id.rawValue, limit]).compactMap { try Self.info($0, in: db) }
        }
    }

    /// The file behind an asset, trashed or not (a trashed asset still shows in the trash).
    public func content(_ id: AssetID, includingTrashed: Bool) throws -> (url: URL, mime: String, hash: String, bytes: Int64)? {
        guard includingTrashed else { return try content(id) }
        return try database.pool.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT b.hash, b.ext, b.mime, b.bytes FROM asset a JOIN blob b ON b.hash = a.blob_hash WHERE a.id = ?
                """, arguments: [id.rawValue]) else { return nil }
            let hash: String = row["hash"]
            return (blobs.url(forHash: hash, ext: row["ext"]), row["mime"], hash, row["bytes"])
        }
    }

    public func thumbnail(_ id: AssetID, size: Int, includingTrashed: Bool) throws -> (url: URL, mime: String)? {
        guard let content = try content(id, includingTrashed: includingTrashed) else { return nil }
        return try thumbnails.thumbnail(forBlobAt: content.url, hash: content.hash, size: size)
    }
}
