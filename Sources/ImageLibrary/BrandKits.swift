import Foundation
import GRDB
import ImageServerAPI

/// Brand kits: per-company, revisioned (every edit is a new immutable revision), referencing library assets by role.
/// `style.json` (marquee-brand-spec 1.1) imports map onto them 1:1 — company → company, style → kit, version → a
/// recorded source version.
extension AssetLibrary {
    // MARK: - Reads

    public func brandKits(company: String? = nil, includeArchived: Bool = false) throws -> [BrandKitInfo] {
        try database.pool.read { db in
            var clauses: [String] = []
            var args: [any DatabaseValueConvertible] = []
            if !includeArchived { clauses.append("k.archived_at IS NULL") }
            if let company {
                guard let cid = try Self.resolveCompanyID(company, in: db, includeArchived: true) else { return [] }
                clauses.append("k.company_id = ?")
                args.append(cid)
            }
            let whereSQL = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
            let ids = try String.fetchAll(db, sql: "SELECT k.id FROM brand_kit k \(whereSQL) ORDER BY k.name COLLATE NOCASE",
                                          arguments: StatementArguments(args))
            return try ids.compactMap { try Self.brandKit(id: $0, revision: nil, in: db) }
        }
    }

    /// `bk_…`, `company/slug`, or a unique `slug`, optionally suffixed `@revision`. Archived kits resolve only with
    /// `includeArchived` (an archived kit is never applied by name, but stays readable).
    public func brandKit(_ ref: String, revision: Int? = nil, includeArchived: Bool = false) throws -> BrandKitInfo? {
        try database.pool.read { db in
            let (base, pinned) = Self.splitRevision(ref)
            guard let id = try Self.resolveBrandKitID(base, in: db, includeArchived: includeArchived) else { return nil }
            return try Self.brandKit(id: id, revision: revision ?? pinned, in: db)
        }
    }

    public func brandKitRevisions(_ ref: String) throws -> [(revision: Int, note: String?, createdAt: Date)] {
        try database.pool.read { db in
            guard let id = try Self.resolveBrandKitID(Self.splitRevision(ref).0, in: db) else {
                throw APIError.notFound("No brand kit '\(ref)'.")
            }
            return try Row.fetchAll(db, sql: """
                SELECT revision, note, created_at FROM brand_kit_revision WHERE kit_id = ? ORDER BY revision DESC
                """, arguments: [id]).map { ($0["revision"], $0["note"], $0["created_at"]) }
        }
    }

    /// The kit that applies to work filed in `project`: the project's own, else its company's default.
    public func brandKit(forProject projectID: String) throws -> (kit: BrandKitInfo, resolvedBy: String)? {
        try database.pool.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT p.brand_kit_id, c.default_brand_kit_id FROM project p LEFT JOIN company c ON c.id = p.company_id
                WHERE p.id = ?
                """, arguments: [projectID]) else { return nil }
            if let own: String = row["brand_kit_id"], let kit = try Self.brandKit(id: own, revision: nil, in: db) {
                return (kit, "project")
            }
            if let fallback: String = row["default_brand_kit_id"], let kit = try Self.brandKit(id: fallback, revision: nil, in: db) {
                return (kit, "company")
            }
            return nil
        }
    }

    // MARK: - Writes

    /// Creates a kit and its revision 1. `company` may be created on the fly with `createCompany`.
    public func createBrandKit(company: String, name: String, slug: String? = nil, manifest: BrandManifest,
                               note: String? = nil, createCompany: Bool = false, by client: ClientID? = nil) throws -> BrandKitInfo {
        let kitSlug = Self.slugify(slug ?? name)
        let id = "bk_" + ULID.make()
        try database.pool.write { db in
            let companyID = try Self.companyID(for: company, create: createCompany, in: db)
            if try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM brand_kit WHERE company_id = ? AND slug = ?)",
                                 arguments: [companyID, kitSlug]) == true {
                throw APIError.conflict("slug_taken", "That company already has a brand kit '\(kitSlug)'.")
            }
            let now = Date()
            try db.execute(sql: """
                INSERT INTO brand_kit(id, company_id, slug, name, current_revision, created_at, updated_at)
                VALUES (?, ?, ?, ?, 0, ?, ?)
                """, arguments: [id, companyID, kitSlug, name, now, now])
            try Self.writeRevision(kit: id, manifest: manifest, note: note ?? "Created", by: client, in: db)
        }
        return try brandKit(id)!
    }

    /// Publishes a new revision. `expectedRevision` makes it optimistic (409 if someone published since).
    public func reviseBrandKit(_ ref: String, manifest: BrandManifest, note: String? = nil, expectedRevision: Int? = nil,
                               by client: ClientID? = nil) throws -> BrandKitInfo {
        let id: String = try database.pool.write { db in
            guard let id = try Self.resolveBrandKitID(Self.splitRevision(ref).0, in: db) else {
                throw APIError.notFound("No brand kit '\(ref)'.")
            }
            let current = try Int.fetchOne(db, sql: "SELECT current_revision FROM brand_kit WHERE id = ?", arguments: [id]) ?? 0
            if let expectedRevision, expectedRevision != current {
                throw APIError.conflict("revision_conflict", "Brand kit is at revision \(current), not \(expectedRevision).")
            }
            try Self.writeRevision(kit: id, manifest: manifest, note: note, by: client, in: db)
            return id
        }
        return try brandKit(id)!
    }

    public func archiveBrandKit(_ ref: String, archived: Bool = true) throws -> BrandKitInfo {
        let id: String = try database.pool.write { db in
            guard let id = try Self.resolveBrandKitID(Self.splitRevision(ref).0, in: db, includeArchived: true) else {
                throw APIError.notFound("No brand kit '\(ref)'.")
            }
            try db.execute(sql: "UPDATE brand_kit SET archived_at = ?, updated_at = ? WHERE id = ?",
                           arguments: [archived ? Date() : nil, Date(), id])
            return id
        }
        return try brandKit(id, includeArchived: true)!
    }

    /// Sets (or clears, with nil) the company's default kit.
    public func setDefaultBrandKit(company: String, kit: String?) throws {
        try database.pool.write { db in
            guard let cid = try Self.resolveCompanyID(company, in: db, includeArchived: true) else {
                throw APIError.notFound("No company '\(company)'.")
            }
            let kitID = try kit.map { ref -> String in
                guard let id = try Self.resolveBrandKitID(Self.splitRevision(ref).0, in: db) else {
                    throw APIError.unprocessable("unknown_brand_kit", "No brand kit '\(ref)'.", param: "default_brand_kit")
                }
                return id
            }
            try db.execute(sql: "UPDATE company SET default_brand_kit_id = ?, updated_at = ? WHERE id = ?",
                           arguments: [kitID, Date(), cid])
        }
    }

    /// Sets (or clears, with nil) the project's own kit.
    public func setProjectBrandKit(project: String, kit: String?) throws {
        try database.pool.write { db in
            guard let pid = try Self.resolveProjectID(project, in: db, includeArchived: true) else {
                throw APIError.notFound("No project '\(project)'.")
            }
            let kitID = try kit.map { ref -> String in
                guard let id = try Self.resolveBrandKitID(Self.splitRevision(ref).0, in: db) else {
                    throw APIError.unprocessable("unknown_brand_kit", "No brand kit '\(ref)'.", param: "brand_kit")
                }
                return id
            }
            try db.execute(sql: "UPDATE project SET brand_kit_id = ?, updated_at = ? WHERE id = ?",
                           arguments: [kitID, Date(), pid])
        }
    }

    // MARK: - style.json import

    /// Imports a marquee-brand-spec `style.json` plus the files it names (keyed by their relative path, e.g.
    /// `assets/mark-white.png`, `fonts/web/AcmeSans-Light.woff2`). Creates the company and kit if needed, else
    /// publishes a new revision — keeping the kit's existing `generation` block and `rules`, which style.json has
    /// no place for.
    public func importStyle(_ styleData: Data, files: [String: Data], by client: ClientID? = nil) throws -> BrandKitInfo {
        guard let style = try? JSONDecoder().decode(JSONValue.self, from: styleData).objectValue else {
            throw APIError.badRequest("invalid_json", "style.json is not a JSON object.")
        }
        guard let companyRef = style["company"]?.stringValue, let styleSlug = style["style"]?.stringValue else {
            throw APIError.unprocessable("invalid_style", "style.json needs `company` and `style`.", param: "style")
        }
        let licence = style["licence"]?.objectValue
        let holder = licence?["holder"]?.stringValue
        let decode: (JSONValue?) -> BrandColour? = { value in
            guard let value, let data = try? JSONEncoder().encode(value) else { return nil }
            return try? JSONDecoder().decode(BrandColour.self, from: data)
        }

        // The company first: the brand assets are filed under it.
        if try company(companyRef) == nil {
            _ = try createCompany(name: holder ?? companyRef, slug: companyRef)
        }
        // Upload the files style.json names. Brand assets belong to the client; their AI use stays unknown until
        // someone says otherwise (generation references still work — only `forbidden` blocks).
        let rights = AssetRights(rightsClass: .clientOwned, holder: holder, aiUse: .unknown,
                                 details: licence.map { ["licence": .object($0), "rights_source": "style.json"] })
        var refs: [BrandAssetRef] = []
        for item in style["assets"]?.arrayValue ?? [] {
            guard let asset = item.objectValue, let file = asset["file"]?.stringValue,
                  let data = files[file] ?? files[(file as NSString).lastPathComponent] else { continue }
            let id = asset["id"]?.stringValue ?? (file as NSString).lastPathComponent
            let uploaded = try importUpload(data, metadata: UploadMetadata(
                name: id, originalFilename: (file as NSString).lastPathComponent, rights: rights,
                company: companyRef, tags: []), origin: .import, uploadedBy: client)
            refs.append(BrandAssetRef(assetID: uploaded.asset.id, role: Self.brandRole(forStyleAssetID: id), sourceID: id))
        }
        if let family = style["fonts"]?.objectValue?["family"]?.objectValue, let fileSets = family["files"]?.objectValue {
            for (platform, list) in fileSets.sorted(by: { $0.key < $1.key }) {
                for path in list.arrayValue?.compactMap(\.stringValue) ?? [] {
                    guard let data = files[path] ?? files[(path as NSString).lastPathComponent] else { continue }
                    let uploaded = try importUpload(data, metadata: UploadMetadata(
                        name: (path as NSString).lastPathComponent, originalFilename: (path as NSString).lastPathComponent,
                        rights: rights, company: companyRef), origin: .import, uploadedBy: client)
                    refs.append(BrandAssetRef(assetID: uploaded.asset.id, role: "font", variant: platform, sourceID: path))
                }
            }
        }

        var manifest = BrandManifest(
            displayName: style["displayName"]?.stringValue, colour: decode(style["colour"]), fonts: style["fonts"],
            licence: licence.map { BrandLicence(holder: $0["holder"]?.stringValue, agreement: $0["agreement"]?.stringValue,
                                                scope: $0["scope"]?.stringValue) },
            assets: refs,
            source: ["format": style["format"] ?? "1.1", "company": .string(companyRef), "style": .string(styleSlug),
                     "version": style["version"] ?? .null])
        let name = style["displayName"]?.stringValue ?? styleSlug
        if let existing = try brandKit("\(companyRef)/\(styleSlug)") {
            manifest.generation = existing.manifest.generation
            manifest.rules = existing.manifest.rules
            let version = style["version"]?.intValue.map { " v\($0)" } ?? ""
            return try reviseBrandKit(existing.id, manifest: manifest, note: "Imported style.json\(version)", by: client)
        }
        return try createBrandKit(company: companyRef, name: name, slug: styleSlug, manifest: manifest,
                                  note: "Imported style.json", by: client)
    }

    /// Imports a brand folder: its `style.json` plus every file that names, read relative to the folder (paths
    /// that escape it are skipped). The console's "Import brand kit…" and the loopback `{"path"}` import use this.
    public func importStyle(folder: URL, by client: ClientID? = nil) throws -> BrandKitInfo {
        let root = folder.standardizedFileURL
        guard let style = try? Data(contentsOf: root.appendingPathComponent("style.json")) else {
            throw APIError.unprocessable("invalid_style", "No style.json in \(root.path).", param: "path")
        }
        var files: [String: Data] = [:]
        for name in Self.styleFilePaths(style) {
            let url = root.appendingPathComponent(name).standardizedFileURL
            guard url.path.hasPrefix(root.path + "/"), let data = try? Data(contentsOf: url) else { continue }
            files[name] = data
        }
        return try importStyle(style, files: files, by: client)
    }

    /// Every file path a style.json names (asset files and font files).
    public static func styleFilePaths(_ style: Data) -> [String] {
        guard let object = try? JSONDecoder().decode(JSONValue.self, from: style).objectValue else { return [] }
        var paths = (object["assets"]?.arrayValue ?? []).compactMap { $0.objectValue?["file"]?.stringValue }
        if let sets = object["fonts"]?.objectValue?["family"]?.objectValue?["files"]?.objectValue {
            for list in sets.values { paths += list.arrayValue?.compactMap(\.stringValue) ?? [] }
        }
        return paths
    }

    // MARK: - Internals

    static func splitRevision(_ ref: String) -> (String, Int?) {
        guard let at = ref.lastIndex(of: "@"), let n = Int(ref[ref.index(after: at)...]) else { return (ref, nil) }
        return (String(ref[..<at]), n)
    }

    static func resolveBrandKitID(_ ref: String, in db: Database, includeArchived: Bool = false) throws -> String? {
        let archived = includeArchived ? "" : " AND archived_at IS NULL"
        if ref.hasPrefix("bk_") {
            return try String.fetchOne(db, sql: "SELECT id FROM brand_kit WHERE id = ?\(archived)", arguments: [ref])
        }
        let parts = ref.split(separator: "/", maxSplits: 1).map(String.init)
        if parts.count == 2 {
            guard let cid = try resolveCompanyID(parts[0], in: db, includeArchived: true) else { return nil }
            return try String.fetchOne(db, sql: "SELECT id FROM brand_kit WHERE company_id = ? AND slug = ?\(archived)",
                                       arguments: [cid, slugify(parts[1])])
        }
        let matches = try String.fetchAll(db, sql: "SELECT id FROM brand_kit WHERE slug = ?\(archived) LIMIT 2",
                                          arguments: [slugify(ref)])
        return matches.count == 1 ? matches[0] : nil
    }

    static func brandKit(id: String, revision: Int?, in db: Database) throws -> BrandKitInfo? {
        guard let kit = try Row.fetchOne(db, sql: """
            SELECT k.*, c.slug AS company_slug FROM brand_kit k JOIN company c ON c.id = k.company_id WHERE k.id = ?
            """, arguments: [id]) else { return nil }
        let current: Int = kit["current_revision"]
        let wanted = revision ?? current
        guard let rev = try Row.fetchOne(db, sql: """
            SELECT manifest_json, note FROM brand_kit_revision WHERE kit_id = ? AND revision = ?
            """, arguments: [id, wanted]) else {
            if revision != nil { throw APIError.notFound("Brand kit \(id) has no revision \(wanted).") }
            return nil
        }
        let manifest = try JSONDecoder.imageServer.decode(BrandManifest.self, from: Data((rev["manifest_json"] as String).utf8))
        return BrandKitInfo(id: id, slug: kit["slug"], name: kit["name"], companyID: kit["company_id"],
                            companySlug: kit["company_slug"], revision: wanted, currentRevision: current,
                            manifest: manifest, note: rev["note"], createdAt: kit["created_at"],
                            updatedAt: kit["updated_at"], archivedAt: kit["archived_at"])
    }

    static func writeRevision(kit id: String, manifest: BrandManifest, note: String?, by client: ClientID?,
                              in db: Database) throws {
        for ref in manifest.assets {
            guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM asset WHERE id = ? AND trashed_at IS NULL)",
                                    arguments: [ref.assetID.rawValue]) == true else {
                throw APIError.unprocessable("input_unresolvable", "Brand asset \(ref.assetID) is not in the library.",
                                             param: "manifest.assets")
            }
        }
        let next = (try Int.fetchOne(db, sql: "SELECT current_revision FROM brand_kit WHERE id = ?", arguments: [id]) ?? 0) + 1
        let now = Date()
        let json = String(decoding: try JSONEncoder.imageServer.encode(manifest), as: UTF8.self)
        try db.execute(sql: """
            INSERT INTO brand_kit_revision(kit_id, revision, manifest_json, note, created_by, created_at)
            VALUES (?, ?, ?, ?, ?, ?)
            """, arguments: [id, next, json, note, client?.rawValue, now])
        for ref in manifest.assets {
            try db.execute(sql: """
                INSERT OR IGNORE INTO brand_kit_asset(kit_id, revision, asset_id, role, variant) VALUES (?, ?, ?, ?, ?)
                """, arguments: [id, next, ref.assetID.rawValue, ref.role, ref.variant])
        }
        try db.execute(sql: "UPDATE brand_kit SET current_revision = ?, updated_at = ? WHERE id = ?",
                       arguments: [next, now, id])
    }

    static func companyID(for ref: String, create: Bool, in db: Database) throws -> String {
        if let id = try resolveCompanyID(ref, in: db) { return id }
        guard create else { throw APIError.unprocessable("unknown_company", "No company '\(ref)'.", param: "company") }
        let id = "cmp_" + ULID.make()
        let now = Date()
        try db.execute(sql: "INSERT INTO company(id, slug, name, created_at, updated_at) VALUES (?, ?, ?, ?, ?)",
                       arguments: [id, slugify(ref), ref, now, now])
        return id
    }

    /// style.json asset ids are free-form; map the common shapes onto brand roles.
    static func brandRole(forStyleAssetID id: String) -> String {
        let lower = id.lowercased()
        if lower.contains("wordmark") { return "wordmark" }
        if lower.contains("lockup") { return "lockup" }
        if lower.contains("logo") || lower.contains("mark") { return "logo" }
        if lower.contains("icon") { return "icon" }
        if lower.contains("bg") || lower.contains("background") || lower.contains("backing") { return "backing" }
        if lower.contains("pattern") || lower.contains("texture") { return "pattern" }
        if lower.contains("guide") { return "guideline" }
        return "reference"
    }
}
