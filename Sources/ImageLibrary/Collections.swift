import Foundation
import GRDB
import ImageServerAPI

/// Collections are views over the library: folders (manual, ordered, nestable) and smart collections (a saved,
/// structured query evaluated live). Deleting a collection never deletes assets.
extension AssetLibrary {
    public func collections(company: String? = nil) throws -> [CollectionInfo] {
        let rows: [Row] = try database.pool.read { db in
            var sql = "SELECT * FROM collection"
            var args: [any DatabaseValueConvertible] = []
            if let company {
                guard let cid = try Self.resolveCompanyID(company, in: db, includeArchived: true) else { return [] }
                sql += " WHERE company_id = ?"
                args.append(cid)
            }
            return try Row.fetchAll(db, sql: sql + " ORDER BY name COLLATE NOCASE", arguments: StatementArguments(args))
        }
        return try rows.map(collectionInfo)
    }

    public func collection(_ ref: String) throws -> CollectionInfo? {
        let row: Row? = try database.pool.read { db in
            guard let id = try Self.resolveCollectionID(ref, in: db) else { return nil }
            return try Row.fetchOne(db, sql: "SELECT * FROM collection WHERE id = ?", arguments: [id])
        }
        return try row.map(collectionInfo)
    }

    public func createCollection(name: String, kind: CollectionKind, slug: String? = nil, parent: String? = nil,
                                 company: String? = nil, query: AssetQuery? = nil) throws -> CollectionInfo {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw APIError.badRequest("missing_parameter", "name is required.", param: "name")
        }
        if kind == .smart && query == nil {
            throw APIError.badRequest("missing_parameter", "A smart collection needs a query.", param: "query")
        }
        let id = "col_" + ULID.make()
        let collectionSlug = Self.slugify(slug ?? name)
        try database.pool.write { db in
            if try String.fetchOne(db, sql: "SELECT id FROM collection WHERE slug = ?", arguments: [collectionSlug]) != nil {
                throw APIError.conflict("slug_taken", "A collection '\(collectionSlug)' already exists.")
            }
            let parentID = try parent.map { ref -> String in
                guard let pid = try Self.resolveCollectionID(ref, in: db) else {
                    throw APIError.unprocessable("unknown_collection", "No collection '\(ref)'.", param: "parent")
                }
                return pid
            }
            let companyID = try company.map { ref -> String in
                guard let cid = try Self.resolveCompanyID(ref, in: db) else {
                    throw APIError.unprocessable("unknown_company", "No company '\(ref)'.", param: "company")
                }
                return cid
            }
            let queryJSON = try query.map { String(decoding: try JSONEncoder.imageServer.encode(Self.storable($0)), as: UTF8.self) }
            let now = Date()
            try db.execute(sql: """
                INSERT INTO collection(id, parent_id, company_id, slug, name, kind, query_json, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [id, parentID, companyID, collectionSlug, name, kind.rawValue, queryJSON, now, now])
        }
        return try collection(id)!
    }

    public func updateCollection(_ ref: String, name: String?, query: AssetQuery?) throws -> CollectionInfo {
        let id: String = try database.pool.write { db in
            guard let id = try Self.resolveCollectionID(ref, in: db) else { throw APIError.notFound("No collection '\(ref)'.") }
            var sets = ["updated_at = ?"]
            var args: [(any DatabaseValueConvertible)?] = [Date()]
            if let name { sets.append("name = ?"); args.append(name) }
            if let query {
                sets.append("query_json = ?")
                args.append(String(decoding: try JSONEncoder.imageServer.encode(Self.storable(query)), as: UTF8.self))
            }
            args.append(id)
            try db.execute(sql: "UPDATE collection SET \(sets.joined(separator: ", ")) WHERE id = ?",
                           arguments: StatementArguments(args))
            return id
        }
        return try collection(id)!
    }

    public func deleteCollection(_ ref: String) throws {
        try database.pool.write { db in
            guard let id = try Self.resolveCollectionID(ref, in: db) else { throw APIError.notFound("No collection '\(ref)'.") }
            try db.execute(sql: "DELETE FROM collection WHERE id = ?", arguments: [id])
        }
    }

    /// Adds assets to a folder (appended in order, or before `position`).
    public func addToCollection(_ assets: [AssetID], collection ref: String) throws {
        try database.pool.write { db in
            guard let id = try Self.resolveCollectionID(ref, in: db) else { throw APIError.notFound("No collection '\(ref)'.") }
            guard try String.fetchOne(db, sql: "SELECT kind FROM collection WHERE id = ?", arguments: [id]) == "folder" else {
                throw APIError.unprocessable("smart_collection", "'\(ref)' is a smart collection; edit its query instead.")
            }
            var position = (try Double.fetchOne(db, sql: "SELECT max(position) FROM collection_item WHERE collection_id = ?",
                                                arguments: [id]) ?? 0)
            for asset in assets {
                try Self.requireAsset(asset.rawValue, in: db)
                position += 1
                try db.execute(sql: """
                    INSERT OR IGNORE INTO collection_item(collection_id, asset_id, position, added_at) VALUES (?, ?, ?, ?)
                    """, arguments: [id, asset.rawValue, position, Date()])
            }
        }
    }

    public func removeFromCollection(_ assets: [AssetID], collection ref: String) throws {
        try database.pool.write { db in
            guard let id = try Self.resolveCollectionID(ref, in: db) else { throw APIError.notFound("No collection '\(ref)'.") }
            for asset in assets {
                try db.execute(sql: "DELETE FROM collection_item WHERE collection_id = ? AND asset_id = ?",
                               arguments: [id, asset.rawValue])
            }
        }
    }

    // MARK: - Internals

    private func collectionInfo(_ row: Row) throws -> CollectionInfo {
        let kind = CollectionKind(rawValue: row["kind"]) ?? .folder
        let query = try (row["query_json"] as String?).map {
            try JSONDecoder.imageServer.decode(AssetQuery.self, from: Data($0.utf8))
        }
        let id: String = row["id"]
        let count: Int
        if kind == .smart, var q = query {
            q.limit = 1
            q.facets = []
            count = try search(q).total
        } else {
            count = try database.pool.read { db in
                try Int.fetchOne(db, sql: """
                    SELECT count(*) FROM collection_item ci JOIN asset a ON a.id = ci.asset_id
                    WHERE ci.collection_id = ? AND a.trashed_at IS NULL
                    """, arguments: [id]) ?? 0
            }
        }
        return CollectionInfo(id: id, slug: row["slug"], name: row["name"], kind: kind, parentID: row["parent_id"],
                              companyID: row["company_id"], query: query, assetCount: count,
                              createdAt: row["created_at"], updatedAt: row["updated_at"])
    }

    /// A saved query keeps its filters, not its paging.
    static func storable(_ query: AssetQuery) -> AssetQuery {
        var q = query
        q.cursor = nil
        q.facets = []
        q.limit = 50
        return q
    }

    static func resolveCollectionID(_ ref: String, in db: Database) throws -> String? {
        if ref.hasPrefix("col_") {
            return try String.fetchOne(db, sql: "SELECT id FROM collection WHERE id = ?", arguments: [ref])
        }
        return try String.fetchOne(db, sql: "SELECT id FROM collection WHERE slug = ?", arguments: [slugify(ref)])
    }
}
