import Foundation
import GRDB
import ImageServerAPI

/// Near-duplicates (Docs/CMS-ROADMAP.md, L2). Two images are the same picture when their bytes are identical or their
/// 64-bit perceptual hashes (dHash) differ by at most `nearDuplicateDistance` bits. Groups are transitive (A≈B, B≈C
/// puts all three together) and skip pairs someone marked "not duplicates".
extension AssetLibrary {
    /// dHash bits that still mean "the same picture": survives resizing, recompression and small crops.
    public static let nearDuplicateDistance = 6

    /// Images that look like `id`, closest first: identical bytes, then perceptual-hash neighbours within
    /// `maxDistance` bits. Pairs marked "not duplicates" are left out.
    public func similar(to id: AssetID, maxDistance: Int = nearDuplicateDistance, limit: Int = 24) throws -> [SimilarAsset] {
        try database.pool.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT a.blob_hash, b.phash FROM asset a JOIN blob b ON b.hash = a.blob_hash
                WHERE a.id = ? AND a.trashed_at IS NULL
                """, arguments: [id.rawValue]) else { throw APIError.notFound("No asset \(id).") }
            let hash: String = row["blob_hash"]
            let phash: Int64? = row["phash"]
            let rows = try Row.fetchAll(db, sql: """
                SELECT a.id, a.blob_hash, b.phash FROM asset a JOIN blob b ON b.hash = a.blob_hash
                WHERE a.id <> ?1 AND a.trashed_at IS NULL
                  AND (a.blob_hash = ?2 OR (?3 IS NOT NULL AND b.phash IS NOT NULL AND hamming(b.phash, ?3) <= ?4))
                  AND NOT EXISTS (SELECT 1 FROM asset_distinct d
                                  WHERE (d.a = ?1 AND d.b = a.id) OR (d.a = a.id AND d.b = ?1))
                """, arguments: [id.rawValue, hash, phash, maxDistance])
            let target = try Self.info(id.rawValue, in: db)
            let targetInputs = Set(target?.generation?.inputs ?? [])
            return try rows.compactMap { r -> SimilarAsset? in
                let same = (r["blob_hash"] as String) == hash
                let distance = same ? 0 : Self.distance(phash, r["phash"])
                guard let info = try Self.info(r["id"], in: db) else { return nil }
                let version = targetInputs.contains(info.id) || (info.generation?.inputs.contains(id) ?? false)
                return SimilarAsset(asset: info, distance: distance, sameBytes: same, isVersion: version)
            }
            .sorted { ($0.distance, $0.asset.id.rawValue) < ($1.distance, $1.asset.id.rawValue) }
            .prefix(limit).map { $0 }
        }
    }

    /// Duplicate groups among images matching `query` (nil = the whole library), largest groups first.
    /// With `includeVersions: false` (the default), groups made only of versions of one another (an image and its
    /// upscale, say) are left out: there is nothing in them to tidy.
    public func duplicateGroups(in query: AssetQuery? = nil, maxDistance: Int = nearDuplicateDistance,
                                includeVersions: Bool = false, limit: Int = 100) throws -> [DuplicateGroup] {
        try database.pool.read { db in
            var sql = """
                SELECT a.id, a.blob_hash, b.phash FROM asset a JOIN blob b ON b.hash = a.blob_hash
                WHERE a.trashed_at IS NULL AND a.kind IN ('image', 'matte')
                """
            var args: [(any DatabaseValueConvertible)?] = []
            if let query {
                let plan = try SearchPlan(query: query, db: db).fromValues(excluding: nil)
                sql += " AND a.id IN (SELECT a.id \(plan.sql))"
                args = plan.values
            }
            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
            let ids: [String] = rows.map { $0["id"] }
            let hashes: [String] = rows.map { $0["blob_hash"] }
            let phashes: [Int64?] = rows.map { $0["phash"] }
            var dismissed = Set<String>()
            for d in try Row.fetchAll(db, sql: "SELECT a, b FROM asset_distinct") {
                dismissed.insert("\(d["a"] as String)|\(d["b"] as String)")
            }
            func isDismissed(_ i: Int, _ j: Int) -> Bool {
                let (x, y) = ids[i] < ids[j] ? (ids[i], ids[j]) : (ids[j], ids[i])
                return dismissed.contains("\(x)|\(y)")
            }

            // Union-find over every close pair. O(n²) popcounts: ~50 M for 10k images, well under a second.
            var parent = Array(rows.indices)
            func find(_ i: Int) -> Int {
                var i = i
                while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }
                return i
            }
            for i in rows.indices {
                for j in (i + 1)..<rows.count {
                    let close = hashes[i] == hashes[j] || Self.distance(phashes[i], phashes[j]) <= maxDistance
                    if close, !isDismissed(i, j) { parent[find(i)] = find(j) }
                }
            }
            var clusters: [Int: [Int]] = [:]
            for i in rows.indices { clusters[find(i), default: []].append(i) }

            var groups: [DuplicateGroup] = []
            for members in clusters.values where members.count > 1 {
                let infos = try members.compactMap { index in try Self.info(ids[index], in: db).map { info in (info, index) } }
                guard infos.count > 1 else { continue }
                // Lineage inside the group: made from another member, or another member was made from it.
                let memberIDs = Set(infos.map(\.0.id))
                let derived = Set(infos.filter { !Set($0.0.generation?.inputs ?? []).isDisjoint(with: memberIDs) }.map(\.0.id))
                let sources = Set(infos.flatMap { $0.0.generation?.inputs ?? [] }).intersection(memberIDs)
                let versions = derived.union(sources)
                // Keep: filed in a project, then an original over a version made from it, then most pixels, then oldest.
                let keeper = infos.max { a, b in
                    if (a.0.home != nil) != (b.0.home != nil) { return a.0.home == nil }
                    if derived.contains(a.0.id) != derived.contains(b.0.id) { return derived.contains(a.0.id) }
                    let pa = (a.0.width ?? 0) * (a.0.height ?? 0), pb = (b.0.width ?? 0) * (b.0.height ?? 0)
                    if pa != pb { return pa < pb }
                    return a.0.createdAt > b.0.createdAt
                }!
                let similar = infos.map { info, index in
                    SimilarAsset(asset: info,
                                 distance: hashes[index] == hashes[keeper.1] ? 0 : Self.distance(phashes[index], phashes[keeper.1]),
                                 sameBytes: hashes[index] == hashes[keeper.1], isVersion: versions.contains(info.id))
                }
                .sorted { a, b in
                    if a.asset.id == keeper.0.id { return true }
                    if b.asset.id == keeper.0.id { return false }
                    return (a.distance, a.asset.id.rawValue) < (b.distance, b.asset.id.rawValue)
                }
                let trash = similar.filter { $0.asset.id != keeper.0.id && !$0.isVersion }.map(\.asset.id)
                if trash.isEmpty && !includeVersions { continue }
                groups.append(DuplicateGroup(suggestedKeep: keeper.0.id, suggestedTrash: trash, members: similar))
            }
            return groups.sorted { ($0.members.count, $0.suggestedKeep.rawValue) > ($1.members.count, $1.suggestedKeep.rawValue) }
                .prefix(limit).map { $0 }
        }
    }

    /// Keeps `keep` and trashes `trash` (restorable). With `mergeFiling`, the keeper first takes over what the others
    /// carry: people's tags, project memberships (and a home, if it has none), folder memberships, and any text field
    /// it has empty. Rights are never merged. An asset a brand kit uses cannot be trashed.
    public func resolveDuplicates(keep: AssetID, trash: [AssetID], mergeFiling: Bool = true) throws -> DuplicateResolution {
        let others = Array(Set(trash.map(\.rawValue)).subtracting([keep.rawValue])).sorted()
        guard !others.isEmpty else {
            throw APIError.badRequest("missing_parameter", "Name at least one asset to trash besides the keeper.",
                                      param: "trash")
        }
        return try database.pool.write { db in
            try Self.requireAsset(keep.rawValue, in: db)
            for id in others {
                try Self.requireAsset(id, in: db)
                if let kit = try String.fetchOne(db, sql: """
                    SELECT c.slug || '/' || k.slug FROM brand_kit_asset ka JOIN brand_kit k ON k.id = ka.kit_id
                    JOIN company c ON c.id = k.company_id WHERE ka.asset_id = ? AND k.archived_at IS NULL LIMIT 1
                    """, arguments: [id]) {
                    throw APIError.conflict("used_by_brand_kit",
                                            "\(id) is a brand asset of \(kit); keep it, or remove it from the kit first.")
                }
            }
            var tags = 0, projects = 0, collections = 0
            var filled: [String] = []
            if mergeFiling {
                for id in others {
                    // People's tags (not auto tags, which belong to their own description).
                    try db.execute(sql: """
                        INSERT OR IGNORE INTO asset_tag(asset_id, tag_id, origin, created_at, confidence, source_ref)
                        SELECT ?, tag_id, origin, created_at, confidence, source_ref FROM asset_tag
                        WHERE asset_id = ? AND origin <> 'auto'
                        """, arguments: [keep.rawValue, id])
                    tags += db.changesCount
                    let keeperHasHome = try Bool.fetchOne(db, sql: """
                        SELECT EXISTS(SELECT 1 FROM project_asset WHERE asset_id = ? AND is_home = 1)
                        """, arguments: [keep.rawValue]) ?? false
                    for m in try Row.fetchAll(db, sql: """
                        SELECT project_id, is_home, status, role FROM project_asset
                        WHERE asset_id = ? AND project_id NOT IN (SELECT project_id FROM project_asset WHERE asset_id = ?)
                        """, arguments: [id, keep.rawValue]) {
                        let home = !keeperHasHome && (m["is_home"] as Bool)
                        try Self.setMembership(asset: keep.rawValue, project: m["project_id"], home: home,
                                               status: (m["status"] as String?).flatMap(ProjectStatus.init(rawValue:)),
                                               role: m["role"], origin: .user, in: db)
                        projects += 1
                    }
                    try db.execute(sql: """
                        INSERT OR IGNORE INTO collection_item(collection_id, asset_id, position, added_at)
                        SELECT collection_id, ?, position, added_at FROM collection_item WHERE asset_id = ?
                        """, arguments: [keep.rawValue, id])
                    collections += db.changesCount
                    for field in ["name", "caption", "alt_text", "notes", "creator", "credit_line", "copyright",
                                  "source_detail"] {
                        try db.execute(sql: """
                            UPDATE asset SET \(field) = (SELECT \(field) FROM asset WHERE id = ?2)
                            WHERE id = ?1 AND (\(field) IS NULL OR \(field) = '')
                              AND (SELECT coalesce(\(field), '') FROM asset WHERE id = ?2) <> ''
                            """, arguments: [keep.rawValue, id])
                        if db.changesCount > 0 { filled.append(field) }
                    }
                }
                try Self.touch(keep.rawValue, in: db)
            }
            let now = Date()
            for id in others {
                try db.execute(sql: "UPDATE asset SET trashed_at = ? WHERE id = ? AND trashed_at IS NULL", arguments: [now, id])
            }
            return DuplicateResolution(kept: keep, trashed: others.map(AssetID.init(rawValue:)), mergedTags: tags,
                                       mergedProjects: projects, mergedCollections: collections, filledFields: filled)
        }
    }

    /// Marks every pair among `ids` as "not duplicates": they stop appearing together in groups and similar lists.
    public func dismissDuplicates(_ ids: [AssetID]) throws {
        let unique = Array(Set(ids.map(\.rawValue))).sorted()
        guard unique.count > 1 else {
            throw APIError.badRequest("missing_parameter", "Name at least two assets.", param: "asset_ids")
        }
        try database.pool.write { db in
            for id in unique { try Self.requireAsset(id, in: db) }
            for i in unique.indices {
                for j in (i + 1)..<unique.count {
                    try db.execute(sql: "INSERT OR IGNORE INTO asset_distinct(a, b, created_at) VALUES (?, ?, ?)",
                                   arguments: [unique[i], unique[j], Date()])
                }
            }
        }
    }

    static func distance(_ a: Int64?, _ b: Int64?) -> Int {
        guard let a, let b else { return 64 }
        return (a ^ b).nonzeroBitCount
    }
}
