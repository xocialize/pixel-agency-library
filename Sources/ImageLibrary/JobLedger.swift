import Foundation
import GRDB
import ImageServerAPI

/// One persisted job plus the scheduler bookkeeping that is not part of the public snapshot.
public struct LedgerEntry: Sendable, Equatable {
    public var snapshot: JobSnapshot
    public var seq: Int64
    public var packageID: String?
    public var idempotencyKey: String?
    public var bypassCount: Int
    public var requeueCount: Int

    public init(snapshot: JobSnapshot, seq: Int64, packageID: String?, idempotencyKey: String?,
                bypassCount: Int = 0, requeueCount: Int = 0) {
        self.snapshot = snapshot
        self.seq = seq
        self.packageID = packageID
        self.idempotencyKey = idempotencyKey
        self.bypassCount = bypassCount
        self.requeueCount = requeueCount
    }
}

/// The job table. The scheduler keeps its working set in memory and writes through here on every state change —
/// the database is the source of truth across relaunches (the MediaOptimizationQueue pattern).
public final class JobLedger: Sendable {
    public let database: ServerDatabase

    public init(database: ServerDatabase) {
        self.database = database
    }

    /// Inserts a new job, assigning the next `seq`. Throws `APIError` 409-free: an idempotency collision is the
    /// caller's to look up first via `existing(client:idempotencyKey:)`.
    public func insert(_ snapshot: JobSnapshot, packageID: String?, idempotencyKey: String?) throws -> LedgerEntry {
        try database.pool.write { db in
            let seq = (try Int64.fetchOne(db, sql: "SELECT MAX(seq) FROM job") ?? 0) + 1
            let entry = LedgerEntry(snapshot: snapshot, seq: seq, packageID: packageID, idempotencyKey: idempotencyKey)
            try Self.write(entry, in: db, insert: true)
            for (name, ids) in snapshot.spec.inputs {
                for (i, id) in ids.enumerated() {
                    try db.execute(sql: "INSERT INTO job_input(job_id, name, ordinal, asset_id) VALUES (?, ?, ?, ?)",
                                   arguments: [snapshot.id.rawValue, name, i, id.rawValue])
                }
            }
            return entry
        }
    }

    public func save(_ entry: LedgerEntry) throws {
        try database.pool.write { db in try Self.write(entry, in: db, insert: false) }
    }

    public func entry(_ id: JobID) throws -> LedgerEntry? {
        try database.pool.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM job WHERE id = ?", arguments: [id.rawValue]).map(Self.entry(from:))
        }
    }

    public func existing(client: ClientID, idempotencyKey: String) throws -> LedgerEntry? {
        try database.pool.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM job WHERE client_id = ? AND idempotency_key = ?",
                             arguments: [client.rawValue, idempotencyKey]).map(Self.entry(from:))
        }
    }

    /// Every job that is not terminal, in submission order — the scheduler's recovery input.
    public func nonTerminal() throws -> [LedgerEntry] {
        let terminal = [JobState.succeeded, .failed, .cancelled].map(\.rawValue)
        return try database.pool.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM job WHERE state NOT IN (?, ?, ?) ORDER BY seq",
                             arguments: StatementArguments(terminal)).map(Self.entry(from:))
        }
    }

    public func recent(limit: Int, states: Set<JobState>?) throws -> [JobSnapshot] {
        try database.pool.read { db in
            var sql = "SELECT * FROM job"
            var args: [any DatabaseValueConvertible] = []
            if let states, !states.isEmpty {
                sql += " WHERE state IN (" + Array(repeating: "?", count: states.count).joined(separator: ",") + ")"
                args += states.map(\.rawValue)
            }
            sql += " ORDER BY seq DESC LIMIT ?"
            args.append(limit)
            return try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args)).map { try Self.entry(from: $0).snapshot }
        }
    }

    /// Deletes terminal jobs older than `age` (their assets stay; `asset.job_id` is informational).
    public func prune(olderThan age: TimeInterval) throws {
        let cutoff = Date().addingTimeInterval(-age)
        try database.pool.write { db in
            try db.execute(sql: """
                DELETE FROM job WHERE state IN ('succeeded','failed','cancelled') AND finished_at < ?
                """, arguments: [cutoff])
        }
    }

    // MARK: - Row mapping (shared with AssetLibrary's success transaction)

    static func write(_ entry: LedgerEntry, in db: Database, insert: Bool) throws {
        let s = entry.snapshot
        let json = String(decoding: try JSONEncoder.imageServer.encode(s), as: UTF8.self)
        let args: StatementArguments = [
            s.id.rawValue, entry.seq, s.state.rawValue, s.spec.capability.rawValue, s.model?.rawValue,
            entry.packageID, s.origin.rawValue, s.client.rawValue, entry.idempotencyKey, s.spec.priority,
            s.attempt, entry.requeueCount, entry.bypassCount, s.license?.licenseClass.rawValue, json,
            s.enqueuedAt, s.startedAt, s.finishedAt,
        ]
        if insert {
            try db.execute(sql: """
                INSERT INTO job(id, seq, state, capability, model_id, package_id, origin, client_id, idempotency_key,
                    priority, attempt, requeue_count, bypass_count, license_class, snapshot_json, enqueued_at,
                    started_at, finished_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: args)
        } else {
            try db.execute(sql: """
                UPDATE job SET seq = ?2, state = ?3, capability = ?4, model_id = ?5, package_id = ?6, origin = ?7,
                    client_id = ?8, idempotency_key = ?9, priority = ?10, attempt = ?11, requeue_count = ?12,
                    bypass_count = ?13, license_class = ?14, snapshot_json = ?15, enqueued_at = ?16,
                    started_at = ?17, finished_at = ?18
                WHERE id = ?1
                """, arguments: args)
        }
    }

    static func entry(from row: Row) throws -> LedgerEntry {
        let json: String = row["snapshot_json"]
        let snapshot = try JSONDecoder.imageServer.decode(JobSnapshot.self, from: Data(json.utf8))
        return LedgerEntry(snapshot: snapshot, seq: row["seq"], packageID: row["package_id"],
                           idempotencyKey: row["idempotency_key"], bypassCount: row["bypass_count"],
                           requeueCount: row["requeue_count"])
    }
}
