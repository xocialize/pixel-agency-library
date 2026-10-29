import CoreGraphics
import Foundation
import GRDB
import ImageIO
@testable import ImageLibrary
import ImageServerAPI
import Testing
import UniformTypeIdentifiers

// MARK: - Fixtures

func makeLibrary() throws -> AssetLibrary {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("imgsrv-lib-\(UUID().uuidString)")
    return try AssetLibrary.open(root: root, cacheRoot: root.appendingPathComponent("cache")).0
}

/// A small synthetic photo-like image: a two-colour gradient with a block, so palette and dHash are non-trivial.
func makeImage(width: Int = 96, height: Int = 64, hue: Double = 0.1, block: Bool = true) -> CGImage {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    let colors = [CGColor(red: hue, green: 0.4, blue: 0.9 - hue, alpha: 1), CGColor(red: 1 - hue, green: 0.8, blue: 0.2, alpha: 1)]
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
    if block {
        ctx.setFillColor(CGColor(red: 0.05, green: 0.05, blue: 0.05, alpha: 1))
        ctx.fill(CGRect(x: width / 4, y: height / 4, width: width / 3, height: height / 3))
    }
    return ctx.makeImage()!
}

/// JPEG bytes with IPTC metadata embedded.
func jpeg(_ image: CGImage, quality: Double = 0.9, iptc: [CFString: Any]? = nil) -> Data {
    let data = NSMutableData()
    let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
    var props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
    if let iptc { props[kCGImagePropertyIPTCDictionary] = iptc }
    CGImageDestinationAddImage(dest, image, props as CFDictionary)
    CGImageDestinationFinalize(dest)
    return data as Data
}

func png(_ image: CGImage) -> Data {
    let data = NSMutableData()
    let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
    return data as Data
}

func scaled(_ image: CGImage, to width: Int, _ height: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return ctx.makeImage()!
}

// MARK: - Tests

@Suite("CMS: companies, projects, membership")
struct ProjectTests {
    @Test("Projects resolve by id, slug and company/slug; slugs are unique per company")
    func resolution() throws {
        let lib = try makeLibrary()
        let acme = try lib.createCompany(name: "Acme Corp")
        #expect(acme.slug == "acme-corp")
        let launch = try lib.createProject(name: "Summer Launch", company: "acme-corp")
        #expect(launch.path == "acme-corp/summer-launch")
        #expect(try lib.project("acme-corp/summer-launch")?.id == launch.id)
        #expect(try lib.project(launch.id)?.id == launch.id)
        #expect(try lib.project("summer-launch")?.id == launch.id)
        // Same slug under another company is fine; then the bare slug is ambiguous.
        _ = try lib.createProject(name: "Summer Launch", company: "Globex", createCompany: true)
        #expect(try lib.project("summer-launch") == nil)
        #expect(throws: APIError.self) { _ = try lib.createProject(name: "Summer Launch", company: "acme-corp") }
    }

    @Test("An asset has at most one home; moving home moves its company; status is per project")
    func membership() throws {
        let lib = try makeLibrary()
        _ = try lib.createProject(name: "A", company: "Acme", createCompany: true)
        _ = try lib.createProject(name: "B", company: "Globex", createCompany: true)
        let up = try lib.importUpload(png(makeImage()), metadata: UploadMetadata(project: "acme/a", status: .draft), origin: .user)
        #expect(up.asset.home?.slug == "a")
        #expect(up.asset.companySlug == "acme")

        try lib.addToProject([up.asset.id], project: "globex/b", status: .approved, origin: .user)
        var asset = try #require(try lib.asset(up.asset.id))
        #expect(asset.projects.count == 2)
        #expect(asset.projects.first { $0.slug == "a" }?.status == .draft)
        #expect(asset.projects.first { $0.slug == "b" }?.status == .approved)
        #expect(asset.home?.slug == "a")

        asset = try lib.patch(up.asset.id, AssetPatch(projects: ProjectEdit(home: "globex/b")), origin: .user)
        #expect(asset.home?.slug == "b")
        #expect(asset.companySlug == "globex")
        let homes = try lib.database.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM project_asset WHERE asset_id = ? AND is_home = 1",
                             arguments: [up.asset.id.rawValue])
        }
        #expect(homes == 1)
    }

    @Test("Edits are optimistic: a stale revision is a 409")
    func revisionConflict() throws {
        let lib = try makeLibrary()
        let up = try lib.importUpload(png(makeImage()), origin: .user)
        let edited = try lib.patch(up.asset.id, AssetPatch(caption: "first", revision: up.asset.revision), origin: .user)
        #expect(edited.revision == up.asset.revision + 1)
        do {
            _ = try lib.patch(up.asset.id, AssetPatch(caption: "second", revision: up.asset.revision), origin: .user)
            Issue.record("expected revision_conflict")
        } catch let error as APIError {
            #expect(error.code == "revision_conflict")
        }
    }
}

@Suite("CMS: uploads")
struct UploadTests {
    @Test("A JPEG with IPTC lands with imported fields, keywords, palette and hash — caller values win")
    func iptcImport() throws {
        let lib = try makeLibrary()
        _ = try lib.createProject(name: "Summer Launch", company: "Acme", createCompany: true)
        let data = jpeg(makeImage(), iptc: [
            kCGImagePropertyIPTCObjectName: "Beach Hero",
            kCGImagePropertyIPTCCaptionAbstract: "Golden hour on the beach",
            kCGImagePropertyIPTCKeywords: ["Beach", "sunset", "usage:social"],
            kCGImagePropertyIPTCByline: "Jane Photographer",
            kCGImagePropertyIPTCCopyrightNotice: "© 2026 Acme",
            kCGImagePropertyIPTCRightsUsageTerms: "Web and social only",
        ])
        let result = try lib.importUpload(data, metadata: UploadMetadata(
            originalFilename: "IMG_0042.jpg", caption: "Caller caption", project: "acme/summer-launch",
            status: .review, tags: ["hero"]), origin: .api)
        let a = result.asset
        #expect(a.name == "Beach Hero")
        #expect(a.caption == "Caller caption", "caller values are never overridden by IPTC")
        #expect(a.creator == "Jane Photographer")
        #expect(a.copyright == "© 2026 Acme")
        #expect(a.rights.rightsClass == .unknown)
        #expect(a.rights.details?["rights_source"] == "import")
        #expect(Set(a.tags) == ["beach", "sunset", "usage:social", "hero"])
        #expect(result.importedFields.contains("creator"))
        #expect(!result.importedFields.contains("caption"))
        #expect(a.mimeType == "image/jpeg")
        #expect(a.orientation == "landscape")
        #expect(!a.palette.isEmpty && a.palette.allSatisfy { $0.hex.hasPrefix("#") })
        #expect(a.home?.status == .review)
        let phash = try lib.database.pool.read { db in
            try Int64?.fetchOne(db, sql: "SELECT phash FROM blob WHERE hash = ?", arguments: [a.contentHash])
        }
        #expect(phash != nil)
    }

    @Test("Same bytes into the same project dedupe; into another project they share the blob")
    func dedupe() throws {
        let lib = try makeLibrary()
        _ = try lib.createProject(name: "A")
        _ = try lib.createProject(name: "B")
        let bytes = png(makeImage())
        let first = try lib.importUpload(bytes, metadata: UploadMetadata(project: "a"), origin: .user)
        let again = try lib.importUpload(bytes, metadata: UploadMetadata(caption: "filled later", project: "a"), origin: .user)
        #expect(again.deduplicated)
        #expect(again.asset.id == first.asset.id)
        #expect(again.asset.caption == "filled later", "empty fields are filled on dedupe")
        let other = try lib.importUpload(bytes, metadata: UploadMetadata(project: "b"), origin: .user)
        #expect(!other.deduplicated)
        #expect(other.asset.id != first.asset.id)
        #expect(other.asset.contentHash == first.asset.contentHash)
        #expect(other.duplicates.contains(first.asset.id))
    }

    @Test("A resized, recompressed copy is reported as a near-duplicate")
    func nearDuplicate() throws {
        let lib = try makeLibrary()
        let image = makeImage(width: 256, height: 170)
        let original = try lib.importUpload(png(image), origin: .user)
        let copy = try lib.importUpload(jpeg(scaled(image, to: 128, 85), quality: 0.6), origin: .user)
        #expect(copy.nearDuplicates.contains(original.asset.id))
        let different = try lib.importUpload(png(makeImage(width: 256, height: 170, hue: 0.9, block: false)), origin: .user)
        #expect(!different.nearDuplicates.contains(original.asset.id))
    }
}

@Suite("CMS: tags")
struct TagTests {
    @Test("Controlled namespaces only accept listed values; reserved namespaces are refused")
    func policies() throws {
        let lib = try makeLibrary()
        let up = try lib.importUpload(png(makeImage()), origin: .user)
        #expect(try lib.tagAssets([up.asset.id], add: ["usage:social", "  Subject:  Beach  "], remove: [], origin: .user)
            == ["subject:beach", "usage:social"])
        do {
            try lib.tagAssets([up.asset.id], add: ["usage:billboard"], remove: [], origin: .user)
            Issue.record("expected tag_not_allowed")
        } catch let e as APIError { #expect(e.code == "tag_not_allowed") }
        do {
            try lib.tagAssets([up.asset.id], add: ["project:acme"], remove: [], origin: .user)
            Issue.record("expected reserved_namespace")
        } catch let e as APIError { #expect(e.code == "reserved_namespace") }
    }

    @Test("Merging moves assignments and keeps the old name as an alias")
    func merge() throws {
        let lib = try makeLibrary()
        let a = try lib.importUpload(png(makeImage()), metadata: UploadMetadata(tags: ["sunset"]), origin: .user)
        let b = try lib.importUpload(png(makeImage(hue: 0.5)), metadata: UploadMetadata(tags: ["sundown"]), origin: .user)
        let tags = try lib.tags()
        let sunset = try #require(tags.first { $0.name == "sunset" })
        let sundown = try #require(tags.first { $0.name == "sundown" })
        try lib.mergeTag(sundown.id, into: sunset.id)
        #expect(try lib.asset(b.asset.id)?.tags == ["sunset"])
        // Writing the old name lands on the target.
        let c = try lib.importUpload(png(makeImage(hue: 0.7)), metadata: UploadMetadata(tags: ["sundown"]), origin: .user)
        #expect(c.asset.tags == ["sunset"])
        #expect(try lib.search(AssetQuery(tags: ["sundown"])).total == 3)
        _ = a
    }
}

@Suite("CMS: search")
struct SearchTests {
    func seeded() throws -> (AssetLibrary, [AssetID]) {
        let lib = try makeLibrary()
        _ = try lib.createProject(name: "Summer Launch", company: "Acme", createCompany: true)
        _ = try lib.createProject(name: "Winter Promo", company: "Acme")
        var ids: [AssetID] = []
        ids.append(try lib.importUpload(png(makeImage(hue: 0.1)), metadata: UploadMetadata(
            caption: "Hero shot at golden hour", project: "acme/summer-launch", status: .approved,
            tags: ["usage:social", "beach"]), origin: .user).asset.id)
        ids.append(try lib.importUpload(png(makeImage(hue: 0.3)), metadata: UploadMetadata(
            caption: "Alternate hero, overcast", project: "acme/summer-launch", status: .draft,
            tags: ["usage:web"]), origin: .user).asset.id)
        ids.append(try lib.importUpload(png(makeImage(width: 64, height: 96, hue: 0.6)), metadata: UploadMetadata(
            caption: "Snowy storefront", project: "acme/winter-promo", status: .final,
            tags: ["usage:print"]), origin: .user).asset.id)
        ids.append(try lib.importUpload(png(makeImage(hue: 0.8)), metadata: UploadMetadata(
            name: "loose sketch"), origin: .user).asset.id)
        return (lib, ids)
    }

    @Test("Full text: words are prefix terms, phrases stay phrases, places and tags are searchable")
    func fullText() throws {
        let (lib, ids) = try seeded()
        #expect(Set(try lib.search(AssetQuery(text: "hero")).assets.map(\.id)) == [ids[0], ids[1]])
        #expect(try lib.search(AssetQuery(text: "\"golden hour\"")).assets.map(\.id) == [ids[0]])
        #expect(try lib.search(AssetQuery(text: "gold")).assets.map(\.id) == [ids[0]], "prefix match")
        #expect(try lib.search(AssetQuery(text: "winter")).assets.map(\.id) == [ids[2]], "project names are indexed")
        #expect(try lib.search(AssetQuery(text: "beach")).assets.map(\.id) == [ids[0]], "tags are indexed")
    }

    @Test("The query language parses into structured filters")
    func queryLanguage() throws {
        let (lib, ids) = try seeded()
        let q = AssetQuery.parse(#"hero project:acme/summer-launch usage:social -status:rejected"#)
        #expect(q.text == "hero")
        #expect(q.projects == ["acme/summer-launch"])
        #expect(q.tags == ["usage:social"])
        #expect(q.excludeStatuses == [.rejected])
        #expect(try lib.search(q).assets.map(\.id) == [ids[0]])
        #expect(try lib.search(.parse("is:inbox")).assets.map(\.id) == [ids[3]])
        #expect(try lib.search(.parse("orient:portrait")).assets.map(\.id) == [ids[2]])
        #expect(try lib.search(.parse("status:draft")).assets.map(\.id) == [ids[1]])
        #expect(try lib.search(.parse("client:acme")).total == 3)
    }

    @Test("Facets count the result set; a facet ignores its own filter")
    func facets() throws {
        let (lib, _) = try seeded()
        let all = try lib.search(AssetQuery(facets: ["project", "tag", "status"]))
        #expect(all.total == 4)
        #expect(all.facets["project"]?.first { $0.label == "acme/summer-launch" }?.count == 2)
        #expect(all.facets["tag"]?.first { $0.label == "usage:social" }?.count == 1)

        let filtered = try lib.search(AssetQuery(projects: ["acme/summer-launch"], facets: ["project", "status"]))
        #expect(filtered.total == 2)
        // The project facet still shows the other project (its own filter is ignored)…
        #expect(filtered.facets["project"]?.contains { $0.label == "acme/winter-promo" } == true)
        // …while status counts are scoped to the filtered project.
        #expect(Set(filtered.facets["status"]?.map(\.value) ?? []) == ["approved", "draft"])
    }

    @Test("Cursor paging walks the whole result")
    func paging() throws {
        let (lib, _) = try seeded()
        var seen: [AssetID] = []
        var cursor: String?
        repeat {
            let page = try lib.search(AssetQuery(cursor: cursor, limit: 3))
            seen += page.assets.map(\.id)
            cursor = page.nextCursor
        } while cursor != nil
        #expect(seen.count == 4 && Set(seen).count == 4)
    }

    /// The search documents must always equal the view they derive from, whatever sequence of edits happens.
    @Test("Search documents never drift from their view under random edits (FTS integrity holds)")
    func ftsInvariant() throws {
        let (lib, ids) = try seeded()
        var rng = SystemRandomNumberGenerator()
        let words = ["alpha", "beta", "gamma", "delta", "hero", "sunset", "usage:web", "usage:social", "subject:dog"]
        for step in 0..<120 {
            let id = ids.randomElement(using: &rng)!
            switch Int.random(in: 0..<6, using: &rng) {
            case 0: _ = try lib.patch(id, AssetPatch(caption: words.randomElement(using: &rng)! + " \(step)"), origin: .user)
            case 1: try lib.tagAssets([id], add: [words.randomElement(using: &rng)!], remove: [], origin: .agent)
            case 2: try lib.tagAssets([id], add: [], remove: [words.randomElement(using: &rng)!], origin: .user)
            case 3: try lib.addToProject([id], project: Bool.random(using: &rng) ? "acme/summer-launch" : "acme/winter-promo",
                                         home: Bool.random(using: &rng), origin: .user)
            case 4: _ = try lib.updateProject("acme/winter-promo", name: "Winter \(step)", slug: nil, description: nil, archived: nil)
            default:
                if let tag = try lib.tags().randomElement(using: &rng), !tag.name.contains(":") {
                    _ = try? lib.renameTag(tag.id, to: tag.name + "x")
                }
            }
        }
        try lib.database.pool.read { db in
            let drift = try Int.fetchOne(db, sql: """
                SELECT count(*) FROM asset_doc_v v LEFT JOIN asset_doc d ON d.asset_id = v.asset_id
                WHERE d.asset_id IS NULL OR d.name IS NOT v.name OR d.caption IS NOT v.caption OR d.prompt IS NOT v.prompt
                   OR d.tags IS NOT v.tags OR d.auto_tags IS NOT v.auto_tags OR d.places IS NOT v.places
                   OR d.credit IS NOT v.credit OR d.notes IS NOT v.notes
                """)
            #expect(drift == 0)
        }
        try lib.database.pool.write { db in
            try db.execute(sql: "INSERT INTO asset_fts(asset_fts, rank) VALUES ('integrity-check', 1)")
        }
    }
}

@Suite("CMS: v1 → v2 migration")
struct MigrationTests {
    @Test("A v1 library migrates with assets and user tags intact; v1 tag filters keep working")
    func upgrade() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("imgsrv-mig-\(UUID().uuidString)")
        let url = dir.appendingPathComponent("library.sqlite")
        let v1 = try ServerDatabase(url: url, migrateUpTo: "v1b-settings")
        let now = Date()
        try v1.pool.write { db in
            try db.execute(sql: "INSERT INTO blob(hash, bytes, mime, ext, width, height, has_alpha, created_at) VALUES ('sha256:aa', 10, 'image/png', 'png', 100, 50, 0, ?)", arguments: [now])
            try db.execute(sql: """
                INSERT INTO generation(id, job_id, capability, model_id, package_id, license_class, info_json, created_at)
                VALUES ('gen_1', 'job_1', 'textToImage', 'z-image-turbo', 'imgsrv.z-image-turbo', 'permissive', ?, ?)
                """, arguments: [#"{"prompt":"a red fox in snow","job_id":"job_1","capability":"textToImage","model":"z-image-turbo","package_id":"imgsrv.z-image-turbo","source_repo":"x","revision":"main","params":{},"inputs":[],"engine_version":"1","app_version":"0.1.0","client":"local"}"#, now])
            try db.execute(sql: """
                INSERT INTO asset(id, blob_hash, kind, mime, width, height, bytes, source, job_id, generation_id, ordinal, license_class, created_at)
                VALUES ('ast_GEN', 'sha256:aa', 'image', 'image/png', 100, 50, 10, 'generated', 'job_1', 'gen_1', 0, 'permissive', ?)
                """, arguments: [now])
            try db.execute(sql: """
                INSERT INTO asset(id, blob_hash, kind, name, mime, width, height, bytes, source, ordinal, license_class, created_at)
                VALUES ('ast_UP', 'sha256:aa', 'image', 'moodboard', 'image/png', 100, 50, 10, 'uploaded', 0, 'permissive', ?)
                """, arguments: [now])
            for (tid, name) in [(1, "model:z-image-turbo"), (2, "source:generated"), (3, "smoke-test")] {
                try db.execute(sql: "INSERT INTO tag(id, name) VALUES (?, ?)", arguments: [tid, name])
            }
            try db.execute(sql: "INSERT INTO asset_tag(asset_id, tag_id, origin) VALUES ('ast_GEN', 1, 'system'), ('ast_GEN', 2, 'system'), ('ast_GEN', 3, 'agent')")
        }
        try v1.migrateToLatest()
        let lib = AssetLibrary(database: v1, blobs: try BlobStore(root: dir), thumbnails: try ThumbnailCache(root: dir.appendingPathComponent("t")))

        let gen = try #require(try lib.asset(AssetID(rawValue: "ast_GEN")))
        #expect(gen.tags == ["smoke-test"], "system tags dropped, user tags kept")
        #expect(gen.rights.rightsClass == .owned)
        #expect(gen.orientation == "landscape")
        let up = try #require(try lib.asset(AssetID(rawValue: "ast_UP")))
        #expect(up.rights.rightsClass == .unknown)
        // v1-style filters still work via reserved namespaces.
        #expect(try lib.search(AssetQuery(tags: ["model:z-image-turbo"])).assets.map(\.id.rawValue) == ["ast_GEN"])
        #expect(try lib.search(AssetQuery(tags: ["source:uploaded"])).assets.map(\.id.rawValue) == ["ast_UP"])
        // The backfilled search documents find the prompt and the name.
        #expect(try lib.search(AssetQuery(text: "fox")).assets.map(\.id.rawValue) == ["ast_GEN"])
        #expect(try lib.search(AssetQuery(text: "moodboard")).assets.map(\.id.rawValue) == ["ast_UP"])
    }
}

@Suite("CMS: search performance")
struct SearchPerformanceTests {
    /// L1 exit criterion: 10k assets, search + 5 facets under 50 ms.
    @Test("10k assets: full-text search with 5 facets stays under 50 ms")
    func tenThousand() throws {
        let lib = try makeLibrary()
        let projects = try (0..<20).map { try lib.createProject(name: "Project \($0)", company: "Client \($0 % 5)", createCompany: true) }
        let words = ["sunset", "beach", "hero", "studio", "portrait", "city", "night", "forest", "product", "lifestyle"]
        try lib.database.pool.write { db in
            let now = Date()
            try db.execute(sql: "INSERT INTO blob(hash, bytes, mime, ext, width, height, has_alpha, created_at) VALUES ('sha256:perf', 1, 'image/png', 'png', 1024, 768, 0, ?)", arguments: [now])
            for t in ["usage:web", "usage:social", "subject:food", "subject:people", "campaign:q4"] {
                try db.execute(sql: "INSERT INTO tag(name, namespace, created_at) VALUES (?, ?, ?)", arguments: [t, String(t.split(separator: ":")[0]), now])
            }
            for i in 0..<10_000 {
                let id = "ast_PERF\(String(format: "%06d", i))"
                let caption = "\(words[i % 10]) \(words[(i / 10) % 10]) shot \(i)"
                try db.execute(sql: """
                    INSERT INTO asset(id, blob_hash, kind, name, caption, mime, width, height, bytes, source, ordinal,
                        license_class, rights_class, created_at, updated_at)
                    VALUES (?, 'sha256:perf', 'image', ?, ?, 'image/png', ?, 768, 1, ?, 0, 'permissive', 'owned', ?, ?)
                    """, arguments: [id, "asset \(i)", caption, i % 3 == 0 ? 512 : 1024, i % 4 == 0 ? "uploaded" : "generated", now, now])
                try db.execute(sql: "INSERT INTO asset_tag(asset_id, tag_id, origin) VALUES (?, ?, 'user')", arguments: [id, Int64(i % 5 + 1)])
                try db.execute(sql: "INSERT INTO project_asset(project_id, asset_id, is_home, status, added_at) VALUES (?, ?, 1, ?, ?)",
                               arguments: [projects[i % 20].id, id, ["draft", "review", "approved"][i % 3], now])
            }
        }
        let query = AssetQuery(text: "sunset beach", limit: 50, facets: ["project", "tag", "status", "source", "orientation"])
        _ = try lib.search(query)  // warm the page cache
        var samples: [Duration] = []
        for _ in 0..<10 {
            let start = ContinuousClock.now
            let result = try lib.search(query)
            samples.append(ContinuousClock.now - start)
            #expect(result.total == 200, "\"sunset beach\" matches either word order: 2 of every 100 captions")
        }
        let p95 = samples.sorted()[8]
        print("search+5 facets over 10k assets: p95 \(p95)")
        #expect(p95 < .milliseconds(50))
    }
}

@Suite("CMS: facts backfill")
struct FactsBackfillTests {
    @Test("Blobs stored before facts existed get a hash and palette, then near-duplicate detection sees them")
    func backfill() throws {
        let lib = try makeLibrary()
        let image = makeImage(width: 256, height: 170)
        let first = try lib.importUpload(png(image), origin: .user)
        // Simulate a v1 blob: no facts.
        try lib.database.pool.write { db in
            try db.execute(sql: "UPDATE blob SET phash = NULL, facts_version = 0 WHERE hash = ?", arguments: [first.asset.contentHash])
            try db.execute(sql: "DELETE FROM blob_color WHERE blob_hash = ?", arguments: [first.asset.contentHash])
        }
        #expect(try lib.backfillFacts() == 1)
        #expect(try lib.backfillFacts() == 0)
        #expect(try lib.asset(first.asset.id)?.palette.isEmpty == false)
        let copy = try lib.importUpload(jpeg(scaled(image, to: 128, 85), quality: 0.6), origin: .user)
        #expect(copy.nearDuplicates.contains(first.asset.id))
    }
}
