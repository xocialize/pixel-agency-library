import Foundation
import GRDB
@testable import ImageLibrary
import ImageServerAPI
import Testing

@Suite("Retention: expiry, trash purge, blob GC")
struct SweeperTests {
    let day: TimeInterval = 86_400

    func upload(_ library: AssetLibrary, hue: Double, project: String? = nil, tags: [String] = []) throws -> AssetInfo {
        var metadata = UploadMetadata(originalFilename: "img-\(hue).png")
        metadata.project = project
        metadata.tags = tags
        return try library.importUpload(png(makeImage(hue: hue)), metadata: metadata, origin: .user).asset
    }

    func backdateTrash(_ library: AssetLibrary, _ id: AssetID, by interval: TimeInterval) throws {
        try library.database.pool.write { db in
            try db.execute(sql: "UPDATE asset SET trashed_at = ? WHERE id = ?", arguments: [Date().addingTimeInterval(-interval), id.rawValue])
        }
    }

    func blobFile(_ library: AssetLibrary, _ id: AssetID) throws -> URL {
        try #require(try library.content(id, includingTrashed: true)).url
    }

    @Test("The trash is purged after 30 days, with its bytes; younger trash and its bytes stay")
    func purge() throws {
        let library = try makeLibrary()
        _ = try library.createProject(name: "Launch")
        let old = try upload(library, hue: 0.1, project: "launch", tags: ["usage:social"])
        let young = try upload(library, hue: 0.6)
        let oldFile = try blobFile(library, old.id), youngFile = try blobFile(library, young.id)
        try library.trash(old.id)
        try library.trash(young.id)
        try backdateTrash(library, old.id, by: 31 * day)
        try backdateTrash(library, young.id, by: 2 * day)

        let report = try library.sweep()
        #expect(report.purged == 1 && report.held == 0 && report.blobsRemoved == 1 && report.bytesFreed == old.bytes)
        #expect(try library.trashed().map(\.id) == [young.id])
        #expect(!FileManager.default.fileExists(atPath: oldFile.path))
        #expect(FileManager.default.fileExists(atPath: youngFile.path))
        // Memberships and tags went with it; the search index too.
        #expect(try library.search(AssetQuery(text: "img")).total == 0)
        #expect(try library.project("launch")?.assetCount == 0)

        try library.restore(young.id)
        #expect(try library.asset(young.id) != nil, "restore brings it back")
    }

    @Test("Bytes shared with a live asset are kept when one owner is purged")
    func sharedBlob() throws {
        let library = try makeLibrary()
        _ = try library.createProject(name: "A")
        _ = try library.createProject(name: "B")
        let a = try upload(library, hue: 0.3, project: "a")
        let b = try upload(library, hue: 0.3, project: "b")
        #expect(a.contentHash == b.contentHash && a.id != b.id)
        try library.trash(a.id)
        try backdateTrash(library, a.id, by: 40 * day)
        let report = try library.sweep()
        #expect(report.purged == 1 && report.blobsRemoved == 0)
        #expect(FileManager.default.fileExists(atPath: try blobFile(library, b.id).path))
    }

    @Test("Rows that refuse a delete hold what they reference: the asset stays trashed, other tables' bytes stay")
    func holds() throws {
        let library = try makeLibrary()
        let asset = try upload(library, hue: 0.2)
        let other = try upload(library, hue: 0.8)
        // Stand-ins for a job's inputs (asset, RESTRICT) and an app's own table of renditions (blob, RESTRICT).
        try library.database.pool.write { db in
            try db.execute(sql: """
                CREATE TABLE test_hold(asset_id TEXT NOT NULL REFERENCES asset(id) ON DELETE RESTRICT);
                CREATE TABLE test_rendition(asset_id TEXT NOT NULL REFERENCES asset(id) ON DELETE CASCADE,
                    blob_hash TEXT NOT NULL REFERENCES blob(hash) ON DELETE RESTRICT);
                """)
            try db.execute(sql: "INSERT INTO test_hold(asset_id) VALUES (?)", arguments: [asset.id.rawValue])
        }
        // `other`'s rendition is `asset`'s bytes: purging `other` must not take them.
        try library.database.pool.write { db in
            try db.execute(sql: "INSERT INTO test_rendition(asset_id, blob_hash) VALUES (?, ?)",
                           arguments: [other.id.rawValue, asset.contentHash])
        }
        for id in [asset.id, other.id] { try library.trash(id); try backdateTrash(library, id, by: 60 * day) }

        let report = try library.sweep()
        #expect(report.held == 1 && report.purged == 1)
        #expect(try library.trashed().map(\.id) == [asset.id], "held, still restorable")
        #expect(FileManager.default.fileExists(atPath: try blobFile(library, asset.id).path))

        // Release the hold: the next sweep purges it, and its bytes go too (the rendition went with `other`).
        try library.database.pool.write { db in try db.execute(sql: "DELETE FROM test_hold") }
        let file = try blobFile(library, asset.id)
        let again = try library.sweep()
        #expect(again.purged == 1 && again.blobsRemoved == 1)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test("A blob held only by another table survives; released, collectBlobs removes it at once")
    func collectReleased() throws {
        let library = try makeLibrary()
        try library.database.pool.write { db in
            try db.execute(sql: "CREATE TABLE test_rendition(blob_hash TEXT NOT NULL REFERENCES blob(hash) ON DELETE RESTRICT)")
        }
        let data = png(makeImage(hue: 0.45, block: false))
        let stored = try library.blobs.store(data, fileExtension: "png")
        try library.database.pool.write { db in
            try library.recordBlob(stored, data: data, mime: "image/png", fileExtension: "png", width: 96, height: 64,
                                   hasAlpha: false, in: db)
            try db.execute(sql: "INSERT INTO test_rendition(blob_hash) VALUES (?)", arguments: [stored.hash])
        }
        #expect(try library.sweep().blobsRemoved == 0)
        try library.database.pool.write { db in try db.execute(sql: "DELETE FROM test_rendition") }
        let collected = try library.collectBlobs([stored.hash])
        #expect(collected.count == 1 && collected.bytes == stored.bytes)
        #expect(!FileManager.default.fileExists(atPath: stored.url.path))
    }

    @Test("Expired ephemeral uploads move to the trash; kept uploads don't expire")
    func expiry() throws {
        let library = try makeLibrary()
        let inline = try library.importUpload(png(makeImage(hue: 0.7)), origin: .api, ephemeral: true).asset
        let kept = try upload(library, hue: 0.9)
        #expect(try library.sweep().expired == 0)
        let report = try library.sweep(now: Date().addingTimeInterval(2 * day))
        #expect(report.expired == 1)
        #expect(try library.trashed().map(\.id) == [inline.id])
        #expect(try library.asset(kept.id) != nil)
    }

    @Test("Files with no row are removed after the grace period; a fresh one may be a write in flight")
    func orphans() throws {
        let library = try makeLibrary()
        let stray = try library.blobs.store(png(makeImage(hue: 0.15)), fileExtension: "png")
        #expect(try library.sweep().orphanFilesRemoved == 0, "younger than the grace period")
        #expect(try library.sweep(now: Date().addingTimeInterval(2 * 3_600)).orphanFilesRemoved == 1)
        #expect(!FileManager.default.fileExists(atPath: stray.url.path))
    }

    @Test("Bytes collected by a sweep are stored again when the same image is imported later")
    func reimport() throws {
        let library = try makeLibrary()
        let first = try upload(library, hue: 0.33)
        let file = try blobFile(library, first.id)
        try library.trash(first.id)
        try backdateTrash(library, first.id, by: 31 * day)
        try library.sweep()
        #expect(!FileManager.default.fileExists(atPath: file.path))
        let second = try upload(library, hue: 0.33)
        #expect(second.contentHash == first.contentHash)
        #expect(FileManager.default.fileExists(atPath: try blobFile(library, second.id).path))
    }
}

@Suite("Outputs stored for runs this server doesn't own")
struct StoreOutputsTests {
    @Test("storeOutputs: provenance, inherited rights, filing and tags, with the caller's own row in the same transaction; lineage both ways")
    func storeOutputs() throws {
        let library = try makeLibrary()
        _ = try library.createProject(name: "Launch")
        var metadata = UploadMetadata(originalFilename: "source.png")
        metadata.project = "launch"
        metadata.rights = AssetRights(rightsClass: .licensed, holder: "Stock Co", aiUse: .allowed)
        let source = try library.importUpload(png(makeImage(hue: 0.25)), metadata: metadata, origin: .user).asset
        try library.database.pool.write { db in try db.execute(sql: "CREATE TABLE test_ticket(id TEXT, assets TEXT)") }

        let encoded = try ImageEncoding.encode(makeImage(hue: 0.6), as: .png, provenance: nil)
        let generation = GenerationInfo(jobID: JobID(rawValue: "tkt_01TEST"), capability: .imageRestore, model: "nafnet",
                                        packageID: "forge.nafnet", sourceRepo: "", revision: "", mode: nil, prompt: nil,
                                        negativePrompt: nil, seed: nil, width: 96, height: 64, steps: nil, guidance: nil,
                                        params: [:], inputs: [source.id], queueMs: nil, prepareMs: nil, runMs: 12,
                                        engineVersion: "built-in", appVersion: "test", client: ClientID(rawValue: "desktop"))
        let license = LicenseStamp(licenseClass: .permissive, weightLicenses: ["MIT"], portCodeLicense: "MIT")
        let ids = try library.storeOutputs([.init(encoded: encoded, generation: generation)], runID: "tkt_01TEST",
                                           inputs: [source.id], license: license,
                                           filing: AssetLibrary.Filing(projectID: try library.requireProjectID("launch")),
                                           tags: ["run:restore"], tagOrigin: .user) { db, assets in
            try db.execute(sql: "INSERT INTO test_ticket(id, assets) VALUES ('tkt_01TEST', ?)", arguments: [assets.map(\.rawValue).joined()])
        }
        let first = try #require(ids.first)
        let output = try #require(try library.asset(first))
        #expect(output.source == .derived && output.generation?.model.rawValue == "nafnet" && output.generation?.inputs == [source.id])
        #expect(output.rights.rightsClass == .licensed && output.rights.holder == "Stock Co", "rights inherited from the input")
        #expect(output.home?.slug == "launch" && output.tags == ["run:restore"])
        #expect(try library.database.pool.read { db in try String.fetchOne(db, sql: "SELECT assets FROM test_ticket") } == ids[0].rawValue)
        #expect(try library.derivatives(of: source.id).map(\.id) == ids)
    }

    @Test("Another engine's PNG and JPEG bytes are stored as they are")
    func wrapping() throws {
        let pngData = png(makeImage(hue: 0.3))
        let wrappedPNG = try ImageEncoding.wrapping(pngData)
        #expect(wrappedPNG.data == pngData && wrappedPNG.format == .png && wrappedPNG.width == 96 && wrappedPNG.height == 64)
        let jpegData = jpeg(makeImage(hue: 0.3))
        let wrappedJPEG = try ImageEncoding.wrapping(jpegData)
        #expect(wrappedJPEG.data == jpegData && wrappedJPEG.format == .jpeg && !wrappedJPEG.hasAlpha)
    }

    @Test("Re-importing this server's own output doesn't turn its provenance JSON into a caption")
    func provenanceIsNotACaption() throws {
        let library = try makeLibrary()
        let encoded = try ImageEncoding.encode(makeImage(hue: 0.5), as: .png,
                                               provenance: #"{"generator":"mlx-image-server","effective_prompt":"a mug"}"#)
        let asset = try library.importUpload(encoded.data, metadata: UploadMetadata(originalFilename: "mug.png"), origin: .user).asset
        #expect(asset.caption == nil)
    }
}
