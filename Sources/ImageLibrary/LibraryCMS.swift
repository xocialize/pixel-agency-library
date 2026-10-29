import Foundation
import GRDB
import ImageServerAPI

// CMS operations on the library: companies, projects and membership, tags, metadata edits, uploads, and search with
// facet counts (Docs/CMS-ROADMAP.md, L1).

extension AssetLibrary {
    // MARK: - Companies

    public func companies(includeArchived: Bool = false) throws -> [CompanyInfo] {
        try database.pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT c.*, (SELECT count(*) FROM project p WHERE p.company_id = c.id AND p.archived_at IS NULL) AS projects,
                    (SELECT count(*) FROM asset a WHERE a.company_id = c.id AND a.trashed_at IS NULL) AS assets
                FROM company c \(includeArchived ? "" : "WHERE c.archived_at IS NULL") ORDER BY c.name COLLATE NOCASE
                """).map(Self.company(from:))
        }
    }

    public func company(_ ref: String) throws -> CompanyInfo? {
        try database.pool.read { db in
            guard let id = try Self.resolveCompanyID(ref, in: db) else { return nil }
            return try Row.fetchOne(db, sql: """
                SELECT c.*, (SELECT count(*) FROM project p WHERE p.company_id = c.id AND p.archived_at IS NULL) AS projects,
                    (SELECT count(*) FROM asset a WHERE a.company_id = c.id AND a.trashed_at IS NULL) AS assets
                FROM company c WHERE c.id = ?
                """, arguments: [id]).map(Self.company(from:))
        }
    }

    public func createCompany(name: String, slug: String? = nil, notes: String? = nil) throws -> CompanyInfo {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw APIError.badRequest("missing_parameter", "name is required.", param: "name") }
        let slug = Self.slugify(slug ?? name)
        let id = "cmp_" + ULID.make()
        try database.pool.write { db in
            if try Self.resolveCompanyID(slug, in: db) != nil {
                throw APIError.conflict("slug_taken", "A company with slug '\(slug)' already exists.")
            }
            let now = Date()
            try db.execute(sql: "INSERT INTO company(id, slug, name, notes, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)",
                           arguments: [id, slug, name, notes, now, now])
        }
        return try company(id)!
    }

    public func updateCompany(_ ref: String, name: String?, slug: String?, notes: String?, archived: Bool?) throws -> CompanyInfo {
        let id: String = try database.pool.write { db in
            guard let id = try Self.resolveCompanyID(ref, in: db, includeArchived: true) else {
                throw APIError.notFound("No company '\(ref)'.")
            }
            var sets = ["updated_at = ?"]
            var args: [(any DatabaseValueConvertible)?] = [Date()]
            if let name { sets.append("name = ?"); args.append(name) }
            if let slug { sets.append("slug = ?"); args.append(Self.slugify(slug)) }
            if let notes { sets.append("notes = ?"); args.append(notes.isEmpty ? nil : notes) }
            if let archived { sets.append("archived_at = ?"); args.append(archived ? Date() : nil) }
            args.append(id)
            try db.execute(sql: "UPDATE company SET \(sets.joined(separator: ", ")) WHERE id = ?",
                           arguments: StatementArguments(args))
            return id
        }
        return try company(id)!
    }

    // MARK: - Projects

    public func projects(company: String? = nil, includeArchived: Bool = false) throws -> [ProjectInfo] {
        try database.pool.read { db in
            var clauses: [String] = []
            var args: [any DatabaseValueConvertible] = []
            if !includeArchived { clauses.append("p.archived_at IS NULL") }
            if let company {
                guard let cid = try Self.resolveCompanyID(company, in: db) else { return [] }
                clauses.append("p.company_id = ?")
                args.append(cid)
            }
            let whereSQL = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
            return try Row.fetchAll(db, sql: Self.projectSelect + " \(whereSQL) ORDER BY c.name COLLATE NOCASE, p.name COLLATE NOCASE",
                                    arguments: StatementArguments(args)).map(Self.project(from:))
        }
    }

    public func project(_ ref: String) throws -> ProjectInfo? {
        try database.pool.read { db in
            guard let id = try Self.resolveProjectID(ref, in: db, includeArchived: true) else { return nil }
            return try Row.fetchOne(db, sql: Self.projectSelect + " WHERE p.id = ?", arguments: [id]).map(Self.project(from:))
        }
    }

    /// Creates a project. `company` may name an existing company (id or slug) or, with `createCompany`, a new one.
    public func createProject(name: String, slug: String? = nil, company: String? = nil, description: String? = nil,
                              createCompany: Bool = false) throws -> ProjectInfo {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw APIError.badRequest("missing_parameter", "name is required.", param: "name") }
        let slug = Self.slugify(slug ?? name)
        let id = "prj_" + ULID.make()
        try database.pool.write { db in
            var companyID: String?
            if let company {
                if let existing = try Self.resolveCompanyID(company, in: db) {
                    companyID = existing
                } else if createCompany {
                    let cid = "cmp_" + ULID.make()
                    let now = Date()
                    try db.execute(sql: "INSERT INTO company(id, slug, name, created_at, updated_at) VALUES (?, ?, ?, ?, ?)",
                                   arguments: [cid, Self.slugify(company), company, now, now])
                    companyID = cid
                } else {
                    throw APIError.unprocessable("unknown_company", "No company '\(company)'.", param: "company")
                }
            }
            let taken = try Bool.fetchOne(db, sql: """
                SELECT EXISTS(SELECT 1 FROM project WHERE slug = ? AND company_id IS ?)
                """, arguments: [slug, companyID]) ?? false
            if taken { throw APIError.conflict("slug_taken", "A project with slug '\(slug)' already exists here.") }
            let now = Date()
            try db.execute(sql: """
                INSERT INTO project(id, company_id, slug, name, description, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?)
                """, arguments: [id, companyID, slug, name, description, now, now])
        }
        return try project(id)!
    }

    public func updateProject(_ ref: String, name: String?, slug: String?, description: String?,
                              archived: Bool?) throws -> ProjectInfo {
        let id: String = try database.pool.write { db in
            guard let id = try Self.resolveProjectID(ref, in: db, includeArchived: true) else {
                throw APIError.notFound("No project '\(ref)'.")
            }
            var sets = ["updated_at = ?"]
            var args: [(any DatabaseValueConvertible)?] = [Date()]
            if let name { sets.append("name = ?"); args.append(name) }
            if let slug { sets.append("slug = ?"); args.append(Self.slugify(slug)) }
            if let description { sets.append("description = ?"); args.append(description.isEmpty ? nil : description) }
            if let archived { sets.append("archived_at = ?"); args.append(archived ? Date() : nil) }
            args.append(id)
            try db.execute(sql: "UPDATE project SET \(sets.joined(separator: ", ")) WHERE id = ?",
                           arguments: StatementArguments(args))
            return id
        }
        return try project(id)!
    }

    /// Resolves a project reference (id, slug, or `company/slug`) to its id, or throws 422.
    public func requireProjectID(_ ref: String) throws -> String {
        try database.pool.read { db in
            guard let id = try Self.resolveProjectID(ref, in: db) else {
                throw APIError.unprocessable("unknown_project", "No project '\(ref)'.", param: "project")
            }
            return id
        }
    }

    /// Adds assets to a project. `home` moves each asset's home there (its company follows).
    public func addToProject(_ assets: [AssetID], project: String, home: Bool = false, status: ProjectStatus? = nil,
                             role: String? = nil, origin: TagOrigin) throws {
        try database.pool.write { db in
            guard let pid = try Self.resolveProjectID(project, in: db) else {
                throw APIError.unprocessable("unknown_project", "No project '\(project)'.", param: "project")
            }
            for asset in assets {
                try Self.requireAsset(asset.rawValue, in: db)
                try Self.setMembership(asset: asset.rawValue, project: pid, home: home, status: status, role: role,
                                       origin: origin, in: db)
                try Self.touch(asset.rawValue, in: db)
            }
        }
    }

    public func removeFromProject(_ assets: [AssetID], project: String) throws {
        try database.pool.write { db in
            guard let pid = try Self.resolveProjectID(project, in: db, includeArchived: true) else {
                throw APIError.notFound("No project '\(project)'.")
            }
            for asset in assets {
                try db.execute(sql: "DELETE FROM project_asset WHERE project_id = ? AND asset_id = ?",
                               arguments: [pid, asset.rawValue])
                try Self.touch(asset.rawValue, in: db)
            }
        }
    }

    // MARK: - Tags

    public func tags(namespace: String? = nil, prefix: String? = nil, limit: Int = 200) throws -> [TagInfo] {
        try database.pool.read { db in
            var clauses = ["t.merged_into_id IS NULL"]
            var args: [any DatabaseValueConvertible] = []
            if let namespace { clauses.append("t.namespace = ?"); args.append(namespace.lowercased()) }
            if let prefix, !prefix.isEmpty { clauses.append("t.name LIKE ? ESCAPE '\\'"); args.append(Self.likeEscape(prefix.lowercased()) + "%") }
            args.append(max(1, min(limit, 1000)))
            return try Row.fetchAll(db, sql: """
                SELECT t.id, t.name, t.namespace,
                    (SELECT count(*) FROM asset_tag at JOIN asset a ON a.id = at.asset_id
                     WHERE at.tag_id = t.id AND a.trashed_at IS NULL) AS n
                FROM tag t WHERE \(clauses.joined(separator: " AND ")) ORDER BY n DESC, t.name LIMIT ?
                """, arguments: StatementArguments(args)).map {
                TagInfo(id: $0["id"], name: $0["name"], namespace: $0["namespace"], count: $0["n"], mergedInto: nil)
            }
        }
    }

    /// Adds and removes tags on many assets. Returns the normalized tags actually added.
    @discardableResult
    public func tagAssets(_ assets: [AssetID], add: [String], remove: [String], origin: TagOrigin) throws -> [String] {
        try database.pool.write { db in
            var added: [String] = []
            for asset in assets {
                try Self.requireAsset(asset.rawValue, in: db)
                for tag in add { added.append(try Self.attach(tag: tag, to: asset.rawValue, origin: origin, in: db)) }
                for tag in remove { try Self.detach(tag: tag, from: asset.rawValue, in: db) }
                try Self.touch(asset.rawValue, in: db)
            }
            return Array(Set(added)).sorted()
        }
    }

    /// Renames a tag (and so every asset carrying it — the search documents follow by trigger).
    public func renameTag(_ id: Int64, to newName: String) throws -> TagInfo {
        let name = try Self.normalizeTag(newName)
        try database.pool.write { db in
            if let existing = try Int64.fetchOne(db, sql: "SELECT id FROM tag WHERE name = ?", arguments: [name]), existing != id {
                throw APIError.conflict("tag_exists", "'\(name)' already exists — merge instead.")
            }
            try db.execute(sql: "UPDATE tag SET name = ?, namespace = ? WHERE id = ?",
                           arguments: [name, Self.namespace(of: name), id])
        }
        return try tags(prefix: name, limit: 50).first { $0.id == id } ?? TagInfo(id: id, name: name, namespace: Self.namespace(of: name), count: 0, mergedInto: nil)
    }

    /// Merges `source` into `target`: assignments move, and `source` stays as an alias so later writes of the old
    /// name land on the target.
    public func mergeTag(_ source: Int64, into target: Int64) throws {
        guard source != target else { return }
        try database.pool.write { db in
            try db.execute(sql: """
                INSERT OR IGNORE INTO asset_tag(asset_id, tag_id, origin, created_at, confidence, source_ref)
                SELECT asset_id, ?, origin, created_at, confidence, source_ref FROM asset_tag WHERE tag_id = ?
                """, arguments: [target, source])
            try db.execute(sql: "DELETE FROM asset_tag WHERE tag_id = ?", arguments: [source])
            try db.execute(sql: "UPDATE tag SET merged_into_id = ? WHERE id = ? OR merged_into_id = ?",
                           arguments: [target, source, source])
        }
    }

    public func deleteTag(_ id: Int64) throws {
        try database.pool.write { db in
            try db.execute(sql: "DELETE FROM asset_tag WHERE tag_id = ?", arguments: [id])
            try db.execute(sql: "UPDATE tag SET merged_into_id = NULL WHERE merged_into_id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM tag WHERE id = ?", arguments: [id])
        }
    }

    // MARK: - Edits

    public func patch(_ id: AssetID, _ patch: AssetPatch, origin: TagOrigin) throws -> AssetInfo {
        try database.pool.write { db in
            guard let current = try Int.fetchOne(db, sql: "SELECT revision FROM asset WHERE id = ? AND trashed_at IS NULL",
                                                 arguments: [id.rawValue]) else {
                throw APIError.notFound("No asset \(id).")
            }
            if let expected = patch.revision, expected != current {
                throw APIError.conflict("revision_conflict", "Asset \(id) is at revision \(current), not \(expected).")
            }
            var sets: [String] = []
            var args: [(any DatabaseValueConvertible)?] = []
            func text(_ column: String, _ value: String?) {
                guard let value else { return }
                sets.append("\(column) = ?")
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                args.append(trimmed.isEmpty ? nil : trimmed)
            }
            text("name", patch.name)
            text("caption", patch.caption)
            text("alt_text", patch.altText)
            text("notes", patch.notes)
            text("creator", patch.creator)
            text("credit_line", patch.creditLine)
            text("copyright", patch.copyright)
            text("source_detail", patch.sourceDetail)
            if let rights = patch.rights {
                sets += ["rights_class = ?", "rights_holder = ?", "rights_expires_at = ?", "ai_use = ?", "rights_json = ?"]
                args += [rights.rightsClass.rawValue, rights.holder, rights.expiresAt, rights.aiUse.rawValue,
                         try rights.details.map { String(decoding: try JSONEncoder.imageServer.encode($0), as: UTF8.self) }]
            }
            if !sets.isEmpty {
                args.append(id.rawValue)
                try db.execute(sql: "UPDATE asset SET \(sets.joined(separator: ", ")) WHERE id = ?",
                               arguments: StatementArguments(args))
            }
            if let tags = patch.tags {
                for tag in tags.add { try Self.attach(tag: tag, to: id.rawValue, origin: origin, in: db) }
                for tag in tags.remove { try Self.detach(tag: tag, from: id.rawValue, in: db) }
            }
            if let projects = patch.projects {
                for ref in projects.remove {
                    guard let pid = try Self.resolveProjectID(ref, in: db, includeArchived: true) else { continue }
                    try db.execute(sql: "DELETE FROM project_asset WHERE project_id = ? AND asset_id = ?",
                                   arguments: [pid, id.rawValue])
                }
                for ref in projects.add {
                    guard let pid = try Self.resolveProjectID(ref, in: db) else {
                        throw APIError.unprocessable("unknown_project", "No project '\(ref)'.", param: "projects")
                    }
                    try Self.setMembership(asset: id.rawValue, project: pid, home: false,
                                           status: projects.home == nil ? projects.status : nil,
                                           role: projects.home == nil ? projects.role : nil, origin: origin, in: db)
                }
                if let ref = projects.home {
                    guard let pid = try Self.resolveProjectID(ref, in: db) else {
                        throw APIError.unprocessable("unknown_project", "No project '\(ref)'.", param: "projects")
                    }
                    try Self.setMembership(asset: id.rawValue, project: pid, home: true, status: projects.status,
                                           role: projects.role, origin: origin, in: db)
                }
            }
            try Self.touch(id.rawValue, in: db)
            guard let info = try Self.info(id.rawValue, in: db) else { throw APIError.notFound("No asset \(id).") }
            return info
        }
    }

    /// Moves an asset to the trash (kept 30 days; GC deletes it and, if unreferenced, its blob).
    public func trash(_ id: AssetID) throws {
        try database.pool.write { db in
            try db.execute(sql: "UPDATE asset SET trashed_at = ? WHERE id = ? AND trashed_at IS NULL",
                           arguments: [Date(), id.rawValue])
        }
    }

    public func restore(_ id: AssetID) throws {
        try database.pool.write { db in
            try db.execute(sql: "UPDATE asset SET trashed_at = NULL WHERE id = ?", arguments: [id.rawValue])
        }
    }

    // MARK: - Uploads

    /// Stores an uploaded image as a first-class asset. Embedded IPTC/EXIF fills gaps (never overriding `metadata`);
    /// identical bytes already filed in the same home project return the existing asset.
    public func importUpload(_ data: Data, metadata: UploadMetadata = UploadMetadata(), origin: TagOrigin,
                             uploadedBy: ClientID? = nil, ephemeral: Bool = false) throws -> UploadResult {
        guard !data.isEmpty else { throw APIError.badRequest("missing_parameter", "The upload is empty.") }
        let facts = try ImageFacts.compute(data, filename: metadata.originalFilename)
        let blob = try blobs.store(data, fileExtension: facts.fileExtension)
        let now = Date()

        return try database.pool.write { db in
            // A sweep may have collected identical bytes between `store` and this transaction: store them again.
            if !FileManager.default.fileExists(atPath: blob.url.path) { _ = try blobs.store(data, fileExtension: facts.fileExtension) }
            // An inline job input whose bytes are already in the library reuses that asset — no clutter, and its
            // rights travel with it.
            if ephemeral, let existing = try String.fetchOne(db, sql: """
                SELECT id FROM asset WHERE blob_hash = ? AND trashed_at IS NULL ORDER BY retention = 'keep' DESC, id LIMIT 1
                """, arguments: [blob.hash]), let info = try Self.info(existing, in: db) {
                return UploadResult(asset: info, deduplicated: true, duplicates: [], nearDuplicates: [],
                                    importedFields: [], importedTags: [])
            }
            let projectID = try metadata.project.map { ref -> String in
                guard let id = try Self.resolveProjectID(ref, in: db) else {
                    throw APIError.unprocessable("unknown_project", "No project '\(ref)'.", param: "project")
                }
                return id
            }
            var companyID = try projectID.flatMap {
                try String.fetchOne(db, sql: "SELECT company_id FROM project WHERE id = ?", arguments: [$0])
            }
            if companyID == nil, let ref = metadata.company {
                guard let id = try Self.resolveCompanyID(ref, in: db) else {
                    throw APIError.unprocessable("unknown_company", "No company '\(ref)'.", param: "company")
                }
                companyID = id
            }

            try db.execute(sql: """
                INSERT OR IGNORE INTO blob(hash, bytes, mime, ext, width, height, has_alpha, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [blob.hash, blob.bytes, facts.mime, facts.fileExtension, facts.width, facts.height,
                                 facts.hasAlpha, now])
            try Self.recordFacts(facts, blob: blob.hash, in: db)

            let iptc = facts.iptc
            var importedFields: [String] = []
            func pick(_ given: String?, _ imported: String?, _ field: String) -> String? {
                if let given = given?.trimmingCharacters(in: .whitespacesAndNewlines), !given.isEmpty { return given }
                if let imported { importedFields.append(field); return imported }
                return nil
            }
            let filenameStem = metadata.originalFilename.map { ($0 as NSString).deletingPathExtension }
            let name = pick(metadata.name, iptc.objectName, "name") ?? filenameStem
            let caption = pick(metadata.caption, iptc.caption, "caption")
            let creator = pick(metadata.creator, iptc.byline, "creator")
            let credit = pick(metadata.creditLine, iptc.credit, "credit_line")
            let copyright = pick(metadata.copyright, iptc.copyright, "copyright")
            var rights = metadata.rights ?? AssetRights()
            if metadata.rights == nil, let terms = iptc.usageTerms {
                rights.details = ["usage_terms": .string(terms), "rights_source": "import"]
                importedFields.append("rights.usage_terms")
            }

            // Same bytes, same home (or both in the Inbox): return the existing asset, filling empty fields only.
            let existing = try String.fetchOne(db, sql: """
                SELECT a.id FROM asset a
                WHERE a.blob_hash = ? AND a.trashed_at IS NULL AND a.source = 'uploaded' AND
                    (SELECT pa.project_id FROM project_asset pa WHERE pa.asset_id = a.id AND pa.is_home = 1) IS ?
                ORDER BY a.id LIMIT 1
                """, arguments: [blob.hash, projectID])
            if let existing {
                try db.execute(sql: """
                    UPDATE asset SET name = coalesce(name, ?), caption = coalesce(caption, ?),
                        alt_text = coalesce(alt_text, ?), notes = coalesce(notes, ?), creator = coalesce(creator, ?),
                        credit_line = coalesce(credit_line, ?), copyright = coalesce(copyright, ?),
                        original_filename = coalesce(original_filename, ?), source_detail = coalesce(source_detail, ?)
                    WHERE id = ?
                    """, arguments: [name, caption, metadata.altText, metadata.notes, creator, credit, copyright,
                                     metadata.originalFilename, metadata.sourceDetail, existing])
                for tag in metadata.tags { try Self.attach(tag: tag, to: existing, origin: origin, in: db) }
                guard let info = try Self.info(existing, in: db) else { throw APIError.notFound("Asset vanished.") }
                return UploadResult(asset: info, deduplicated: true,
                                    duplicates: try Self.duplicates(of: existing, hash: blob.hash, in: db),
                                    nearDuplicates: try Self.nearDuplicates(of: existing, hash: blob.hash,
                                                                            phash: facts.phash, in: db),
                                    importedFields: [], importedTags: [])
            }

            let id = AssetID.make(at: now).rawValue
            let rightsJSON = try rights.details.map { String(decoding: try JSONEncoder.imageServer.encode($0), as: UTF8.self) }
            try db.execute(sql: """
                INSERT INTO asset(id, blob_hash, kind, name, original_filename, caption, alt_text, notes, creator,
                    credit_line, copyright, source_detail, uploaded_by, company_id, mime, width, height, bytes, source,
                    ordinal, license_class, rights_class, rights_holder, rights_expires_at, ai_use, rights_json,
                    retention, expires_at, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'uploaded', 0, 'permissive', ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [id, blob.hash, facts.kind.rawValue, name, metadata.originalFilename, caption,
                                 metadata.altText, metadata.notes, creator, credit, copyright, metadata.sourceDetail,
                                 uploadedBy?.rawValue, companyID, facts.mime, facts.width, facts.height, blob.bytes,
                                 rights.rightsClass.rawValue, rights.holder, rights.expiresAt, rights.aiUse.rawValue,
                                 rightsJSON, ephemeral ? "ephemeral" : "keep",
                                 ephemeral ? now.addingTimeInterval(24 * 3600) : nil, now, now])
            if let projectID {
                try Self.setMembership(asset: id, project: projectID, home: true, status: metadata.status,
                                       role: metadata.role, origin: origin, in: db)
            }
            for tag in metadata.tags { try Self.attach(tag: tag, to: id, origin: origin, in: db) }
            var importedTags: [String] = []
            for keyword in iptc.keywords {
                // Imported keywords that would collide with structure (reserved namespaces) or a controlled
                // vocabulary are skipped rather than failing the upload.
                if let tag = try? Self.attach(tag: keyword, to: id, origin: .import, in: db) { importedTags.append(tag) }
            }
            guard let info = try Self.info(id, in: db) else { throw APIError.notFound("Asset vanished after insert.") }
            return UploadResult(asset: info, deduplicated: false,
                                duplicates: try Self.duplicates(of: id, hash: blob.hash, in: db),
                                nearDuplicates: try Self.nearDuplicates(of: id, hash: blob.hash, phash: facts.phash, in: db),
                                importedFields: importedFields, importedTags: importedTags)
        }
    }

    // MARK: - Job inputs

    /// What a set of input assets passes on to anything derived from them.
    public struct InputSummary: Sendable, Equatable {
        public var licenseClass: LicenseClass
        public var rights: AssetRights
    }

    /// Checks job inputs exist and may be used with AI, and returns what derived outputs inherit: the most restrictive
    /// licence class and rights class, the earliest rights expiry, every holder, and the strictest AI-use.
    public func inputSummary(_ ids: [AssetID]) throws -> InputSummary {
        try database.pool.read { db in
            var licenseClasses: [LicenseClass] = []
            var rightsClasses: [RightsClass] = []
            var holders: [String] = []
            var expiry: Date?
            var aiUse: AIUse = .allowed
            for id in ids {
                guard let row = try Row.fetchOne(db, sql: """
                    SELECT license_class, rights_class, rights_holder, rights_expires_at, ai_use, name, original_filename
                    FROM asset WHERE id = ? AND trashed_at IS NULL
                    """, arguments: [id.rawValue]) else {
                    throw APIError.unprocessable("input_unresolvable", "No asset \(id).", param: "inputs")
                }
                let use = AIUse(rawValue: row["ai_use"] ?? "unknown") ?? .unknown
                if use == .forbidden {
                    let label: String = row["name"] ?? row["original_filename"] ?? id.rawValue
                    throw APIError.unprocessable("input_ai_use_forbidden",
                                                 "'\(label)' (\(id)) is marked ai_use: forbidden and cannot be used as a model input.",
                                                 param: "inputs")
                }
                if use == .unknown { aiUse = .unknown }
                licenseClasses.append(LicenseClass(rawValue: row["license_class"] ?? "permissive") ?? .permissive)
                rightsClasses.append(RightsClass(rawValue: row["rights_class"] ?? "unknown") ?? .unknown)
                if let holder: String = row["rights_holder"], !holders.contains(holder) { holders.append(holder) }
                if let date: Date = row["rights_expires_at"] { expiry = min(expiry ?? date, date) }
            }
            var rights = AssetRights(rightsClass: rightsClasses.max() ?? .owned,
                                     holder: holders.isEmpty ? nil : holders.joined(separator: "; "),
                                     expiresAt: expiry, aiUse: ids.isEmpty ? .allowed : aiUse)
            if !ids.isEmpty { rights.details = ["derived_from": .array(ids.map { .string($0.rawValue) })] }
            return InputSummary(licenseClass: LicenseClass.mostRestrictive(licenseClasses), rights: rights)
        }
    }

    // MARK: - Internals: resolution, membership, tags

    static let projectSelect = """
        SELECT p.*, c.slug AS company_slug, c.name AS company_name,
            (SELECT count(*) FROM project_asset pa JOIN asset a ON a.id = pa.asset_id
             WHERE pa.project_id = p.id AND a.trashed_at IS NULL) AS assets
        FROM project p LEFT JOIN company c ON c.id = p.company_id
        """

    static func company(from row: Row) -> CompanyInfo {
        CompanyInfo(id: row["id"], slug: row["slug"], name: row["name"], notes: row["notes"],
                    defaultBrandKitID: row["default_brand_kit_id"], projectCount: row["projects"],
                    assetCount: row["assets"], createdAt: row["created_at"], archivedAt: row["archived_at"])
    }

    static func project(from row: Row) -> ProjectInfo {
        ProjectInfo(id: row["id"], slug: row["slug"], name: row["name"], description: row["description"],
                    companyID: row["company_id"], companySlug: row["company_slug"], companyName: row["company_name"],
                    brandKitID: row["brand_kit_id"], assetCount: row["assets"], createdAt: row["created_at"],
                    archivedAt: row["archived_at"])
    }

    static func resolveCompanyID(_ ref: String, in db: Database, includeArchived: Bool = false) throws -> String? {
        let archived = includeArchived ? "" : " AND archived_at IS NULL"
        return try String.fetchOne(db, sql: "SELECT id FROM company WHERE (id = ? OR slug = ?)\(archived) LIMIT 1",
                                   arguments: [ref, slugify(ref)])
    }

    /// `prj_…`, `slug` (unique among company-less projects, else any unique match), or `company/slug`.
    static func resolveProjectID(_ ref: String, in db: Database, includeArchived: Bool = false) throws -> String? {
        let archived = includeArchived ? "" : " AND p.archived_at IS NULL"
        if ref.hasPrefix("prj_") {
            return try String.fetchOne(db, sql: "SELECT id FROM project p WHERE id = ?\(archived)", arguments: [ref])
        }
        let parts = ref.split(separator: "/", maxSplits: 1).map(String.init)
        if parts.count == 2 {
            guard let cid = try resolveCompanyID(parts[0], in: db, includeArchived: true) else { return nil }
            return try String.fetchOne(db, sql: "SELECT id FROM project p WHERE company_id = ? AND slug = ?\(archived)",
                                       arguments: [cid, slugify(parts[1])])
        }
        let matches = try String.fetchAll(db, sql: "SELECT id FROM project p WHERE slug = ?\(archived) LIMIT 2",
                                          arguments: [slugify(ref)])
        return matches.count == 1 ? matches[0] : nil
    }

    static func requireAsset(_ id: String, in db: Database) throws {
        guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM asset WHERE id = ? AND trashed_at IS NULL)",
                                arguments: [id]) == true else { throw APIError.notFound("No asset \(id).") }
    }

    /// Adds (or updates) a membership. `home` moves the asset's single home here and sets its company.
    static func setMembership(asset: String, project: String, home: Bool, status: ProjectStatus?, role: String?,
                              origin: TagOrigin, in db: Database) throws {
        if home {
            try db.execute(sql: "UPDATE project_asset SET is_home = 0 WHERE asset_id = ? AND project_id <> ?",
                           arguments: [asset, project])
        }
        try db.execute(sql: """
            INSERT INTO project_asset(project_id, asset_id, is_home, status, role, added_at, added_origin)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(project_id, asset_id) DO UPDATE SET
                is_home = max(project_asset.is_home, excluded.is_home),
                status = coalesce(excluded.status, project_asset.status),
                role = coalesce(excluded.role, project_asset.role)
            """, arguments: [project, asset, home, status?.rawValue, role, Date(), origin.rawValue])
        if home {
            try db.execute(sql: "UPDATE asset SET company_id = (SELECT company_id FROM project WHERE id = ?) WHERE id = ?",
                           arguments: [project, asset])
        }
    }

    static func touch(_ asset: String, in db: Database) throws {
        try db.execute(sql: "UPDATE asset SET revision = revision + 1, updated_at = ? WHERE id = ?",
                       arguments: [Date(), asset])
    }

    /// Trim, collapse whitespace, Unicode-normalize, lowercase. Namespaced tags keep their `ns:value` shape.
    static func normalizeTag(_ raw: String) throws -> String {
        let collapsed = raw.precomposedStringWithCanonicalMapping
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
            .lowercased()
        var name = collapsed
        if let colon = name.firstIndex(of: ":") {
            let ns = name[..<colon].trimmingCharacters(in: .whitespaces)
            let value = name[name.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            name = value.isEmpty ? ns : "\(ns):\(value)"
        }
        guard !name.isEmpty, name.count <= 100 else {
            throw APIError.unprocessable("invalid_tag", "Tags must be 1–100 characters.", param: "tags")
        }
        return name
    }

    static func namespace(of name: String) -> String {
        guard let colon = name.firstIndex(of: ":") else { return "" }
        return String(name[..<colon])
    }

    /// Resolves (creating if needed) a tag id, following merge aliases. Reserved namespaces are structure, not tags.
    static func tagID(for raw: String, create: Bool, in db: Database) throws -> (id: Int64, name: String)? {
        let name = try normalizeTag(raw)
        let ns = namespace(of: name)
        if CMSSchema.reservedNamespaces.contains(ns) {
            throw APIError.unprocessable("reserved_namespace",
                                         "'\(ns):' is structure, not a tag — use the \(ns) field instead.", param: "tags")
        }
        if let row = try Row.fetchOne(db, sql: "SELECT id, merged_into_id FROM tag WHERE name = ?", arguments: [name]) {
            var id: Int64 = row["id"]
            var hops = 0
            while let target = try Int64.fetchOne(db, sql: "SELECT merged_into_id FROM tag WHERE id = ?", arguments: [id]),
                  hops < 8 {
                id = target
                hops += 1
            }
            let resolved = try String.fetchOne(db, sql: "SELECT name FROM tag WHERE id = ?", arguments: [id]) ?? name
            return (id, resolved)
        }
        guard create else { return nil }
        if !ns.isEmpty, let allowed = try String.fetchOne(db, sql: """
            SELECT allowed_json FROM tag_namespace WHERE name = ? AND policy = 'controlled'
            """, arguments: [ns]),
           let values = try? JSONDecoder().decode([String].self, from: Data(allowed.utf8)) {
            let value = String(name.dropFirst(ns.count + 1))
            guard values.contains(value) else {
                throw APIError.unprocessable("tag_not_allowed",
                                             "'\(ns):' allows only: \(values.map { "\(ns):\($0)" }.joined(separator: ", ")).",
                                             param: "tags")
            }
        }
        try db.execute(sql: "INSERT INTO tag(name, namespace, created_at) VALUES (?, ?, ?)", arguments: [name, ns, Date()])
        return (db.lastInsertedRowID, name)
    }

    /// Attaches a tag; returns the normalized (alias-resolved) name.
    @discardableResult
    static func attach(tag raw: String, to asset: String, origin: TagOrigin, confidence: Double? = nil,
                       sourceRef: String? = nil, in db: Database) throws -> String {
        guard let tag = try tagID(for: raw, create: true, in: db) else { return raw }
        try db.execute(sql: """
            INSERT OR IGNORE INTO asset_tag(asset_id, tag_id, origin, created_at, confidence, source_ref)
            VALUES (?, ?, ?, ?, ?, ?)
            """, arguments: [asset, tag.id, origin.rawValue, Date(), confidence, sourceRef])
        return tag.name
    }

    static func detach(tag raw: String, from asset: String, in db: Database) throws {
        guard let tag = try? tagID(for: raw, create: false, in: db) else { return }
        try db.execute(sql: "DELETE FROM asset_tag WHERE asset_id = ? AND tag_id = ?", arguments: [asset, tag.id])
    }

    static func duplicates(of asset: String, hash: String, in db: Database) throws -> [AssetID] {
        try String.fetchAll(db, sql: """
            SELECT id FROM asset WHERE blob_hash = ? AND id <> ? AND trashed_at IS NULL ORDER BY id LIMIT 20
            """, arguments: [hash, asset]).map(AssetID.init(rawValue:))
    }

    static func nearDuplicates(of asset: String, hash: String, phash: Int64?, in db: Database) throws -> [AssetID] {
        guard let phash else { return [] }
        return try String.fetchAll(db, sql: """
            SELECT a.id FROM asset a JOIN blob b ON b.hash = a.blob_hash
            WHERE b.phash IS NOT NULL AND b.hash <> ? AND a.trashed_at IS NULL AND hamming(b.phash, ?) <= 6
            ORDER BY hamming(b.phash, ?), a.id LIMIT 20
            """, arguments: [hash, phash, phash]).map(AssetID.init(rawValue:))
    }

    static func slugify(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .init(identifier: "en_US"))
        var out = ""
        var lastDash = false
        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII {
                out.unicodeScalars.append(scalar)
                lastDash = false
            } else if !lastDash && !out.isEmpty {
                out.append("-")
                lastDash = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? "untitled" : String(out.prefix(64))
    }

    static func likeEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }
}
