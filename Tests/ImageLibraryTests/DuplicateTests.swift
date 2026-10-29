import CoreGraphics
import Foundation
@testable import ImageLibrary
import ImageServerAPI
import Testing

func bars(width: Int, height: Int, period: Int = 12) -> CGImage {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    for x in stride(from: 0, to: width, by: period) {
        let light = (x / period) % 2 == 0
        ctx.setFillColor(CGColor(red: light ? 0.9 : 0.1, green: light ? 0.9 : 0.2, blue: light ? 0.8 : 0.3, alpha: 1))
        ctx.fill(CGRect(x: x, y: 0, width: period, height: height))
    }
    return ctx.makeImage()!
}

@Suite("L2: near-duplicates")
struct DuplicateTests {
    /// The same picture three ways — an inbox upload, the same bytes filed in a project, a smaller JPEG — and an
    /// unrelated image.
    func fixture() throws -> (lib: AssetLibrary, inbox: AssetID, filed: AssetID, small: AssetID, other: AssetID) {
        let lib = try makeLibrary()
        let picture = makeImage(width: 96, height: 64, hue: 0.1)
        let original = png(picture)
        let inbox = try lib.importUpload(original, metadata: UploadMetadata(name: "inbox copy"), origin: .user).asset.id
        let project = try lib.createProject(name: "Launch", company: "acme", createCompany: true)
        let filed = try lib.importUpload(original, metadata: UploadMetadata(project: project.id), origin: .user).asset.id
        let small = try lib.importUpload(jpeg(scaled(picture, to: 48, 32), quality: 0.7),
                                         metadata: UploadMetadata(caption: "Hero candidate", tags: ["hero"]),
                                         origin: .user).asset.id
        // Structurally different (vertical bars): two smooth diagonal gradients can sit right at the threshold,
        // because a perceptual hash reads brightness structure, not hue.
        let other = try lib.importUpload(png(bars(width: 96, height: 64)), origin: .user).asset.id
        return (lib, inbox, filed, small, other)
    }

    @Test("similar(to:) lists identical bytes first, then perceptual neighbours, never unrelated images")
    func similar() throws {
        let f = try fixture()
        let found = try f.lib.similar(to: f.inbox)
        #expect(found.map(\.asset.id) == [f.filed, f.small])
        #expect(found[0].sameBytes && found[0].distance == 0)
        #expect(!found[1].sameBytes && found[1].distance <= AssetLibrary.nearDuplicateDistance)
    }

    @Test("Groups are transitive; the keeper is the largest, then the one filed in a project")
    func groups() throws {
        let f = try fixture()
        let groups = try f.lib.duplicateGroups()
        #expect(groups.count == 1)
        let group = try #require(groups.first)
        #expect(Set(group.members.map(\.asset.id)) == [f.inbox, f.filed, f.small])
        #expect(group.suggestedKeep == f.filed, "already filed in a project")
        #expect(Set(group.suggestedTrash) == [f.inbox, f.small], "plain copies, no versions among them")
        #expect(group.members.first?.asset.id == f.filed)
        // Scoped to a search: only images in that project → no pair left.
        #expect(try f.lib.duplicateGroups(in: AssetQuery.parse("project:launch")).isEmpty)
    }

    @Test("Not duplicates: dismissed pairs leave groups and similar lists")
    func dismiss() throws {
        let f = try fixture()
        try f.lib.dismissDuplicates([f.inbox, f.filed, f.small])
        #expect(try f.lib.duplicateGroups().isEmpty)
        #expect(try f.lib.similar(to: f.inbox).isEmpty)
        #expect(throws: APIError.self) { try f.lib.dismissDuplicates([f.inbox]) }
    }

    @Test("Resolving keeps one, carries the others' filing over, and trashes them (restorable)")
    func resolve() throws {
        let f = try fixture()
        let folder = try f.lib.createCollection(name: "Picks", kind: .folder)
        try f.lib.addToCollection([f.small], collection: folder.id)
        let result = try f.lib.resolveDuplicates(keep: f.filed, trash: [f.inbox, f.small, f.filed])
        #expect(Set(result.trashed) == [f.inbox, f.small], "the keeper is never trashed, even if listed")
        #expect(result.mergedTags >= 1 && result.mergedCollections == 1)
        #expect(result.filledFields.contains("caption") && result.filledFields.contains("name"))
        let kept = try #require(try f.lib.asset(f.filed))
        #expect(kept.tags.contains("hero"))
        #expect(kept.caption == "Hero candidate")
        #expect(kept.home?.slug == "launch", "the keeper's own home stays")
        #expect(try f.lib.collection(folder.id)?.assetCount == 1)
        #expect(try f.lib.asset(f.small) == nil && f.lib.asset(f.inbox) == nil)
        try f.lib.restore(f.small)
        #expect(try f.lib.asset(f.small) != nil)
    }

    @Test("An asset a brand kit uses is not trashed")
    func brandGuard() throws {
        let f = try fixture()
        _ = try f.lib.createBrandKit(company: "acme", name: "Acme", manifest: BrandManifest(
            assets: [BrandAssetRef(assetID: f.small, role: "logo")]))
        #expect(throws: APIError.self) { try f.lib.resolveDuplicates(keep: f.filed, trash: [f.small]) }
        #expect(try f.lib.asset(f.small) != nil)
    }
}
