import Foundation
#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite)
import CSQLite
#endif

/// The apps' local copy of the vault in SQLite (docs/ROADMAP.md §3.1), in place of one JSON file
/// with every op that was encoded whole on every save. A save writes what changed (`SyncEngine.takeSaveDelta`):
/// new ops are appended, new segment keys added, and the small state (journal, pending ops, what's
/// still to push) replaced. The checkpoint the engine starts from (PROTOCOL.md §3) is one row, and
/// the ops it covers are dropped.
///
///     meta(k, v)            "version", "state" (JSON SyncEngine.LocalState), "base" (TRC1 checkpoint)
///     ops(device, seq, op)  op JSON, for ops the checkpoint doesn't cover
///     applied(key)          segment keys already applied
public final class LocalDatabase: @unchecked Sendable {
    public struct Failure: Error, CustomStringConvertible {
        public var description: String
    }

    private var db: OpaquePointer?
    private let lock = NSLock()
    public let url: URL

    public init(url: URL) throws {
        self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "can't open"
            sqlite3_close(handle)
            throw Failure(description: "open \(url.lastPathComponent): \(message)")
        }
        db = handle
        try exec("PRAGMA journal_mode=WAL")
        try exec("PRAGMA synchronous=NORMAL")
        try exec("""
            CREATE TABLE IF NOT EXISTS meta(k TEXT PRIMARY KEY, v BLOB) WITHOUT ROWID;
            CREATE TABLE IF NOT EXISTS ops(device TEXT NOT NULL, seq INTEGER NOT NULL, op BLOB NOT NULL, PRIMARY KEY(device, seq)) WITHOUT ROWID;
            CREATE TABLE IF NOT EXISTS applied(key TEXT PRIMARY KEY) WITHOUT ROWID;
            """)
    }

    deinit { sqlite3_close(db) }

    // MARK: Loading

    /// Everything saved, or nil when nothing has been yet.
    public func load() throws -> SyncEngine.Snapshot? {
        try lock.withLock {
            guard let stateData = try metaValue("state") else { return nil }
            let state = try JSONDecoder().decode(SyncEngine.LocalState.self, from: stateData)
            var base: Checkpoint?
            if let data = try metaValue("base") { base = try Checkpoint.decode(data) }
            let decoder = JSONDecoder()
            var ops: [Op] = []
            try query("SELECT op FROM ops") { row in ops.append(try decoder.decode(Op.self, from: Self.blob(row, 0))) }
            var applied: [String] = []
            try query("SELECT key FROM applied") { row in applied.append(String(cString: sqlite3_column_text(row, 0))) }
            return SyncEngine.Snapshot(journal: state.journal, pending: state.pending, unpushed: state.unpushed, applied: applied, ops: ops,
                                       unpushedBlobs: state.unpushedBlobs, bridgeBlobs: state.bridgeBlobs, base: base,
                                       checkpointCheckedAt: state.checkpointCheckedAt)
        }
    }

    // MARK: Saving

    /// Writes one save in a single transaction (all of it or none).
    public func save(_ delta: SyncEngine.SaveDelta) throws {
        try lock.withLock {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            try exec("BEGIN IMMEDIATE")
            do {
                if delta.rewrite {
                    try exec("DELETE FROM ops")
                    try exec("DELETE FROM applied")
                }
                if delta.baseChanged {
                    if let base = delta.base {
                        try setMeta("base", try base.encoded())
                        // The ops it covers are inside it now.
                        for (device, ranges) in base.covers {
                            for r in ranges where r.count == 2 {
                                try run("DELETE FROM ops WHERE device = ? AND seq BETWEEN ? AND ?", .text(device), .int(r[0]), .int(r[1]))
                            }
                        }
                    } else {
                        try run("DELETE FROM meta WHERE k = 'base'")
                    }
                }
                let insertOp = try prepare("INSERT OR REPLACE INTO ops(device, seq, op) VALUES(?, ?, ?)")
                defer { sqlite3_finalize(insertOp) }
                for op in delta.newOps {
                    try step(insertOp, [.text(op.device), .int(op.seq), .blob(try encoder.encode(op))])
                }
                let insertKey = try prepare("INSERT OR IGNORE INTO applied(key) VALUES(?)")
                defer { sqlite3_finalize(insertKey) }
                for key in delta.newApplied { try step(insertKey, [.text(key)]) }
                try setMeta("version", Data("1".utf8))
                try setMeta("state", try encoder.encode(delta.state))
                try exec("COMMIT")
            } catch {
                try? exec("ROLLBACK")
                throw error
            }
        }
    }

    /// How many ops are stored (for tests and diagnostics).
    public func opCount() throws -> Int {
        try lock.withLock {
            var n = 0
            try query("SELECT COUNT(*) FROM ops") { row in n = Int(sqlite3_column_int64(row, 0)) }
            return n
        }
    }

    // MARK: SQLite helpers

    enum Value { case text(String), int(Int), blob(Data) }

    private func error(_ what: String) -> Failure {
        Failure(description: "\(what): \(db.map { String(cString: sqlite3_errmsg($0)) } ?? "closed")")
    }

    private func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw error(sql) }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw error(sql) }
        return stmt
    }

    private func bind(_ stmt: OpaquePointer?, _ values: [Value]) {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, value) in values.enumerated() {
            let index = Int32(i + 1)
            switch value {
            case .text(let s): sqlite3_bind_text(stmt, index, s, -1, transient)
            case .int(let n): sqlite3_bind_int64(stmt, index, Int64(n))
            case .blob(let d):
                _ = d.withUnsafeBytes { raw in sqlite3_bind_blob(stmt, index, raw.baseAddress, Int32(d.count), transient) }
            }
        }
    }

    private func step(_ stmt: OpaquePointer?, _ values: [Value]) throws {
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
        bind(stmt, values)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw error("step") }
    }

    private func run(_ sql: String, _ values: Value...) throws {
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        try step(stmt, values)
    }

    private func query(_ sql: String, _ values: Value..., row: (OpaquePointer?) throws -> Void) throws {
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        bind(stmt, values)
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw error(sql) }
            try row(stmt)
        }
    }

    private static func blob(_ stmt: OpaquePointer?, _ column: Int32) -> Data {
        let count = Int(sqlite3_column_bytes(stmt, column))
        guard count > 0, let bytes = sqlite3_column_blob(stmt, column) else { return Data() }
        return Data(bytes: bytes, count: count)
    }

    private func metaValue(_ key: String) throws -> Data? {
        var out: Data?
        try query("SELECT v FROM meta WHERE k = ?", .text(key)) { row in out = Self.blob(row, 0) }
        return out
    }

    private func setMeta(_ key: String, _ value: Data) throws {
        try run("INSERT OR REPLACE INTO meta(k, v) VALUES(?, ?)", .text(key), .blob(value))
    }
}
