import Foundation
import GRDB
import ImageServerAPI

/// The asset library: content-addressed blobs, asset rows, generation provenance, projects, tags and search.
///
/// Layout under `root` (relocatable as a whole): `library.sqlite`, `blobs/sha256/…`, `tmp/`. Thumbnails live in a
/// separate purgeable cache. CMS operations (companies, projects, tags, edits, uploads, search) are in
/// `LibraryCMS.swift`; retention (expiry, trash purge, blob GC) in `Sweeper.swift`.
public final class AssetLibrary: Sendable {
    public let database: ServerDatabase
    public let blobs: BlobStore
    public let thumbnails: ThumbnailCache

    public init(database: ServerDatabase, blobs: BlobStore, thumbnails: ThumbnailCache) {
        self.database = database
        self.blobs = blobs
        self.thumbnails = thumbnails
    }

    /// Opens (or creates) the library at `root`, with thumbnails under `cacheRoot`.
    public static func open(root: URL, cacheRoot: URL) throws -> (AssetLibrary, JobLedger) {
        let database = try ServerDatabase(url: root.appendingPathComponent("library.sqlite"))
        let library = AssetLibrary(database: database, blobs: try BlobStore(root: root),
                                   thumbnails: try ThumbnailCache(root: cacheRoot.appendingPathComponent("thumbs")))
        return (library, JobLedger(database: database))
    }

    /// One output ready to store: already encoded (with provenance embedded).
    public struct PreparedOutput: Sendable {
        public var encoded: ImageEncoding.Encoded
        public var kind: AssetKind
        public var generation: GenerationInfo

        public init(encoded: ImageEncoding.Encoded, kind: AssetKind = .image, generation: GenerationInfo) {
            self.encoded = encoded
            self.kind = kind
            self.generation = generation
        }
    }

    /// Where a job's outputs are filed (resolved and frozen at submit).
    public struct Filing: Sendable, Equatable {
        public var projectID: String
        public var status: ProjectStatus?
        public var role: String?

        public init(projectID: String, status: ProjectStatus? = nil, role: String? = nil) {
            self.projectID = projectID
            self.status = status
            self.role = role
        }
    }

    /// Stores the outputs, files them, and marks the job succeeded — in **one** transaction, after the blob files
    /// exist. Returns the job entry as committed (state `succeeded`, `outputs` filled).
    /// `alsoInTransaction` runs inside the same transaction, before the job is marked succeeded (a describe job's
    /// write-back, which has no outputs of its own).
    public func commitSuccess(of entry: LedgerEntry, outputs: [PreparedOutput], license: LicenseStamp,
                              filing: Filing? = nil, tagOrigin: TagOrigin = .api, finishedAt: Date = Date(),
                              alsoInTransaction: (@Sendable (Database) throws -> Void)? = nil) throws -> LedgerEntry {
        let prepared = try prepare(outputs)
        let inputs = entry.snapshot.spec.inputs.values.flatMap { $0 }
        let inherited = try inputSummary(inputs)
        let tags = entry.snapshot.spec.tags + (entry.snapshot.spec.file?.tags ?? [])

        return try database.pool.write { db in
            var entry = entry
            let assetIDs = try insertOutputs(outputs, prepared: prepared, runID: entry.snapshot.id.rawValue, inputs: inputs,
                                             inherited: inherited, license: license, filing: filing, tags: tags,
                                             tagOrigin: tagOrigin, at: finishedAt, in: db)
            for (ordinal, assetID) in assetIDs.enumerated() {
                try db.execute(sql: "INSERT INTO job_output(job_id, ordinal, asset_id) VALUES (?, ?, ?)",
                               arguments: [entry.snapshot.id.rawValue, ordinal, assetID.rawValue])
            }
            try alsoInTransaction?(db)
            entry.snapshot.outputs = assetIDs
            entry.snapshot.state = .succeeded
            entry.snapshot.progress = nil
            entry.snapshot.error = nil
            entry.snapshot.finishedAt = finishedAt
            try JobLedger.write(entry, in: db, insert: false)
            return entry
        }
    }

    /// Stores outputs of a run this server's job ledger doesn't own (Pixel Agency Desktop's tickets): the same rows as
    /// `commitSuccess` (blobs, generation provenance, assets inheriting their inputs' licence and rights, filing,
    /// tags), with `runID` recorded as their job id, and no ledger entry. `alsoInTransaction` gets the new assets, so
    /// the caller records its own state in the same transaction. Returns the new assets in output order.
    @discardableResult
    public func storeOutputs(_ outputs: [PreparedOutput], runID: String, inputs: [AssetID], license: LicenseStamp,
                             filing: Filing? = nil, tags: [String] = [], tagOrigin: TagOrigin = .api, at date: Date = Date(),
                             alsoInTransaction: ((Database, [AssetID]) throws -> Void)? = nil) throws -> [AssetID] {
        let prepared = try prepare(outputs)
        let inherited = try inputSummary(inputs)
        return try database.pool.write { db in
            let assetIDs = try insertOutputs(outputs, prepared: prepared, runID: runID, inputs: inputs, inherited: inherited,
                                             license: license, filing: filing, tags: tags, tagOrigin: tagOrigin, at: date, in: db)
            try alsoInTransaction?(db, assetIDs)
            return assetIDs
        }
    }

    /// Writes the outputs' bytes (before any database row names them) and computes their facts.
    private func prepare(_ outputs: [PreparedOutput]) throws -> [(blob: BlobStore.Stored, facts: ImageFacts?)] {
        try outputs.map { output in
            (try blobs.store(output.encoded.data, fileExtension: output.encoded.format.fileExtension),
             try? ImageFacts.compute(output.encoded.data))
        }
    }

    /// The rows behind stored outputs, inside the caller's transaction. Derived outputs inherit from their inputs:
    /// the most restrictive licence class (model ∪ inputs) and rights.
    private func insertOutputs(_ outputs: [PreparedOutput], prepared: [(blob: BlobStore.Stored, facts: ImageFacts?)],
                               runID: String, inputs: [AssetID], inherited: InputSummary, license: LicenseStamp,
                               filing: Filing?, tags: [String], tagOrigin: TagOrigin, at date: Date,
                               in db: Database) throws -> [AssetID] {
        let licenseJSON = String(decoding: try JSONEncoder.imageServer.encode(license), as: UTF8.self)
        let licenseClass = LicenseClass.mostRestrictive([license.licenseClass, inherited.licenseClass])
        let rights = inputs.isEmpty ? AssetRights(rightsClass: .owned, aiUse: .allowed) : inherited.rights
        let rightsJSON = try rights.details.map { String(decoding: try JSONEncoder.imageServer.encode($0), as: UTF8.self) }
        var assetIDs: [AssetID] = []
        for (ordinal, (output, item)) in zip(outputs, prepared).enumerated() {
            let e = output.encoded
            let blob = item.blob
            // A sweep may have collected identical bytes since `store`: store them again.
            if !FileManager.default.fileExists(atPath: blob.url.path) { _ = try blobs.store(e.data, fileExtension: e.format.fileExtension) }
            try db.execute(sql: """
                INSERT OR IGNORE INTO blob(hash, bytes, mime, ext, width, height, has_alpha, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [blob.hash, blob.bytes, e.format.mimeType, e.format.fileExtension,
                                 e.width, e.height, e.hasAlpha, date])
            if let f = item.facts { try Self.recordFacts(f, blob: blob.hash, in: db) }

            let generationID = "gen_" + ULID.make(at: date)
            let info = String(decoding: try JSONEncoder.imageServer.encode(output.generation), as: UTF8.self)
            try db.execute(sql: """
                INSERT INTO generation(id, job_id, capability, model_id, package_id, license_class, info_json, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [generationID, runID, output.generation.capability.rawValue,
                                 output.generation.model.rawValue, output.generation.packageID,
                                 license.licenseClass.rawValue, info, date])

            let assetID = AssetID.make(at: date)
            try db.execute(sql: """
                INSERT INTO asset(id, blob_hash, kind, name, mime, width, height, bytes, source, job_id,
                    generation_id, ordinal, license_class, license_json, rights_class, rights_holder,
                    rights_expires_at, ai_use, rights_json, created_at, updated_at)
                VALUES (?, ?, ?, NULL, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [assetID.rawValue, blob.hash, output.kind.rawValue, e.format.mimeType, e.width,
                                 e.height, blob.bytes, (inputs.isEmpty ? AssetSource.generated : .derived).rawValue,
                                 runID, generationID, ordinal, licenseClass.rawValue, licenseJSON,
                                 rights.rightsClass.rawValue, rights.holder, rights.expiresAt, rights.aiUse.rawValue,
                                 rightsJSON, date, date])
            if let filing {
                try Self.setMembership(asset: assetID.rawValue, project: filing.projectID, home: true,
                                       status: filing.status, role: filing.role, origin: tagOrigin, in: db)
            }
            for tag in tags {
                // A bad tag on a finished run is dropped, not a reason to lose the outputs.
                try? Self.attach(tag: tag, to: assetID.rawValue, origin: tagOrigin, in: db)
            }
            assetIDs.append(assetID)
        }
        return assetIDs
    }

    // MARK: - Reads

    public func asset(_ id: AssetID) throws -> AssetInfo? {
        try database.pool.read { db in try Self.info(id.rawValue, in: db) }
    }

    /// The file behind an asset, for ranged serving.
    public func content(_ id: AssetID) throws -> (url: URL, mime: String, hash: String, bytes: Int64)? {
        try database.pool.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT b.hash, b.ext, b.mime, b.bytes FROM asset a JOIN blob b ON b.hash = a.blob_hash
                WHERE a.id = ? AND a.trashed_at IS NULL
                """, arguments: [id.rawValue]) else { return nil }
            let hash: String = row["hash"]
            let ext: String = row["ext"]
            return (blobs.url(forHash: hash, ext: ext), row["mime"], hash, row["bytes"])
        }
    }

    public func thumbnail(_ id: AssetID, size: Int) throws -> (url: URL, mime: String)? {
        guard let content = try content(id) else { return nil }
        return try thumbnails.thumbnail(forBlobAt: content.url, hash: content.hash, size: size)
    }

    public func count() throws -> Int {
        try database.pool.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset WHERE trashed_at IS NULL") ?? 0 }
    }

    // MARK: - Row mapping

    static func info(_ id: String, in db: Database) throws -> AssetInfo? {
        guard let row = try Row.fetchOne(db, sql: """
            SELECT a.*, g.info_json, c.slug AS company_slug FROM asset a
            LEFT JOIN generation g ON g.id = a.generation_id
            LEFT JOIN company c ON c.id = a.company_id
            WHERE a.id = ? AND a.trashed_at IS NULL
            """, arguments: [id]) else { return nil }
        return try info(from: row, in: db)
    }

    static func info(from row: Row, in db: Database) throws -> AssetInfo {
        let id: String = row["id"]
        let license: LicenseStamp? = try (row["license_json"] as String?).map {
            try JSONDecoder.imageServer.decode(LicenseStamp.self, from: Data($0.utf8))
        }
        let generation: GenerationInfo? = try (row["info_json"] as String?).map {
            try JSONDecoder.imageServer.decode(GenerationInfo.self, from: Data($0.utf8))
        }
        let rightsDetails: JSONObject? = (row["rights_json"] as String?).flatMap {
            try? JSONDecoder.imageServer.decode(JSONObject.self, from: Data($0.utf8))
        }
        let rights = AssetRights(rightsClass: RightsClass(rawValue: row["rights_class"] ?? "unknown") ?? .unknown,
                                 holder: row["rights_holder"], expiresAt: row["rights_expires_at"],
                                 aiUse: AIUse(rawValue: row["ai_use"] ?? "unknown") ?? .unknown, details: rightsDetails)

        let tagRows = try Row.fetchAll(db, sql: """
            SELECT t.name, at.origin FROM asset_tag at JOIN tag t ON t.id = at.tag_id WHERE at.asset_id = ? ORDER BY t.name
            """, arguments: [id])
        let projects = try Row.fetchAll(db, sql: """
            SELECT pa.project_id, pa.is_home, pa.status, pa.role, p.slug, p.name, c.slug AS company_slug
            FROM project_asset pa JOIN project p ON p.id = pa.project_id LEFT JOIN company c ON c.id = p.company_id
            WHERE pa.asset_id = ? ORDER BY pa.is_home DESC, p.name
            """, arguments: [id]).map { r in
            ProjectMembership(projectID: r["project_id"], slug: r["slug"], name: r["name"], companySlug: r["company_slug"],
                              isHome: r["is_home"], status: (r["status"] as String?).flatMap(ProjectStatus.init(rawValue:)),
                              role: r["role"])
        }
        let palette = try Row.fetchAll(db, sql: "SELECT hex, weight FROM blob_color WHERE blob_hash = ? ORDER BY rank",
                                       arguments: [row["blob_hash"] as String]).map {
            PaletteColor(hex: $0["hex"], weight: $0["weight"])
        }

        var info = AssetInfo(
            id: AssetID(rawValue: id), kind: AssetKind(rawValue: row["kind"]) ?? .image, name: row["name"],
            originalFilename: row["original_filename"], caption: row["caption"], altText: row["alt_text"],
            notes: row["notes"], creator: row["creator"], creditLine: row["credit_line"], copyright: row["copyright"],
            sourceDetail: row["source_detail"], mimeType: row["mime"], width: row["width"], height: row["height"],
            orientation: row["orientation"], bytes: row["bytes"], contentHash: row["blob_hash"],
            source: AssetSource(rawValue: row["source"]) ?? .generated, license: license,
            licenseClass: LicenseClass(rawValue: row["license_class"] ?? "permissive") ?? .permissive, rights: rights,
            companyID: row["company_id"], companySlug: row["company_slug"], projects: projects, generation: generation,
            tags: tagRows.filter { ($0["origin"] as String) != TagOrigin.auto.rawValue }.map { $0["name"] },
            autoTags: tagRows.filter { ($0["origin"] as String) == TagOrigin.auto.rawValue }.map { $0["name"] },
            palette: palette, revision: row["revision"] ?? 1, createdAt: row["created_at"], updatedAt: row["updated_at"])
        info.description = try latestDescription(id, in: db)
        return info
    }

    /// Computes facts (perceptual hash, palette, metadata) for up to `batch` blobs stored before the current
    /// `ImageFacts.version` — v1 blobs, or after the fact computation changes. Returns how many it processed;
    /// call until 0. Unreadable files are marked so they are not retried every launch.
    @discardableResult
    public func backfillFacts(batch: Int = 50) throws -> Int {
        let pending = try database.pool.read { db in
            try Row.fetchAll(db, sql: "SELECT hash, ext FROM blob WHERE facts_version < ? LIMIT ?",
                             arguments: [ImageFacts.version, batch]).map { ($0["hash"] as String, $0["ext"] as String) }
        }
        for (hash, ext) in pending {
            let facts = (try? Data(contentsOf: blobs.url(forHash: hash, ext: ext))).flatMap { try? ImageFacts.compute($0) }
            try database.pool.write { db in
                if let facts {
                    try Self.recordFacts(facts, blob: hash, in: db)
                } else {
                    try db.execute(sql: "UPDATE blob SET facts_version = ? WHERE hash = ?", arguments: [ImageFacts.version, hash])
                }
            }
        }
        return pending.count
    }

    static func recordFacts(_ facts: ImageFacts, blob hash: String, in db: Database) throws {
        let current = try Int.fetchOne(db, sql: "SELECT facts_version FROM blob WHERE hash = ?", arguments: [hash]) ?? 0
        guard current < ImageFacts.version else { return }
        let meta = facts.metadataJSON
        try db.execute(sql: """
            UPDATE blob SET phash = ?, meta_json = ?, has_alpha = ?, facts_version = ? WHERE hash = ?
            """, arguments: [facts.phash, meta, facts.hasAlpha, ImageFacts.version, hash])
        try db.execute(sql: "DELETE FROM blob_color WHERE blob_hash = ?", arguments: [hash])
        for (rank, c) in facts.palette.enumerated() {
            try db.execute(sql: """
                INSERT INTO blob_color(blob_hash, rank, hex, l, a, b, weight, bucket) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [hash, rank, c.hex, c.l, c.a, c.b, c.weight, c.bucket])
        }
    }
}
