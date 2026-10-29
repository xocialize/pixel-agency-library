import Foundation
import GRDB
import ImageServerAPI

/// Library search: FTS5 (BM25 with column weights) + structured filters + facet counts. A single-choice facet's
/// counts ignore that facet's own filter, so the alternatives stay visible; tag facets AND.
extension AssetLibrary {
    public static let defaultFacets = ["project", "company", "status", "tag", "source", "license", "rights",
                                       "model", "orientation"]

    public func search(_ query: AssetQuery) throws -> SearchResult {
        try database.pool.read { db in
            let plan = try SearchPlan(query: query, db: db)
            let limit = max(1, min(query.limit, 200))
            let offset = query.cursor.flatMap(Int.init) ?? 0

            let base = plan.from(excluding: nil)
            let total = try Int.fetchOne(db, sql: "SELECT count(*) \(base.sql)", arguments: base.args) ?? 0
            let order: String
            switch query.sort ?? (plan.hasText ? .relevance : .newest) {
            case .relevance where plan.hasText: order = "rank, a.id DESC"
            case .relevance, .newest: order = "a.id DESC"
            case .oldest: order = "a.id ASC"
            case .name: order = "coalesce(a.name, a.original_filename, a.id) COLLATE NOCASE, a.id DESC"
            case .updated: order = "coalesce(a.updated_at, a.created_at) DESC, a.id DESC"
            }
            // Every join in the base query is 1:1 per asset (tags and projects filter through EXISTS), so no
            // GROUP BY — FTS5's bm25() cannot run inside an aggregate.
            let rankColumn = plan.hasText ? ", bm25(asset_fts, 8, 4, 3, 6, 1, 5, 2, 2) AS rank" : ""
            var args = base.args
            args += [limit, offset]
            let ids = try String.fetchAll(db, sql: """
                SELECT a.id \(rankColumn) \(base.sql) ORDER BY \(order) LIMIT ? OFFSET ?
                """, arguments: args)
            let assets = try ids.compactMap { try Self.info($0, in: db) }

            var facets: [String: [FacetValue]] = [:]
            for name in (query.facets.isEmpty ? [] : query.facets) {
                facets[name] = try plan.facet(name, db: db)
            }
            let next = offset + assets.count < total ? String(offset + assets.count) : nil
            return SearchResult(assets: assets, total: total, nextCursor: next, facets: facets)
        }
    }
}

/// A compiled query: FROM/JOIN/WHERE fragments, each tagged with the facet it belongs to.
struct SearchPlan {
    struct Clause {
        var facet: String?
        var sql: String
        var args: [(any DatabaseValueConvertible)?]
    }

    let hasText: Bool
    private let ftsExpression: String?
    private var clauses: [Clause] = []
    private var projectIDs: [String] = []

    init(query: AssetQuery, db: Database, depth: Int = 0) throws {
        ftsExpression = query.text.flatMap(Self.ftsExpression)
        hasText = ftsExpression != nil

        // Tags: AND across, aliases resolved; an unknown tag matches nothing.
        for raw in query.tags {
            if let reserved = Self.reservedFilter(raw) { clauses.append(reserved); continue }
            guard let tag = try? AssetLibrary.tagID(for: raw, create: false, in: db) else {
                clauses.append(Clause(facet: "tag", sql: "0", args: []))
                continue
            }
            clauses.append(Clause(facet: nil, sql: "EXISTS (SELECT 1 FROM asset_tag at WHERE at.asset_id = a.id AND at.tag_id = ?)",
                                  args: [tag.id]))
        }
        for raw in query.excludeTags {
            guard let tag = try? AssetLibrary.tagID(for: raw, create: false, in: db) else { continue }
            clauses.append(Clause(facet: nil, sql: "NOT EXISTS (SELECT 1 FROM asset_tag at WHERE at.asset_id = a.id AND at.tag_id = ?)",
                                  args: [tag.id]))
        }

        if !query.projects.isEmpty {
            projectIDs = try query.projects.compactMap { try AssetLibrary.resolveProjectID($0, in: db, includeArchived: true) }
            if projectIDs.isEmpty {
                clauses.append(Clause(facet: "project", sql: "0", args: []))
            } else {
                clauses.append(Clause(facet: "project", sql: """
                    EXISTS (SELECT 1 FROM project_asset pa WHERE pa.asset_id = a.id AND pa.project_id IN (\(Self.marks(projectIDs.count))))
                    """, args: projectIDs))
            }
        }
        if let company = query.company {
            if let id = try AssetLibrary.resolveCompanyID(company, in: db, includeArchived: true) {
                clauses.append(Clause(facet: "company", sql: "a.company_id = ?", args: [id]))
            } else {
                clauses.append(Clause(facet: "company", sql: "0", args: []))
            }
        }
        if query.inbox {
            clauses.append(Clause(facet: nil, sql: "NOT EXISTS (SELECT 1 FROM project_asset pa WHERE pa.asset_id = a.id AND pa.is_home = 1)",
                                  args: []))
        }
        let scope = projectIDs.isEmpty ? "" : " AND pa.project_id IN (\(Self.marks(projectIDs.count)))"
        if !query.statuses.isEmpty {
            clauses.append(Clause(facet: "status", sql: """
                EXISTS (SELECT 1 FROM project_asset pa WHERE pa.asset_id = a.id\(scope) AND pa.status IN (\(Self.marks(query.statuses.count))))
                """, args: projectIDs + query.statuses.map(\.rawValue)))
        }
        if !query.excludeStatuses.isEmpty {
            clauses.append(Clause(facet: nil, sql: """
                NOT EXISTS (SELECT 1 FROM project_asset pa WHERE pa.asset_id = a.id\(scope) AND pa.status IN (\(Self.marks(query.excludeStatuses.count))))
                """, args: projectIDs + query.excludeStatuses.map(\.rawValue)))
        }
        if let v = query.source { clauses.append(Clause(facet: "source", sql: "a.source = ?", args: [v.rawValue])) }
        if let v = query.kind { clauses.append(Clause(facet: "kind", sql: "a.kind = ?", args: [v.rawValue])) }
        if let v = query.licenseClass { clauses.append(Clause(facet: "license", sql: "a.license_class = ?", args: [v.rawValue])) }
        if let v = query.rightsClass { clauses.append(Clause(facet: "rights", sql: "a.rights_class = ?", args: [v.rawValue])) }
        if let v = query.model { clauses.append(Clause(facet: "model", sql: "g.model_id = ?", args: [v.rawValue])) }
        if let v = query.capability { clauses.append(Clause(facet: "capability", sql: "g.capability = ?", args: [v.rawValue])) }
        if let v = query.orientation { clauses.append(Clause(facet: "orientation", sql: "a.orientation = ?", args: [v])) }
        // Collections: folder membership, or a smart collection's saved query (nested, depth-limited against cycles).
        for ref in query.collections {
            guard let row = try Row.fetchOne(db, sql: "SELECT id, kind, query_json FROM collection WHERE id = ? OR slug = ?",
                                             arguments: [ref, AssetLibrary.slugify(ref)]) else {
                clauses.append(Clause(facet: "collection", sql: "0", args: []))
                continue
            }
            let id: String = row["id"]
            if (row["kind"] as String) == "smart", let json: String = row["query_json"], depth < 3,
               let saved = try? JSONDecoder.imageServer.decode(AssetQuery.self, from: Data(json.utf8)) {
                let inner = try SearchPlan(query: saved, db: db, depth: depth + 1).fromValues(excluding: nil)
                clauses.append(Clause(facet: "collection", sql: "a.id IN (SELECT a.id \(inner.sql))", args: inner.values))
            } else {
                clauses.append(Clause(facet: "collection",
                                      sql: "EXISTS (SELECT 1 FROM collection_item ci WHERE ci.asset_id = a.id AND ci.collection_id = ?)",
                                      args: [id]))
            }
        }
        if let colour = query.colour {
            if let lab = Self.lab(hex: colour) {
                clauses.append(Clause(facet: "colour", sql: Self.colourMatch(lab), args: []))
            } else {
                clauses.append(Clause(facet: "colour",
                                      sql: "EXISTS (SELECT 1 FROM blob_color bc WHERE bc.blob_hash = a.blob_hash AND bc.bucket = ? AND bc.weight >= 0.1)",
                                      args: [colour == "grey" ? "gray" : colour]))
            }
        }
        if let described = query.described {
            clauses.append(Clause(facet: "described",
                                  sql: (described ? "" : "NOT ") + "EXISTS (SELECT 1 FROM asset_description ad WHERE ad.asset_id = a.id)",
                                  args: []))
        }
        if let expiry = query.expiry {
            let now = Date()
            switch expiry {
            case "expired":
                clauses.append(Clause(facet: "expiry", sql: "a.rights_expires_at IS NOT NULL AND a.rights_expires_at < ?", args: [now]))
            case "soon":
                clauses.append(Clause(facet: "expiry", sql: "a.rights_expires_at >= ? AND a.rights_expires_at < ?",
                                      args: [now, now.addingTimeInterval(30 * 86400)]))
            default:
                clauses.append(Clause(facet: "expiry", sql: "a.rights_expires_at IS NOT NULL", args: []))
            }
        }
        if let v = query.createdAfter { clauses.append(Clause(facet: "month", sql: "a.created_at >= ?", args: [v])) }
        if let v = query.createdBefore { clauses.append(Clause(facet: "month", sql: "a.created_at < ?", args: [v])) }
    }

    /// `FROM … WHERE …` with every clause except those belonging to `facet`.
    func from(excluding facet: String?, extraJoin: String = "") -> (sql: String, args: StatementArguments) {
        let (sql, values) = fromValues(excluding: facet, extraJoin: extraJoin)
        return (sql, StatementArguments(values))
    }

    func fromValues(excluding facet: String?, extraJoin: String = "") -> (sql: String, values: [(any DatabaseValueConvertible)?]) {
        var sql = "FROM asset a LEFT JOIN generation g ON g.id = a.generation_id"
        var args: [(any DatabaseValueConvertible)?] = []
        if let fts = ftsExpression {
            sql += " JOIN asset_doc d ON d.asset_id = a.id JOIN asset_fts ON asset_fts.rowid = d.doc_id"
            sql += extraJoin + " WHERE a.trashed_at IS NULL AND asset_fts MATCH ?"
            args.append(fts)
        } else {
            sql += extraJoin + " WHERE a.trashed_at IS NULL"
        }
        for clause in clauses where facet == nil || clause.facet != facet {
            sql += " AND (\(clause.sql))"
            args += clause.args
        }
        return (sql, args)
    }

    func facet(_ name: String, db: Database) throws -> [FacetValue] {
        let spec: (join: String, key: String, label: String, limit: Int)
        switch name {
        case "project":
            spec = (" JOIN project_asset fpa ON fpa.asset_id = a.id JOIN project fp ON fp.id = fpa.project_id"
                        + " LEFT JOIN company fc ON fc.id = fp.company_id",
                    "fp.id", "coalesce(fc.slug || '/', '') || fp.slug", 30)
        case "company":
            spec = (" JOIN company fc ON fc.id = a.company_id", "fc.id", "fc.name", 30)
        case "status":
            let scope = projectIDs.isEmpty ? "" : " AND fpa.project_id IN ('\(projectIDs.joined(separator: "','"))')"
            spec = (" JOIN project_asset fpa ON fpa.asset_id = a.id AND fpa.status IS NOT NULL\(scope)", "fpa.status", "fpa.status", 10)
        case "tag":
            spec = (" JOIN asset_tag fat ON fat.asset_id = a.id AND fat.origin <> 'auto' JOIN tag ft ON ft.id = fat.tag_id",
                    "ft.name", "ft.name", 40)
        case "source": spec = ("", "a.source", "a.source", 10)
        case "kind": spec = ("", "a.kind", "a.kind", 10)
        case "license": spec = ("", "a.license_class", "a.license_class", 10)
        case "rights": spec = ("", "a.rights_class", "a.rights_class", 10)
        case "model": spec = ("", "g.model_id", "g.model_id", 30)
        case "orientation": spec = ("", "a.orientation", "a.orientation", 5)
        case "month": spec = ("", "strftime('%Y-%m', a.created_at)", "strftime('%Y-%m', a.created_at)", 24)
        case "colour":
            spec = (" JOIN blob_color fbc ON fbc.blob_hash = a.blob_hash AND fbc.rank = 0", "fbc.bucket", "fbc.bucket", 12)
        case "expiry":
            let now = SearchPlan.sqlDate(Date())
            let soon = SearchPlan.sqlDate(Date().addingTimeInterval(30 * 86400))
            let key = "CASE WHEN a.rights_expires_at IS NULL THEN NULL WHEN a.rights_expires_at < '\(now)' THEN 'expired' "
                + "WHEN a.rights_expires_at < '\(soon)' THEN 'soon' ELSE 'later' END"
            spec = ("", key, key, 3)
        default: return []
        }
        // Tags AND, so their facet keeps every filter; single-choice facets drop their own.
        let base = from(excluding: name == "tag" ? nil : name, extraJoin: spec.join)
        let rows = try Row.fetchAll(db, sql: """
            SELECT \(spec.key) AS value, \(spec.label) AS label, count(DISTINCT a.id) AS n \(base.sql)
            AND \(spec.key) IS NOT NULL GROUP BY \(spec.key) ORDER BY n DESC, label LIMIT \(spec.limit)
            """, arguments: base.args)
        return rows.map { FacetValue(value: $0["value"], label: $0["label"], count: $0["n"]) }
    }

    /// Reserved-namespace tags (`model:x`, `source:uploaded`, …) are column filters, so v1 `tag=` filters keep working.
    static func reservedFilter(_ raw: String) -> Clause? {
        let name = raw.lowercased()
        guard let colon = name.firstIndex(of: ":") else { return nil }
        let ns = String(name[..<colon]), value = String(raw[raw.index(after: colon)...])
        switch ns {
        case "model": return Clause(facet: "model", sql: "g.model_id = ?", args: [value])
        case "capability": return Clause(facet: "capability", sql: "g.capability = ?", args: [value])
        case "license": return Clause(facet: "license", sql: "a.license_class = ?", args: [value])
        case "source": return Clause(facet: "source", sql: "a.source = ?", args: [value])
        case "kind": return Clause(facet: "kind", sql: "a.kind = ?", args: [value])
        case "rights": return Clause(facet: "rights", sql: "a.rights_class = ?", args: [value])
        case "orientation": return Clause(facet: "orientation", sql: "a.orientation = ?", args: [value])
        default: return nil
        }
    }

    /// Free text → FTS5: quoted phrases stay phrases; words become prefix terms (`"hero"*`); all ANDed.
    static func ftsExpression(_ text: String) -> String? {
        var parts: [String] = []
        for token in AssetQuery.tokenize(text) {
            if token.hasPrefix("\"") {
                let inner = token.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                    .replacingOccurrences(of: "\"", with: "\"\"")
                if !inner.isEmpty { parts.append("\"\(inner)\"") }
                continue
            }
            let words = token.unicodeScalars.split { !CharacterSet.alphanumerics.contains($0) }.map { String(String.UnicodeScalarView($0)) }
            for word in words where !word.isEmpty { parts.append("\"\(word)\"*") }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    static func marks(_ n: Int) -> String { Array(repeating: "?", count: n).joined(separator: ",") }

    static func lab(hex: String) -> (Double, Double, Double)? {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        return ImageFacts.lab(r: Double((value >> 16) & 0xff) / 255, g: Double((value >> 8) & 0xff) / 255,
                              b: Double(value & 0xff) / 255)
    }

    /// A palette entry covering at least 6% of the image that is either near the colour in Lab (ΔE < 20) or the same
    /// colour under different light: hue within 15° and at least 60% of its chroma. Lighting moves L and chroma a
    /// long way (a shaded #FF6600 mug reads #BB5B25, ΔE 29) while hue barely moves; the chroma floor keeps a
    /// tan desk (same hue, 40% chroma) out of "orange". Polynomial only — no SQLite math functions needed. The
    /// numbers come from a parsed hex, so they are inlined.
    static func colourMatch(_ lab: (Double, Double, Double)) -> String {
        let (l, a, b) = lab
        let chroma2 = a * a + b * b
        let near = "((bc.l - \(l)) * (bc.l - \(l)) + (bc.a - \(a)) * (bc.a - \(a)) + (bc.b - \(b)) * (bc.b - \(b))) < 400"
        var sql = "EXISTS (SELECT 1 FROM blob_color bc WHERE bc.blob_hash = a.blob_hash AND bc.weight >= 0.06 AND (\(near)"
        if chroma2 >= 400 {   // hue is only meaningful for a saturated reference
            let dot = "(bc.a * \(a) + bc.b * \(b))"
            let c2 = "(bc.a * bc.a + bc.b * bc.b)"
            sql += " OR (\(dot) > 0 AND \(dot) * \(dot) >= \(0.933 * chroma2) * \(c2) AND \(c2) >= \(0.36 * chroma2))"
        }
        return sql + "))"
    }

    /// GRDB's stored datetime format, for literals in facet CASE expressions.
    static func sqlDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f.string(from: date)
    }
}
