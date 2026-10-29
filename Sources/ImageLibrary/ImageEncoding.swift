import CoreGraphics
import Foundation
import ImageIO
import ImageServerAPI
import UniformTypeIdentifiers

/// ImageIO encode/decode for the library. Provenance rides inside the file as well as in the database, so an image
/// that leaves the library still says which model (and which licence) made it.
public enum ImageEncoding {
    public enum CodingError: Error { case encodeFailed, decodeFailed }

    public struct Encoded: Sendable {
        public let data: Data
        public let format: OutputFormat
        public let width: Int
        public let height: Int
        public let hasAlpha: Bool
    }

    /// Encodes `image`. `provenance` (a JSON string) goes into the PNG Description / TIFF ImageDescription.
    /// A JPEG cannot carry alpha, so an image with alpha is always written as PNG regardless of `format`.
    public static func encode(_ image: CGImage, as format: OutputFormat, provenance: String?, jpegQuality: Double = 0.92) throws -> Encoded {
        let alpha = hasAlpha(image)
        let actual: OutputFormat = alpha ? .png : format
        let type = actual == .png ? UTType.png : UTType.jpeg
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            throw CodingError.encodeFailed
        }
        var props: [CFString: Any] = [:]
        if actual == .jpeg { props[kCGImageDestinationLossyCompressionQuality] = jpegQuality }
        if let provenance {
            if actual == .png {
                props[kCGImagePropertyPNGDictionary] = [
                    kCGImagePropertyPNGDescription: provenance,
                    kCGImagePropertyPNGSoftware: "ML[X] Image Server",
                ] as [CFString: Any]
            } else {
                props[kCGImagePropertyTIFFDictionary] = [
                    kCGImagePropertyTIFFImageDescription: provenance,
                    kCGImagePropertyTIFFSoftware: "ML[X] Image Server",
                ] as [CFString: Any]
            }
        }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw CodingError.encodeFailed }
        return Encoded(data: data as Data, format: actual, width: image.width, height: image.height, hasAlpha: alpha)
    }

    public static func decode(_ data: Data) throws -> CGImage {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { throw CodingError.decodeFailed }
        return image
    }

    /// Bytes another engine already encoded (an MES output), kept as they are when they're PNG or JPEG; anything else
    /// is decoded and stored as PNG.
    public static func wrapping(_ data: Data) throws -> Encoded {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
              let uti = CGImageSourceGetType(src) as String? else { throw CodingError.decodeFailed }
        let alpha = props[kCGImagePropertyHasAlpha] as? Bool ?? false
        switch UTType(uti) {
        case .png?: return Encoded(data: data, format: .png, width: w, height: h, hasAlpha: alpha)
        case .jpeg?: return Encoded(data: data, format: .jpeg, width: w, height: h, hasAlpha: false)
        default: return try encode(try decode(data), as: .png, provenance: nil)
        }
    }

    /// Dimensions and MIME type without decoding pixels.
    public static func probe(_ data: Data) -> (width: Int, height: Int, mime: String)? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int,
              let uti = CGImageSourceGetType(src) as String?,
              let mime = UTType(uti)?.preferredMIMEType else { return nil }
        return (w, h, mime)
    }

    public static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: false
        default: true
        }
    }

    /// Downscaled preview (long edge ≤ `maxPixel`) for MCP image blocks and thumbnails. JPEG unless the source has alpha.
    public static func preview(of data: Data, maxPixel: Int, jpegQuality: Double = 0.85) throws -> (data: Data, mime: String) {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { throw CodingError.decodeFailed }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else {
            throw CodingError.decodeFailed
        }
        let encoded = try encode(thumb, as: .jpeg, provenance: nil, jpegQuality: jpegQuality)
        return (encoded.data, encoded.format.mimeType)
    }
}

/// On-disk thumbnail cache keyed by content hash and size — purgeable at any time.
public struct ThumbnailCache: Sendable {
    public let root: URL
    public static let sizes = [256, 512, 1024]

    public init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// Returns the cached thumbnail, generating it on first request.
    public func thumbnail(forBlobAt source: URL, hash: String, size: Int) throws -> (url: URL, mime: String) {
        let size = Self.sizes.min(by: { abs($0 - size) < abs($1 - size) }) ?? 512
        let hex = hash.hasPrefix("sha256:") ? String(hash.dropFirst(7)) : hash
        for (ext, mime) in [("jpg", "image/jpeg"), ("png", "image/png")] {
            let candidate = root.appendingPathComponent("\(hex)_\(size).\(ext)")
            if FileManager.default.fileExists(atPath: candidate.path) { return (candidate, mime) }
        }
        let preview = try ImageEncoding.preview(of: try Data(contentsOf: source), maxPixel: size)
        let ext = preview.mime == "image/png" ? "png" : "jpg"
        let url = root.appendingPathComponent("\(hex)_\(size).\(ext)")
        try preview.data.write(to: url, options: .atomic)
        return (url, preview.mime)
    }
}
