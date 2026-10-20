import Foundation

/// A small read-only SQLite reader (https://sqlite.org/fileformat.html), like web/public/core/sqlite.js:
/// tables, their columns and rows, with overflow pages and a write-ahead log (`-wal`) applied. Enough
/// to read another app's database (the Paste importer) anywhere, Linux included.
public struct SQLiteReader: Sendable {
    public enum Value: Sendable, Equatable {
        case null, integer(Int64), real(Double), text(String), blob(Data)

        public var string: String? { if case .text(let s) = self { return s }; return nil }
        public var data: Data? { if case .blob(let d) = self { return d }; return nil }
        public var number: Double? {
            switch self {
            case .integer(let i): Double(i)
            case .real(let d): d
            default: nil
            }
        }
        public var int: Int64? {
            switch self {
            case .integer(let i): i
            case .real(let d): Int64(exactly: d.rounded()) ?? nil
            default: nil
            }
        }
    }

    public struct Table: Sendable {
        public var name: String
        public var root: Int
        public var columns: [String]
        public var rowidColumn: Int
    }

    public struct Row: Sendable {
        public var rowid: Int64
        public var values: [String: Value]
        public subscript(_ column: String) -> Value { values[column] ?? .null }
    }

    public enum Failure: Error, CustomStringConvertible {
        case notSQLite, damaged(String)
        public var description: String {
            switch self {
            case .notSQLite: "This isn't a SQLite database"
            case .damaged(let why): "The database looks damaged (\(why))"
            }
        }
    }

    private let bytes: [UInt8]
    private let pageSize: Int
    private let usable: Int
    private var overlay: [Int: ArraySlice<UInt8>] = [:]
    public private(set) var tables: [Table] = []

    public init(_ data: Data, wal: Data? = nil) throws {
        bytes = [UInt8](data)
        guard bytes.count >= 100, String(decoding: bytes[0..<15], as: UTF8.self) == "SQLite format 3" else { throw Failure.notSQLite }
        let ps = Int(bytes[16]) << 8 | Int(bytes[17])
        pageSize = ps == 1 ? 65536 : ps
        usable = pageSize - Int(bytes[20])
        if let wal { applyWAL([UInt8](wal)) }
        tables = try readTables()
    }

    // MARK: Pages

    private static func u16(_ b: ArraySlice<UInt8>, _ at: Int) -> Int { Int(b[b.startIndex + at]) << 8 | Int(b[b.startIndex + at + 1]) }
    private static func u32(_ b: ArraySlice<UInt8>, _ at: Int) -> Int {
        (0..<4).reduce(0) { $0 << 8 | Int(b[b.startIndex + at + $1]) }
    }

    /// The newest committed copy of each page in the log (frames with the log's current salts).
    private mutating func applyWAL(_ wal: [UInt8]) {
        guard wal.count >= 32 else { return }
        let w = wal[...]
        let magic = Self.u32(w, 0)
        guard magic == 0x377f0682 || magic == 0x377f0683, Self.u32(w, 8) == pageSize else { return }
        let salt1 = Self.u32(w, 16), salt2 = Self.u32(w, 20)
        var pending: [Int: ArraySlice<UInt8>] = [:]
        var at = 32
        while at + 24 + pageSize <= wal.count {
            guard Self.u32(w, at + 8) == salt1, Self.u32(w, at + 12) == salt2 else { break }
            pending[Self.u32(w, at)] = w[(at + 24)..<(at + 24 + pageSize)]
            if Self.u32(w, at + 4) != 0 { overlay.merge(pending) { _, b in b }; pending = [:] }
            at += 24 + pageSize
        }
    }

    private func page(_ n: Int) throws -> ArraySlice<UInt8> {
        if let own = overlay[n] { return own }
        let start = (n - 1) * pageSize
        guard n >= 1, start + pageSize <= bytes.count else { throw Failure.damaged("page \(n) is outside the file") }
        return bytes[start..<(start + pageSize)]
    }

    private static func varint(_ b: ArraySlice<UInt8>, _ at: Int) -> (Int64, Int) {
        var v: UInt64 = 0
        for i in 0..<8 {
            let byte = b[b.startIndex + at + i]
            v = v << 7 | UInt64(byte & 0x7f)
            if byte & 0x80 == 0 { return (Int64(bitPattern: v), i + 1) }
        }
        return (Int64(bitPattern: v << 8 | UInt64(b[b.startIndex + at + 8])), 9)
    }

    /// Every row of the table b-tree at `root`, as (rowid, payload).
    private func cells(_ root: Int, seen: inout Set<Int>, into out: inout [(Int64, [UInt8])]) throws {
        guard seen.insert(root).inserted else { return } // a loop: a damaged file
        let p = try page(root)
        let h = root == 1 ? 100 : 0
        let type = p[p.startIndex + h], count = Self.u16(p, h + 3)
        if type == 0x05 {
            for i in 0..<count { try cells(Self.u32(p, Self.u16(p, h + 12 + i * 2)), seen: &seen, into: &out) }
            try cells(Self.u32(p, h + 8), seen: &seen, into: &out)
        } else if type == 0x0d {
            for i in 0..<count {
                var at = Self.u16(p, h + 8 + i * 2)
                let (size, a) = Self.varint(p, at); at += a
                let (rowid, b) = Self.varint(p, at); at += b
                out.append((rowid, try payload(p, at: at, size: Int(size))))
            }
        }
    }

    /// A cell's payload, joined from its overflow pages when it's too big for the page.
    private func payload(_ p: ArraySlice<UInt8>, at: Int, size: Int) throws -> [UInt8] {
        let u = usable, x = u - 35
        let base = p.startIndex + at
        if size <= x { return Array(p[base..<(base + size)]) }
        let m = ((u - 12) * 32) / 255 - 23
        let k = m + ((size - m) % (u - 4))
        let local = k <= x ? k : m
        var out = Array(p[base..<(base + local)])
        out.reserveCapacity(size)
        var next = Self.u32(p, at + local)
        var seen: Set<Int> = []
        while next != 0, out.count < size, seen.insert(next).inserted {
            let o = try page(next)
            let take = min(u - 4, size - out.count)
            out += o[(o.startIndex + 4)..<(o.startIndex + 4 + take)]
            next = Self.u32(o, 0)
        }
        return out
    }

    /// A record's values.
    static func record(_ payload: [UInt8]) -> [Value] {
        let b = payload[...]
        guard !payload.isEmpty else { return [] }
        let (headerSize, n) = varint(b, 0)
        var types: [Int64] = []
        var at = n
        while at < Int(headerSize), at < payload.count { let (t, k) = varint(b, at); types.append(t); at += k }
        var values: [Value] = []
        at = Int(headerSize)
        for t in types {
            switch t {
            case 0: values.append(.null)
            case 1...6:
                let len = [0, 1, 2, 3, 4, 6, 8][Int(t)]
                guard at + len <= payload.count else { values.append(.null); continue }
                var v: Int64 = payload[at] & 0x80 != 0 ? -1 : 0
                for i in 0..<len { v = v << 8 | Int64(payload[at + i]) }
                values.append(.integer(v))
                at += len
            case 7:
                guard at + 8 <= payload.count else { values.append(.null); continue }
                let bits = (0..<8).reduce(UInt64(0)) { $0 << 8 | UInt64(payload[at + $1]) }
                values.append(.real(Double(bitPattern: bits)))
                at += 8
            case 8, 9: values.append(.integer(t - 8))
            default:
                if t >= 12 {
                    let len = Int(t % 2 == 0 ? (t - 12) / 2 : (t - 13) / 2)
                    let end = min(payload.count, at + len)
                    let slice = Array(payload[min(at, end)..<end])
                    values.append(t % 2 == 0 ? .blob(Data(slice)) : .text(String(decoding: slice, as: UTF8.self)))
                    at += len
                } else {
                    values.append(.null)
                }
            }
        }
        return values
    }

    // MARK: Tables and rows

    private func readTables() throws -> [Table] {
        var seen: Set<Int> = []
        var out: [(Int64, [UInt8])] = []
        try cells(1, seen: &seen, into: &out)
        return out.compactMap { _, payload in
            let r = Self.record(payload)
            guard r.count >= 5, r[0].string == "table", let name = r[1].string, let root = r[3].int, root > 0, let sql = r[4].string else { return nil }
            let (columns, rowid) = Self.columns(sql)
            return Table(name: name, root: Int(root), columns: columns, rowidColumn: rowid)
        }
    }

    public func table(_ name: String) -> Table? { tables.first { $0.name.lowercased() == name.lowercased() } }

    /// A table's rows, keyed by column name (the rowid column gets the rowid).
    public func rows(_ table: Table) throws -> [Row] {
        var seen: Set<Int> = []
        var out: [(Int64, [UInt8])] = []
        try cells(table.root, seen: &seen, into: &out)
        return out.map { rowid, payload in
            let values = Self.record(payload)
            var row: [String: Value] = [:]
            for (i, c) in table.columns.enumerated() { row[c] = i == table.rowidColumn ? .integer(rowid) : (i < values.count ? values[i] : .null) }
            return Row(rowid: rowid, values: row)
        }
    }

    /// The column names in a CREATE TABLE statement, and which one is the rowid (INTEGER PRIMARY KEY).
    static func columns(_ sql: String) -> ([String], Int) {
        guard let open = sql.firstIndex(of: "("), let close = sql.lastIndex(of: ")"), open < close else { return ([], -1) }
        let body = Array(sql[sql.index(after: open)..<close])
        var parts: [String] = []
        var depth = 0, start = 0
        var quote: Character?
        for (i, c) in body.enumerated() {
            if let q = quote { if c == q { quote = nil }; continue }
            switch c {
            case "'", "\"", "`": quote = c
            case "[": quote = "]"
            case "(": depth += 1
            case ")": depth -= 1
            case "," where depth == 0: parts.append(String(body[start..<i])); start = i + 1
            default: break
            }
        }
        parts.append(String(body[start...]))
        var names: [String] = []
        var rowid = -1
        for raw in parts {
            let p = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = p.lowercased()
            if p.isEmpty || ["constraint", "primary key", "primary  key", "unique", "check", "foreign key"].contains(where: { lower.hasPrefix($0) }) { continue }
            var name: String
            var rest: Substring
            if let first = p.first, "\"`['".contains(first) {
                let closer: Character = first == "[" ? "]" : first
                let afterOpen = p.index(after: p.startIndex)
                guard let end = p[afterOpen...].firstIndex(of: closer) else { continue }
                name = String(p[afterOpen..<end])
                rest = p[p.index(after: end)...]
            } else {
                let end = p.firstIndex(where: { $0.isWhitespace }) ?? p.endIndex
                name = String(p[..<end])
                rest = p[end...]
            }
            let tail = rest.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
            if tail.hasPrefix("integer primary key") { rowid = names.count }
            names.append(name)
        }
        return (names, rowid)
    }
}
