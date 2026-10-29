import CryptoKit
import Foundation

/// Content-addressed file store: `<root>/blobs/sha256/ab/cd/<hex>.<ext>`.
///
/// Write path (crash-safe ordering): bytes → `<root>/tmp/` (same volume) → hash → rename into place if absent.
/// The database row is written *after* the file exists, so a crash can only leave an orphan file.
public struct BlobStore: Sendable {
    public let root: URL

    public init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: blobsRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
    }

    var blobsRoot: URL { root.appendingPathComponent("blobs/sha256", isDirectory: true) }
    var tmpRoot: URL { root.appendingPathComponent("tmp", isDirectory: true) }

    public struct Stored: Sendable, Equatable {
        /// `sha256:<hex>`
        public let hash: String
        public let bytes: Int64
        public let url: URL
        /// false when identical bytes were already stored.
        public let isNew: Bool
    }

    /// Stores in-memory bytes (engine outputs, decoded uploads).
    public func store(_ data: Data, fileExtension ext: String) throws -> Stored {
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let destination = url(forHex: digest, ext: ext)
        if FileManager.default.fileExists(atPath: destination.path) {
            return Stored(hash: "sha256:" + digest, bytes: Int64(data.count), url: destination, isNew: false)
        }
        let tmp = tmpRoot.appendingPathComponent(UUID().uuidString + "." + ext)
        try data.write(to: tmp, options: .atomic)
        return try moveIntoPlace(tmp: tmp, hex: digest, ext: ext, bytes: Int64(data.count))
    }

    /// Stores a file without reading it into memory (large uploads) — one streaming pass hashes and copies.
    public func store(fileAt source: URL, fileExtension ext: String) throws -> Stored {
        let tmp = tmpRoot.appendingPathComponent(UUID().uuidString + "." + ext)
        let result = try ContentHasher.hash(contentsOf: source, copyingTo: tmp)
        let hex = String(result.contentHash.dropFirst("sha256:".count))
        if FileManager.default.fileExists(atPath: url(forHex: hex, ext: ext).path) {
            try? FileManager.default.removeItem(at: tmp)
            return Stored(hash: result.contentHash, bytes: result.byteSize, url: url(forHex: hex, ext: ext), isNew: false)
        }
        return try moveIntoPlace(tmp: tmp, hex: hex, ext: ext, bytes: result.byteSize)
    }

    public func url(forHash hash: String, ext: String) -> URL {
        url(forHex: String(hash.dropFirst(hash.hasPrefix("sha256:") ? 7 : 0)), ext: ext)
    }

    /// Deletes temp files left by an interrupted write. Run at launch, before the listener starts.
    public func sweepTemporaryFiles() {
        let fm = FileManager.default
        for file in (try? fm.contentsOfDirectory(at: tmpRoot, includingPropertiesForKeys: nil)) ?? [] {
            try? fm.removeItem(at: file)
        }
    }

    private func url(forHex hex: String, ext: String) -> URL {
        let a = String(hex.prefix(2))
        let b = String(hex.dropFirst(2).prefix(2))
        return blobsRoot.appendingPathComponent(a, isDirectory: true)
            .appendingPathComponent(b, isDirectory: true)
            .appendingPathComponent(hex + "." + ext)
    }

    private func moveIntoPlace(tmp: URL, hex: String, ext: String, bytes: Int64) throws -> Stored {
        let destination = url(forHex: hex, ext: ext)
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try fm.moveItem(at: tmp, to: destination)
        } catch {
            // Lost a race with an identical write — the bytes are the same by construction.
            try? fm.removeItem(at: tmp)
            guard fm.fileExists(atPath: destination.path) else { throw error }
            return Stored(hash: "sha256:" + hex, bytes: bytes, url: destination, isNew: false)
        }
        return Stored(hash: "sha256:" + hex, bytes: bytes, url: destination, isNew: true)
    }
}

/// Streaming SHA-256 over a file, producing the content hash and the byte count in a single read pass.
/// Adapted from MarqueeDataKit (same author), re-licensed MIT with this project.
public enum ContentHasher {
    public struct Result: Sendable, Equatable {
        /// `"sha256:<lowercase hex>"` — the prefix keeps records self-describing if the algorithm ever changes.
        public let contentHash: String
        public let byteSize: Int64
    }

    /// Hashes the file at `source`. If `copyingTo` is given, writes the bytes there in the same pass.
    public static func hash(contentsOf source: URL, copyingTo destination: URL? = nil) throws -> Result {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }

        var output: FileHandle?
        if let destination {
            FileManager.default.createFile(atPath: destination.path, contents: nil)
            output = try FileHandle(forWritingTo: destination)
        }
        defer { try? output?.close() }

        var hasher = SHA256()
        var byteSize: Int64 = 0
        while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
            try output?.write(contentsOf: chunk)
            byteSize += Int64(chunk.count)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return Result(contentHash: "sha256:\(digest)", byteSize: byteSize)
    }
}
