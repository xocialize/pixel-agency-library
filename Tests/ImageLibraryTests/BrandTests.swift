import CoreGraphics
import Foundation
@testable import ImageLibrary
import ImageServerAPI
import MLXToolKit
import Testing

func solid(_ r: Double, _ g: Double, _ b: Double, size: Int = 48) -> CGImage {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.setFillColor(CGColor(red: r, green: g, blue: b, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
    return ctx.makeImage()!
}

let acmeManifest = BrandManifest(
    displayName: "Acme 2026",
    colour: BrandColour(palette: BrandPalette(primary: "#FF6600", secondary: "#221100")),
    rules: ["Never place the logo on red."],
    generation: BrandGeneration(stylePrompt: "flat editorial illustration", negativePrompt: "photorealistic"))

@Suite("L2: brand kits")
struct BrandKitTests {
    @Test("Kits are revisioned; a pinned revision keeps its manifest; optimistic revise conflicts")
    func revisions() throws {
        let lib = try makeLibrary()
        let kit = try lib.createBrandKit(company: "acme", name: "Acme 2026", manifest: acmeManifest, createCompany: true)
        #expect(kit.reference == "acme/acme-2026@1")
        var next = acmeManifest
        next.colour?.palette?.primary = "#0055FF"
        let revised = try lib.reviseBrandKit("acme/acme-2026", manifest: next, note: "Blue refresh", expectedRevision: 1)
        #expect(revised.revision == 2 && revised.currentRevision == 2)
        #expect(try lib.brandKit("acme/acme-2026@1")?.manifest.colour?.palette?.primary == "#FF6600")
        #expect(try lib.brandKit(kit.id)?.manifest.colour?.palette?.primary == "#0055FF")
        #expect(try lib.brandKitRevisions(kit.id).map(\.revision) == [2, 1])
        #expect(throws: APIError.self) {
            try lib.reviseBrandKit(kit.id, manifest: acmeManifest, expectedRevision: 1)
        }
    }

    @Test("A project's own kit wins over its client's default")
    func resolution() throws {
        let lib = try makeLibrary()
        let main = try lib.createBrandKit(company: "acme", name: "Main", manifest: acmeManifest, createCompany: true)
        let promo = try lib.createBrandKit(company: "acme", name: "Promo", manifest: BrandManifest())
        let project = try lib.createProject(name: "Summer", company: "acme")
        #expect(try lib.brandKit(forProject: project.id) == nil)
        try lib.setDefaultBrandKit(company: "acme", kit: "acme/main")
        #expect(try lib.brandKit(forProject: project.id)?.resolvedBy == "company")
        #expect(try lib.brandKit(forProject: project.id)?.kit.id == main.id)
        try lib.setProjectBrandKit(project: project.id, kit: promo.id)
        #expect(try lib.brandKit(forProject: project.id)?.resolvedBy == "project")
        #expect(try lib.brandKit(forProject: project.id)?.kit.id == promo.id)
    }

    @Test("Archiving hides a kit from listings and name lookup but keeps it readable")
    func archive() throws {
        let lib = try makeLibrary()
        let kit = try lib.createBrandKit(company: "acme", name: "Old", manifest: acmeManifest, createCompany: true)
        let archived = try lib.archiveBrandKit(kit.id)
        #expect(archived.archivedAt != nil)
        #expect(try lib.brandKits(company: "acme").isEmpty)
        #expect(try lib.brandKit("acme/old") == nil)
        #expect(try lib.brandKit("acme/old", includeArchived: true)?.id == kit.id)
        #expect(try lib.archiveBrandKit(kit.id, archived: false).archivedAt == nil)
    }

    @Test("style.json import: company, kit, client-owned assets with roles, fonts; re-import revises and keeps generation")
    func importStyle() throws {
        let lib = try makeLibrary()
        let style = """
            {"format": "1.1", "company": "globex", "style": "globex-core", "version": 3, "displayName": "Globex",
             "colour": {"palette": {"primary": "#00AEEF", "secondary": "#002244"}, "text": {"onLight": "#111111"}},
             "fonts": {"family": {"name": "Globex Sans", "files": {"web": ["fonts/web/GlobexSans.woff2"]}}},
             "licence": {"holder": "Globex Corp", "scope": "Campaign use"},
             "assets": [{"id": "logo-primary", "file": "assets/logo.png"}, {"id": "bg-texture", "file": "assets/bg.png"}]}
            """
        let files: [String: Data] = [
            "assets/logo.png": png(solid(0, 0.68, 0.94)),
            "bg.png": png(makeImage(hue: 0.6)),   // matched by base name
            "fonts/web/GlobexSans.woff2": Data("wOF2".utf8) + Data(repeating: 0, count: 64),
        ]
        let kit = try lib.importStyle(Data(style.utf8), files: files)
        #expect(kit.reference == "globex/globex-core@1")
        #expect(try lib.company("globex")?.name == "Globex Corp")
        #expect(kit.manifest.colour?.palette?.primary == "#00AEEF")
        let roles = Dictionary(kit.manifest.assets.map { ($0.role, $0) }, uniquingKeysWith: { a, _ in a })
        #expect(Set(roles.keys) == ["logo", "backing", "font"])
        let logoRef = try #require(roles["logo"])
        let logo = try #require(try lib.asset(logoRef.assetID))
        #expect(logo.rights.rightsClass == .clientOwned)
        #expect(logo.rights.holder == "Globex Corp")
        #expect(logo.companySlug == "globex")
        let fontRef = try #require(roles["font"])
        let font = try #require(try lib.asset(fontRef.assetID))
        #expect(font.kind == .font)
        #expect(roles["font"]?.variant == "web")

        // A kit's generation block and rules are not in style.json; a re-import must keep them.
        var withGeneration = kit.manifest
        withGeneration.generation = BrandGeneration(stylePrompt: "clean tech photography")
        withGeneration.rules = ["Blue on white only."]
        _ = try lib.reviseBrandKit(kit.id, manifest: withGeneration)
        let again = try lib.importStyle(Data(style.utf8), files: files)
        #expect(again.revision == 3)
        #expect(again.manifest.generation?.stylePrompt == "clean tech photography")
        #expect(again.manifest.rules == ["Blue on white only."])
    }
}

@Suite("L2: console support")
struct ConsoleSupportTests {
    @Test("languageString is the inverse of parse for every filter (smart collections edit their query as text)")
    func languageRoundTrip() {
        let text = #"red fox "winter light" project:acme/launch client:acme status:approved -status:rejected "#
            + #"usage:social -tag:draft collection:hero-picks source:generated kind:image license:permissive "#
            + #"rights:owned model:z-image-turbo capability:textToImage orient:landscape colour:#ff6600 "#
            + #"expires:soon after:2026-09-01 before:2026-10-01 sort:newest is:inbox"#
        let query = AssetQuery.parse(text)
        let again = AssetQuery.parse(query.languageString)
        #expect(again == query)
        #expect(AssetQuery.parse("tag:\"two words\"").languageString == "tag:\"two words\"")
        #expect(AssetQuery().languageString.isEmpty)
    }

    @Test("A brand folder imports style.json and its files; paths escaping the folder are ignored")
    func folderImport() throws {
        let lib = try makeLibrary()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("brand-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("assets"), withIntermediateDirectories: true)
        try png(solid(1, 0.4, 0)).write(to: root.appendingPathComponent("assets/logo.png"))
        let outside = root.deletingLastPathComponent().appendingPathComponent("outside-\(UUID().uuidString).png")
        try png(solid(0, 0, 1)).write(to: outside)
        let style = """
            {"company": "initech", "style": "core", "colour": {"palette": {"primary": "#FF6600"}},
             "assets": [{"id": "logo", "file": "assets/logo.png"}, {"id": "escape", "file": "../\(outside.lastPathComponent)"}]}
            """
        try Data(style.utf8).write(to: root.appendingPathComponent("style.json"))
        let kit = try lib.importStyle(folder: root)
        #expect(kit.reference == "initech/core@1")
        #expect(kit.manifest.assets.map(\.role) == ["logo"])
        #expect(throws: APIError.self) { try lib.importStyle(folder: root.appendingPathComponent("assets")) }
    }
}

@Suite("L2: collections, colour and expiry search, non-image assets")
struct CollectionSearchTests {
    @Test("Folders hold picks; smart collections are live queries; nesting works; deleting keeps assets")
    func collections() throws {
        let lib = try makeLibrary()
        var ids: [AssetID] = []
        for i in 0..<4 {
            var m = UploadMetadata(name: "pic \(i)")
            m.tags = i < 2 ? ["usage:web"] : ["usage:social"]
            ids.append(try lib.importUpload(png(makeImage(hue: 0.1 + Double(i) * 0.2)), metadata: m, origin: .user).asset.id)
        }
        let folder = try lib.createCollection(name: "Hero picks", kind: .folder)
        try lib.addToCollection([ids[0], ids[3]], collection: folder.slug)
        #expect(try lib.collection(folder.slug)?.assetCount == 2)
        #expect(Set(try lib.search(AssetQuery.parse("collection:hero-picks")).assets.map(\.id)) == [ids[0], ids[3]])

        let smart = try lib.createCollection(name: "All heroes", kind: .smart, query: AssetQuery.parse("usage:web"))
        #expect(smart.assetCount == 2)
        // A smart collection over a folder: heroes that are also picks.
        _ = try lib.createCollection(name: "Picked heroes", kind: .smart,
                                     query: AssetQuery.parse("collection:hero-picks usage:web"))
        #expect(try lib.search(AssetQuery.parse("collection:picked-heroes")).assets.map(\.id) == [ids[0]])
        #expect(throws: APIError.self) { try lib.addToCollection([ids[1]], collection: smart.slug) }

        try lib.removeFromCollection([ids[0]], collection: folder.slug)
        #expect(try lib.collection(folder.slug)?.assetCount == 1)
        try lib.deleteCollection(folder.slug)
        #expect(try lib.asset(ids[3]) != nil)
        #expect(try lib.search(AssetQuery.parse("collection:hero-picks")).total == 0)
    }

    @Test("Colour buckets follow Lab hue (red is red, blue is blue)")
    func buckets() {
        func name(_ r: Double, _ g: Double, _ b: Double) -> String {
            let lab = ImageFacts.lab(r: r, g: g, b: b)
            return ImageFacts.bucket(l: lab.0, a: lab.1, b: lab.2)
        }
        #expect(name(1, 0, 0) == "red")
        #expect(name(1, 0.4, 0) == "orange")
        #expect(name(1, 1, 0) == "yellow")
        #expect(name(0, 0.6, 0) == "green")
        #expect(name(0, 0.5, 0.5) == "teal")
        #expect(name(0, 0, 1) == "blue")
        #expect(name(0.5, 0, 0.5) == "purple")
        #expect(name(1, 0.6, 0.75) == "pink")
        #expect(name(0.55, 0.27, 0.07) == "brown")
        #expect(name(0.5, 0.5, 0.5) == "gray")
    }

    @Test("colour: matches by name or near a hex; the colour facet counts dominant colours")
    func colour() throws {
        let lib = try makeLibrary()
        let orange = try lib.importUpload(png(solid(1, 0.4, 0)), origin: .user).asset.id
        let blue = try lib.importUpload(png(solid(0, 0.2, 0.9)), origin: .user).asset.id
        #expect(try lib.search(AssetQuery.parse("colour:orange")).assets.map(\.id) == [orange])
        #expect(try lib.search(AssetQuery.parse("color:blue")).assets.map(\.id) == [blue])
        #expect(try lib.search(AssetQuery.parse("colour:#FF6A00")).assets.map(\.id) == [orange])
        #expect(try lib.search(AssetQuery.parse("colour:#00FF00")).total == 0)

        // The same orange in shade still matches the hex; a tan of the same hue but low chroma does not.
        let shaded = try lib.importUpload(png(solid(0xBB / 255.0, 0x5B / 255.0, 0x25 / 255.0)), origin: .user).asset.id
        let tan = try lib.importUpload(png(solid(0xC3 / 255.0, 0x81 / 255.0, 0x54 / 255.0)), origin: .user).asset.id
        let hits = Set(try lib.search(AssetQuery.parse("colour:#FF6600")).assets.map(\.id))
        #expect(hits.contains(shaded) && !hits.contains(tan))
        try lib.trash(shaded)
        try lib.trash(tan)
        var q = AssetQuery()
        q.facets = ["colour"]
        let facet = try lib.search(q).facets["colour"] ?? []
        #expect(Set(facet.map(\.value)) == ["orange", "blue"])
    }

    @Test("A small saturated object gets its own palette entry even on a same-lightness background")
    func paletteSeparatesObjects() throws {
        // 80% tan "desk" with an orange "mug" block of similar lightness.
        let size = 64
        let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0xC3 / 255.0, green: 0x81 / 255.0, blue: 0x54 / 255.0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        ctx.setFillColor(CGColor(red: 0.9, green: 0.42, blue: 0.12, alpha: 1))
        ctx.fill(CGRect(x: 20, y: 20, width: 26, height: 26))
        let palette = ImageFacts.palette(of: ctx.makeImage()!)
        #expect(palette.contains { $0.bucket == "orange" && $0.weight > 0.12 })
    }

    @Test("expires: expired / soon / set")
    func expiry() throws {
        let lib = try makeLibrary()
        let past = try lib.importUpload(png(makeImage(hue: 0.2)), metadata: UploadMetadata(
            rights: AssetRights(rightsClass: .licensed, expiresAt: Date().addingTimeInterval(-86400))), origin: .user).asset.id
        let soon = try lib.importUpload(png(makeImage(hue: 0.5)), metadata: UploadMetadata(
            rights: AssetRights(rightsClass: .licensed, expiresAt: Date().addingTimeInterval(10 * 86400))), origin: .user).asset.id
        let later = try lib.importUpload(png(makeImage(hue: 0.8)), metadata: UploadMetadata(
            rights: AssetRights(rightsClass: .licensed, expiresAt: Date().addingTimeInterval(200 * 86400))), origin: .user).asset.id
        _ = try lib.importUpload(png(makeImage(hue: 0.95)), origin: .user)
        #expect(try lib.search(AssetQuery.parse("expires:expired")).assets.map(\.id) == [past])
        #expect(try lib.search(AssetQuery.parse("expires:soon")).assets.map(\.id) == [soon])
        #expect(Set(try lib.search(AssetQuery.parse("expires:set")).assets.map(\.id)) == [past, soon, later])
        var q = AssetQuery()
        q.facets = ["expiry"]
        let counts = Dictionary(uniqueKeysWithValues: (try lib.search(q).facets["expiry"] ?? []).map { ($0.value, $0.count) })
        #expect(counts == ["expired": 1, "soon": 1, "later": 1])
    }

    @Test("PDFs, SVGs and fonts upload as documents, vectors and fonts")
    func nonImage() throws {
        let lib = try makeLibrary()
        let pdf = try lib.importUpload(Data("%PDF-1.7\n%âãÏÓ\n".utf8),
                                       metadata: UploadMetadata(originalFilename: "guidelines.pdf"), origin: .user).asset
        #expect(pdf.kind == .document && pdf.mimeType == "application/pdf")
        let svg = try lib.importUpload(Data(#"<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"/>"#.utf8),
                                       metadata: UploadMetadata(originalFilename: "mark.svg"), origin: .user).asset
        #expect(svg.kind == .vector)
        #expect(try lib.search(AssetQuery.parse("kind:document")).assets.map(\.id) == [pdf.id])
        #expect(throws: APIError.self) {
            try lib.importUpload(Data("not an image at all".utf8), origin: .user)
        }
    }
}
