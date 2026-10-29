import Foundation
import GRDB
import ImageServerAPI
import MLXToolKit

/// What a vision model wrote for one asset, parsed, before it is stored.
public struct DescriptionDraft: Sendable, Equatable {
    public var caption: String?
    public var altText: String?
    public var tags: [String]
    /// The model's reply as it came back.
    public var raw: String

    public init(caption: String?, altText: String?, tags: [String], raw: String) {
        self.caption = caption
        self.altText = altText
        self.tags = tags
        self.raw = raw
    }
}

/// Descriptions (auto-describe, Docs/CMS-ROADMAP.md L2). Every description is kept with the model and licence that
/// wrote it; applying one fills an empty caption / alt text and replaces earlier auto tags. What a person typed is
/// only replaced when the caller asks (`overwrite`), and their tags never are.
extension AssetLibrary {
    /// Records `draft` for `asset` and applies it. Runs inside the describe job's success transaction.
    public static func recordDescription(_ draft: DescriptionDraft, asset: String, jobID: String?, model: String,
                                  licenseClass: LicenseClass, overwrite: Bool, at date: Date, in db: Database) throws {
        guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM asset WHERE id = ? AND trashed_at IS NULL)",
                                arguments: [asset]) == true else {
            throw APIError.notFound("Asset \(asset) was removed before its description finished.")
        }
        let tags = autoTags(draft.tags)
        let tagsJSON = String(decoding: try JSONEncoder().encode(tags), as: UTF8.self)
        try db.execute(sql: """
            INSERT INTO asset_description(asset_id, job_id, model_id, license_class, caption, alt_text, tags_json,
                raw_text, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [asset, jobID, model, licenseClass.rawValue, draft.caption, draft.altText, tagsJSON,
                             draft.raw, date])
        try db.execute(sql: """
            UPDATE asset SET
                caption = CASE WHEN ?1 IS NOT NULL AND (?3 OR caption IS NULL OR caption = '') THEN ?1 ELSE caption END,
                alt_text = CASE WHEN ?2 IS NOT NULL AND (?3 OR alt_text IS NULL OR alt_text = '') THEN ?2 ELSE alt_text END,
                revision = revision + 1, updated_at = ?4
            WHERE id = ?5
            """, arguments: [draft.caption, draft.altText, overwrite, date, asset])
        try db.execute(sql: "DELETE FROM asset_tag WHERE asset_id = ? AND origin = ?",
                       arguments: [asset, TagOrigin.auto.rawValue])
        for tag in tags {
            // A word the vocabulary refuses (a reserved namespace, say) is dropped, not a failed description.
            _ = try? attach(tag: tag, to: asset, origin: .auto, sourceRef: jobID, in: db)
        }
    }

    static func latestDescription(_ asset: String, in db: Database) throws -> AssetDescription? {
        guard let row = try Row.fetchOne(db, sql: """
            SELECT * FROM asset_description WHERE asset_id = ? ORDER BY id DESC LIMIT 1
            """, arguments: [asset]) else { return nil }
        let tags = (row["tags_json"] as String?).flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) }
        return AssetDescription(
            model: ModelID(row["model_id"] as String),
            licenseClass: LicenseClass(rawValue: row["license_class"] ?? "") ?? .restricted,
            caption: row["caption"], altText: row["alt_text"], tags: tags ?? [],
            jobID: (row["job_id"] as String?).map { JobID(rawValue: $0) }, createdAt: row["created_at"])
    }

    /// Plain keywords only: lowercased, no namespaces (a model writing `usage:web` must not file anything), no
    /// hashtags, at most 40 characters and 12 tags.
    public static func autoTags(_ raw: [String]) -> [String] {
        var seen = Set<String>()
        return raw.compactMap { tag -> String? in
            let word = tag.replacingOccurrences(of: ":", with: " ").replacingOccurrences(of: "#", with: "")
                .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
                .lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".,;\"'"))
            guard !word.isEmpty, word.count <= 40, seen.insert(word).inserted else { return nil }
            return word
        }
        .prefix(12).map { $0 }
    }
}
