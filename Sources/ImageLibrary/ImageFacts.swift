import CoreGraphics
import Foundation
import ImageIO
import ImageServerAPI
import UniformTypeIdentifiers

/// Facts about a blob's bytes, computed once per content hash at upload (≈10–30 ms): type, dimensions, alpha,
/// a 64-bit perceptual hash for near-duplicate detection, a 5-colour palette, and embedded metadata.
public struct ImageFacts: Sendable {
    public var mime: String
    public var fileExtension: String
    public var kind: AssetKind
    public var width: Int?
    public var height: Int?
    public var hasAlpha: Bool
    /// dHash bit pattern (64 bits, stored signed).
    public var phash: Int64?
    public var palette: [PaletteEntry]
    /// EXIF / IPTC / TIFF / PNG text as JSON, GPS removed.
    public var metadataJSON: String?
    public var iptc: IPTCFields

    public struct PaletteEntry: Sendable, Equatable {
        public var hex: String
        public var l: Double
        public var a: Double
        public var b: Double
        public var weight: Double
        public var bucket: String
    }

    /// Bump when the facts computed here change, so a background pass can refresh older blobs.
    /// 2: six-colour palettes with farthest-point seeding (v1 seeded along lightness only, so a mid-tone object
    /// merged into a same-lightness background — an orange mug vanished into a walnut desk).
    public static let version = 2

    /// Image facts, or — for the non-raster files brand kits carry (fonts, PDF guidelines, SVG marks) — just their
    /// type. Anything else is refused.
    public static func compute(_ data: Data, filename: String?) throws -> ImageFacts {
        // Magic bytes first: ImageIO happily rasterises a PDF, which would file brand guidelines as an image.
        if let other = nonImage(data, filename: nil) { return other }
        if let image = try? compute(data) { return image }
        if let other = nonImage(data, filename: filename) { return other }
        throw APIError.unprocessable("input_unresolvable",
                                     "The file is not a recognisable image, font, PDF or SVG.")
    }

    static func nonImage(_ data: Data, filename: String?) -> ImageFacts? {
        let ext = filename.map { ($0 as NSString).pathExtension.lowercased() } ?? ""
        let head = data.prefix(512)
        let text = String(decoding: head, as: UTF8.self)
        func facts(_ kind: AssetKind, _ mime: String, _ ext: String) -> ImageFacts {
            ImageFacts(mime: mime, fileExtension: ext, kind: kind, width: nil, height: nil, hasAlpha: false, phash: nil,
                       palette: [], metadataJSON: nil, iptc: IPTCFields())
        }
        if head.starts(with: Data("%PDF".utf8)) || ext == "pdf" { return facts(.document, "application/pdf", "pdf") }
        if ext == "svg" || text.contains("<svg") { return facts(.vector, "image/svg+xml", "svg") }
        let magic = [UInt8](head.prefix(4))
        if ext == "woff2" || magic == Array("wOF2".utf8) { return facts(.font, "font/woff2", "woff2") }
        if ext == "woff" || magic == Array("wOFF".utf8) { return facts(.font, "font/woff", "woff") }
        if ext == "otf" || magic == Array("OTTO".utf8) { return facts(.font, "font/otf", "otf") }
        if ext == "ttf" || magic == [0, 1, 0, 0] || magic == Array("true".utf8) { return facts(.font, "font/ttf", "ttf") }
        return nil
    }

    public static func compute(_ data: Data) throws -> ImageFacts {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let uti = CGImageSourceGetType(source) as String?,
              let type = UTType(uti) else {
            throw APIError.unprocessable("input_unresolvable", "The file is not a recognisable image.")
        }
        let props = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
        let width = props[kCGImagePropertyPixelWidth] as? Int
        let height = props[kCGImagePropertyPixelHeight] as? Int
        let declaredAlpha = props[kCGImagePropertyHasAlpha] as? Bool

        var metadata: [String: Any] = [:]
        for (key, name) in [(kCGImagePropertyExifDictionary, "exif"), (kCGImagePropertyIPTCDictionary, "iptc"),
                            (kCGImagePropertyTIFFDictionary, "tiff"), (kCGImagePropertyPNGDictionary, "png")] {
            if let dict = props[key] as? [CFString: Any] {
                metadata[name] = jsonSafe(dict)
            }
        }
        // GPS is deliberately dropped: location never leaves the machine via this library.

        let iptc = IPTCFields(props: props)
        let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 64,
        ] as CFDictionary)

        let hasAlpha = declaredAlpha ?? thumb.map(ImageEncoding.hasAlpha) ?? false
        return ImageFacts(
            mime: type.preferredMIMEType ?? "application/octet-stream",
            fileExtension: type.preferredFilenameExtension ?? "img",
            kind: .image, width: width, height: height, hasAlpha: hasAlpha,
            phash: thumb.flatMap(differenceHash), palette: thumb.map { palette(of: $0) } ?? [],
            metadataJSON: (try? JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys]))
                .map { String(decoding: $0, as: UTF8.self) },
            iptc: iptc)
    }

    /// dHash: 9×8 grayscale, one bit per horizontal neighbour comparison. Robust to scaling and recompression.
    static func differenceHash(_ image: CGImage) -> Int64? {
        let w = 9, h = 8
        var pixels = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var bits: UInt64 = 0
        for y in 0..<h {
            for x in 0..<(w - 1) {
                bits <<= 1
                if pixels[y * w + x] > pixels[y * w + x + 1] { bits |= 1 }
            }
        }
        return Int64(bitPattern: bits)
    }

    /// Up to six dominant colours by k-means in Lab space over a 64 px downsample (alpha-weighted).
    static func palette(of image: CGImage, k: Int = 6) -> [PaletteEntry] {
        let w = max(1, min(64, image.width)), h = max(1, min(64, image.height))
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &rgba, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return [] }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        var points: [(l: Double, a: Double, b: Double, weight: Double)] = []
        points.reserveCapacity(w * h)
        for i in stride(from: 0, to: rgba.count, by: 4) {
            let alpha = Double(rgba[i + 3]) / 255
            guard alpha > 0.1 else { continue }
            let lab = Self.lab(r: Double(rgba[i]) / 255 / alpha, g: Double(rgba[i + 1]) / 255 / alpha,
                               b: Double(rgba[i + 2]) / 255 / alpha)
            points.append((lab.0, lab.1, lab.2, alpha))
        }
        guard !points.isEmpty else { return [] }

        // Deterministic farthest-point seeding: start at the median-lightness pixel, then repeatedly take the pixel
        // farthest from every seed so far, so a distinct hue gets a centroid even when it shares a background's
        // lightness. A seed that lands on a stray highlight ends up tiny and is filtered below.
        let sorted = points.sorted { $0.l < $1.l }
        var centroids = [(sorted[sorted.count / 2].l, sorted[sorted.count / 2].a, sorted[sorted.count / 2].b)]
        var nearest = points.map { p in
            (p.l - centroids[0].0) * (p.l - centroids[0].0) + (p.a - centroids[0].1) * (p.a - centroids[0].1)
                + (p.b - centroids[0].2) * (p.b - centroids[0].2)
        }
        while centroids.count < min(k, points.count), let far = nearest.indices.max(by: { nearest[$0] < nearest[$1] }),
              nearest[far] > 1 {
            let c = (points[far].l, points[far].a, points[far].b)
            centroids.append(c)
            for (i, p) in points.enumerated() {
                let d = (p.l - c.0) * (p.l - c.0) + (p.a - c.1) * (p.a - c.1) + (p.b - c.2) * (p.b - c.2)
                if d < nearest[i] { nearest[i] = d }
            }
        }
        var assignment = [Int](repeating: 0, count: points.count)
        for _ in 0..<12 {
            for (i, p) in points.enumerated() {
                var best = 0, bestD = Double.infinity
                for (j, c) in centroids.enumerated() {
                    let d = (p.l - c.0) * (p.l - c.0) + (p.a - c.1) * (p.a - c.1) + (p.b - c.2) * (p.b - c.2)
                    if d < bestD { bestD = d; best = j }
                }
                assignment[i] = best
            }
            var sums = [(Double, Double, Double, Double)](repeating: (0, 0, 0, 0), count: centroids.count)
            for (i, p) in points.enumerated() {
                let j = assignment[i]
                sums[j] = (sums[j].0 + p.l * p.weight, sums[j].1 + p.a * p.weight, sums[j].2 + p.b * p.weight,
                           sums[j].3 + p.weight)
            }
            for j in centroids.indices where sums[j].3 > 0 {
                centroids[j] = (sums[j].0 / sums[j].3, sums[j].1 / sums[j].3, sums[j].2 / sums[j].3)
            }
        }
        var weights = [Double](repeating: 0, count: centroids.count)
        for (i, p) in points.enumerated() { weights[assignment[i]] += p.weight }
        let total = weights.reduce(0, +)
        return centroids.indices
            .map { j in
                let c = centroids[j]
                return PaletteEntry(hex: hex(lab: c), l: c.0, a: c.1, b: c.2, weight: total > 0 ? weights[j] / total : 0,
                                    bucket: bucket(l: c.0, a: c.1, b: c.2))
            }
            .filter { $0.weight > 0.005 }
            .sorted { $0.weight > $1.weight }
    }

    /// A coarse colour name for facet filtering: neutrals by lightness, chromatic colours by hue.
    /// `#FF6600` → `orange`: the search bucket, for prompts (models read colour words better than hex codes).
    public static func colourName(hex: String) -> String? {
        guard let lab = SearchPlan.lab(hex: hex) else { return nil }
        return bucket(l: lab.0, a: lab.1, b: lab.2)
    }

    /// A colour name for search (`colour:orange`). Ranges are CIE Lab hue angles, which are not HSV's: sRGB red
    /// sits at 40°, orange ~55°, yellow ~100°, green ~135°, cyan ~195°, blue ~305°, magenta ~330°.
    static func bucket(l: Double, a: Double, b: Double) -> String {
        let chroma = (a * a + b * b).squareRoot()
        if chroma < 10 { return l < 20 ? "black" : (l > 85 ? "white" : "gray") }
        var hue = atan2(b, a) * 180 / .pi
        if hue < 0 { hue += 360 }
        // Dark, muted warm hues read as brown, not dark orange.
        if (10..<80).contains(hue), l < 50, chroma < 60 { return "brown" }
        switch hue {
        case 10..<48: return "red"
        case 48..<75: return "orange"
        case 75..<115: return "yellow"
        case 115..<175: return "green"
        case 175..<230: return "teal"
        case 230..<310: return "blue"
        case 310..<340: return "purple"
        default: return "pink"
        }
    }

    // MARK: - Colour math (sRGB D65 ↔ CIE Lab)

    static func lab(r: Double, g: Double, b: Double) -> (Double, Double, Double) {
        func lin(_ c: Double) -> Double { let c = min(1, max(0, c)); return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let (R, G, B) = (lin(r), lin(g), lin(b))
        let x = (0.4124 * R + 0.3576 * G + 0.1805 * B) / 0.95047
        let y = (0.2126 * R + 0.7152 * G + 0.0722 * B)
        let z = (0.0193 * R + 0.1192 * G + 0.9505 * B) / 1.08883
        func f(_ t: Double) -> Double { t > 0.008856 ? cbrt(t) : 7.787 * t + 16.0 / 116 }
        return (116 * f(y) - 16, 500 * (f(x) - f(y)), 200 * (f(y) - f(z)))
    }

    static func hex(lab: (Double, Double, Double)) -> String {
        let fy = (lab.0 + 16) / 116, fx = fy + lab.1 / 500, fz = fy - lab.2 / 200
        func inv(_ t: Double) -> Double { t * t * t > 0.008856 ? t * t * t : (t - 16.0 / 116) / 7.787 }
        let x = inv(fx) * 0.95047, y = inv(fy), z = inv(fz) * 1.08883
        func gamma(_ c: Double) -> Int {
            let c = c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055
            return Int((min(1, max(0, c)) * 255).rounded())
        }
        let r = gamma(3.2406 * x - 1.5372 * y - 0.4986 * z)
        let g = gamma(-0.9689 * x + 1.8758 * y + 0.0415 * z)
        let b = gamma(0.0557 * x - 0.2040 * y + 1.0570 * z)
        return String(format: "#%02x%02x%02x", r, g, b)
    }

    /// CoreFoundation property dictionaries → JSON-serializable values.
    static func jsonSafe(_ value: Any) -> Any {
        switch value {
        case let dict as [CFString: Any]:
            var out: [String: Any] = [:]
            for (k, v) in dict { out[k as String] = jsonSafe(v) }
            return out
        case let dict as [String: Any]:
            return dict.mapValues(jsonSafe)
        case let array as [Any]:
            return array.map(jsonSafe)
        case let n as NSNumber:
            return n
        case let s as String:
            return s
        case let d as Data:
            return d.base64EncodedString()
        default:
            return String(describing: value)
        }
    }
}

/// The IPTC fields the library imports. Imported values fill gaps only — never overriding what a caller supplied —
/// and imported rights are suggestions (`rights_source: import`), not facts.
public struct IPTCFields: Sendable, Equatable {
    public var objectName: String?
    public var caption: String?
    public var keywords: [String]
    public var byline: String?
    public var credit: String?
    public var copyright: String?
    public var usageTerms: String?

    init() {
        keywords = []
    }

    init(props: [CFString: Any]) {
        let iptc = props[kCGImagePropertyIPTCDictionary] as? [CFString: Any] ?? [:]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        func string(_ v: Any?) -> String? {
            if let s = v as? String { return s.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty }
            if let a = v as? [String] { return a.joined(separator: ", ").nilIfEmpty }
            return nil
        }
        objectName = string(iptc[kCGImagePropertyIPTCObjectName])
        // Our own provenance JSON (PNG Description, which ImageIO also reports as the IPTC caption) is not a caption.
        caption = (string(iptc[kCGImagePropertyIPTCCaptionAbstract]) ?? string(tiff[kCGImagePropertyTIFFImageDescription]))
            .flatMap { $0.hasPrefix("{") ? nil : $0 }
        keywords = (iptc[kCGImagePropertyIPTCKeywords] as? [String] ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        byline = string(iptc[kCGImagePropertyIPTCByline]) ?? string(tiff[kCGImagePropertyTIFFArtist])
        credit = string(iptc[kCGImagePropertyIPTCCredit])
        copyright = string(iptc[kCGImagePropertyIPTCCopyrightNotice]) ?? string(tiff[kCGImagePropertyTIFFCopyright])
        usageTerms = string(iptc[kCGImagePropertyIPTCRightsUsageTerms])
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
