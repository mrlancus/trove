import Foundation
#if canImport(Compression)
import Compression
#endif

/// Checkpoints (PROTOCOL.md §3 "Checkpoints"): the materialised records at some point, so a new
/// device loads one file instead of replaying every op since the vault began. web/public/core/checkpoint.js
/// is the same code; both check Fixtures/checkpoint-cases.json.
///
/// A checkpoint holds, for every record, its kind, first and last HLC and its fields grouped by the
/// HLC of the op that set them; every text op verbatim (text merges replay them); and which ops it
/// covers. Ops it doesn't cover, even older ones from a device that was offline, then apply on top
/// exactly as a full replay would (`RecordStore.useBase`).
public struct Checkpoint: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable {
        public var id: String
        public var k: String
        public var ks: String?
        public var c: String
        public var u: String
        /// [[hlc, {field: value}]]
        public var g: [Group]
    }

    /// Fields set by the op with this HLC; JSON `["<hlc>", {…}]`.
    public struct Group: Codable, Sendable, Equatable {
        public var hlc: String
        public var fields: [String: JSONValue]

        public init(hlc: String, fields: [String: JSONValue]) { self.hlc = hlc; self.fields = fields }

        public init(from decoder: Decoder) throws {
            var c = try decoder.unkeyedContainer()
            hlc = try c.decode(String.self)
            fields = try c.decode([String: JSONValue].self)
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.unkeyedContainer()
            try c.encode(hlc)
            try c.encode(fields)
        }
    }

    public var v: Int = 1
    public var frontier: String
    public var cursor: Int?
    public var device: String
    public var createdAt: Double
    /// Device → merged [first, last] sequence ranges.
    public var covers: [String: [[Int]]]
    public var records: [Entry]
    public var texts: [Op]

    enum CodingKeys: String, CodingKey { case v, frontier, cursor, device, createdAt, covers, records, texts }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(v, forKey: .v)
        try c.encode(frontier, forKey: .frontier)
        if let cursor { try c.encode(cursor, forKey: .cursor) } else { try c.encodeNil(forKey: .cursor) }
        try c.encode(device, forKey: .device)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(covers, forKey: .covers)
        try c.encode(records, forKey: .records)
        try c.encode(texts, forKey: .texts)
    }

    /// What `RecordStore.useBase` takes: records with their fields, stamps by record, sorted covers.
    public struct Base: Sendable {
        public struct Rec: Sendable {
            public var id: String
            public var kind: String
            public var created: String
            public var updated: String
            public var fields: [String: JSONValue]
        }
        public struct Stamps: Sendable {
            public var fields: [String: String]
            public var kind: String?
        }
        public var id: String = ""
        public var frontier: String
        public var cursor: Int?
        public var covers: [String: [ClosedRange<Int>]]
        public var records: [Rec]
        public var stamps: [String: Stamps]
        public var texts: [Op]

        /// The highest sequence number of `device` inside, or 0.
        public func lastCovered(_ device: String) -> Int { covers[device]?.last?.upperBound ?? 0 }
    }

    public enum Failure: Error, Equatable { case notACheckpoint, unknownFormat, tooLarge }

    // MARK: Making

    /// The checkpoint of everything `store` holds. Make one only when every op is pushed (nothing
    /// pending), so nothing it covers can be renumbered. `cursor` is the relay cursor up to which
    /// every relay segment is applied.
    public static func make(from store: RecordStore, cursor: Int?, device: String, createdAt: Date = Date()) -> Checkpoint {
        var stamps: [String: Base.Stamps] = store.base?.stamps ?? [:]
        var seqs: [String: [ClosedRange<Int>]] = store.base?.covers ?? [:]
        var texts: [Op] = []
        for op in store.allOps.sorted(by: RecordStore.order) {
            seqs[op.device, default: []].append(op.seq...op.seq)
            if op.type == .text { texts.append(op) }
            var s = stamps[op.record] ?? Base.Stamps(fields: [:], kind: nil)
            if op.recordKind != nil {
                let current = s.kind ?? ""
                if current.isEmpty || op.hlc >= current { s.kind = op.hlc }
            }
            if op.type == .set {
                for key in (op.fields ?? [:]).keys {
                    if let current = s.fields[key], op.hlc < current { continue }
                    s.fields[key] = op.hlc
                }
            }
            stamps[op.record] = s
        }
        var covers: [String: [[Int]]] = [:]
        for (device, ranges) in seqs { covers[device] = merge(ranges).map { [$0.lowerBound, $0.upperBound] } }
        var entries: [Entry] = []
        for id in store.records.keys.sorted() {
            guard let r = store.records[id] else { continue }
            let s = stamps[id]
            var groups: [String: [String: JSONValue]] = [:]
            for (key, value) in r.fields {
                let h = s?.fields[key] ?? r.updatedHLC
                groups[h, default: [:]][key] = value
            }
            let g = groups.keys.sorted().map { Group(hlc: $0, fields: groups[$0] ?? [:]) }
            entries.append(Entry(id: id, k: r.kind, ks: s?.kind, c: r.createdHLC, u: r.updatedHLC, g: g))
        }
        return Checkpoint(frontier: store.frontier, cursor: cursor, device: device,
                          createdAt: (createdAt.timeIntervalSince1970 * 1000).rounded(), covers: covers, records: entries, texts: texts)
    }

    public var base: Base {
        var cov: [String: [ClosedRange<Int>]] = [:]
        for (device, ranges) in covers {
            cov[device] = Self.merge(ranges.compactMap { r in r.count == 2 && r[0] <= r[1] ? r[0]...r[1] : nil })
        }
        var recs: [Base.Rec] = []
        var stamps: [String: Base.Stamps] = [:]
        recs.reserveCapacity(records.count)
        for r in records {
            var fields: [String: JSONValue] = [:]
            var fieldStamps: [String: String] = [:]
            for group in r.g {
                for (key, value) in group.fields {
                    fields[key] = value
                    fieldStamps[key] = group.hlc
                }
            }
            recs.append(Base.Rec(id: r.id, kind: r.k, created: r.c, updated: r.u, fields: fields))
            stamps[r.id] = Base.Stamps(fields: fieldStamps, kind: r.ks)
        }
        return Base(frontier: frontier, cursor: cursor, covers: cov, records: recs, stamps: stamps, texts: texts)
    }

    // MARK: Ranges

    static func merge(_ list: [ClosedRange<Int>]) -> [ClosedRange<Int>] {
        var out: [ClosedRange<Int>] = []
        for r in list.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = out.last, r.lowerBound <= last.upperBound + 1 {
                out[out.count - 1] = last.lowerBound...max(last.upperBound, r.upperBound)
            } else {
                out.append(r)
            }
        }
        return out
    }

    /// `covers` holds every op of `device` from `first` to `last` (a whole segment).
    public static func covers(_ covers: [String: [ClosedRange<Int>]], device: String, first: Int, last: Int) -> Bool {
        guard let ranges = covers[device] else { return false }
        var lo = 0, hi = ranges.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            let r = ranges[mid]
            if first < r.lowerBound { hi = mid - 1 }
            else if first > r.upperBound { lo = mid + 1 }
            else { return last <= r.upperBound }
        }
        return false
    }

    /// `outer` covers every op `inner` does.
    public static func coversAll(_ outer: [String: [ClosedRange<Int>]], _ inner: [String: [ClosedRange<Int>]]) -> Bool {
        for (device, ranges) in inner {
            for r in ranges where !covers(outer, device: device, first: r.lowerBound, last: r.upperBound) { return false }
        }
        return true
    }

    // MARK: Bytes

    static let magic = Data("TRC1".utf8)

    /// "TRC1", a format byte (0: JSON; 1: u32 length then raw DEFLATE of the JSON), then the payload.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let json = try encoder.encode(self)
        if let deflated = Self.deflate(json) {
            var out = Self.magic
            out.append(1)
            out.appendUInt32(UInt32(json.count))
            out.append(deflated)
            return out
        }
        var out = Self.magic
        out.append(0)
        out.append(json)
        return out
    }

    public static func decode(_ data: Data) throws -> Checkpoint {
        let bytes = [UInt8](data)
        guard bytes.count >= 5, Data(bytes[0..<4]) == magic else { throw Failure.notACheckpoint }
        let json: Data
        switch bytes[4] {
        case 0:
            json = Data(bytes[5...])
        case 1:
            guard bytes.count >= 9 else { throw Failure.notACheckpoint }
            let length = Int(UInt32(bytes[5]) << 24 | UInt32(bytes[6]) << 16 | UInt32(bytes[7]) << 8 | UInt32(bytes[8]))
            json = try Inflate.decompress(Data(bytes[9...]), expectedSize: length)
        default:
            throw Failure.unknownFormat
        }
        return try JSONDecoder().decode(Checkpoint.self, from: json)
    }

    /// Encrypted like a segment (TRV1 with the segment key), so only the vault's devices can read it.
    public func sealed(with keys: VaultKeys) throws -> Data { try TRV1.encrypt(encoded(), key: keys.segmentKey) }

    public static func open(_ data: Data, keys: VaultKeys) throws -> Checkpoint {
        try decode(TRV1.decrypt(data, key: keys.segmentKey))
    }

    /// Raw DEFLATE where the Compression framework has it (Apple platforms); checked by inflating it
    /// back. Elsewhere checkpoints are written uncompressed (format 0), which every reader takes.
    static func deflate(_ input: Data) -> Data? {
        #if canImport(Compression)
        guard !input.isEmpty else { return nil }
        let capacity = input.count + input.count / 10 + 1024
        var out = Data(count: capacity)
        let written = out.withUnsafeMutableBytes { dst in
            input.withUnsafeBytes { src in
                compression_encode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                                          src.bindMemory(to: UInt8.self).baseAddress!, input.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return nil }
        out.count = written
        guard (try? Inflate.decompress(out, expectedSize: input.count)) == input else { return nil }
        return out
        #else
        return nil
        #endif
    }
}
