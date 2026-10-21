import Foundation

/// The apps' meaning-vector cache on disk (docs/ROADMAP.md §3.7 item 7). It was JSON (~10 MB at 2,000
/// items, every float written as text) and rewritten after every change; now little-endian Float32:
///
///     "TVC1"  u32 count
///     count × ( u16 idLength, id UTF-8, u16 versionLength, version UTF-8, u32 dimensions, Float32 × dimensions )
///
/// Local only, never synced: every device rebuilds it from synced content.
public enum VectorCache {
    public struct Entry: Sendable, Equatable {
        public var version: String
        public var vector: [Float]
        public init(version: String, vector: [Float]) {
            self.version = version
            self.vector = vector
        }
    }

    static let magic: [UInt8] = Array("TVC1".utf8)

    public static func encode(_ entries: [String: Entry]) -> Data {
        var out = Data()
        var size = 8
        for (id, e) in entries { size += 8 + id.utf8.count + e.version.utf8.count + 4 * e.vector.count }
        out.reserveCapacity(size)
        out.append(contentsOf: magic)
        append(UInt32(entries.count), to: &out)
        for id in entries.keys.sorted() {
            guard let e = entries[id] else { continue }
            appendString(id, to: &out)
            appendString(e.version, to: &out)
            append(UInt32(e.vector.count), to: &out)
            for f in e.vector { append(f.bitPattern, to: &out) }
        }
        return out
    }

    /// Nil when the data isn't a vector cache (or was cut short).
    public static func decode(_ data: Data) -> [String: Entry]? {
        let bytes = [UInt8](data)
        guard bytes.count >= 8, Array(bytes[0..<4]) == magic else { return nil }
        var at = 4
        guard let count = readU32(bytes, &at) else { return nil }
        var out: [String: Entry] = [:]
        out.reserveCapacity(Int(min(count, 1_000_000)))
        for _ in 0..<count {
            guard let id = readString(bytes, &at), let version = readString(bytes, &at),
                  let dims = readU32(bytes, &at) else { return nil }
            let n = Int(dims)
            guard n <= (bytes.count - at) / 4 else { return nil }
            var vector = [Float](repeating: 0, count: n)
            for i in 0..<n {
                guard let bits = readU32(bytes, &at) else { return nil }
                vector[i] = Float(bitPattern: bits)
            }
            out[id] = Entry(version: version, vector: vector)
        }
        return out
    }

    private static func append(_ v: UInt32, to out: inout Data) {
        let le = v.littleEndian
        out.append(UInt8(truncatingIfNeeded: le))
        out.append(UInt8(truncatingIfNeeded: le >> 8))
        out.append(UInt8(truncatingIfNeeded: le >> 16))
        out.append(UInt8(truncatingIfNeeded: le >> 24))
    }

    private static func appendString(_ s: String, to out: inout Data) {
        let utf8 = Array(s.utf8.prefix(Int(UInt16.max)))
        let n = UInt16(utf8.count)
        out.append(UInt8(truncatingIfNeeded: n))
        out.append(UInt8(truncatingIfNeeded: n >> 8))
        out.append(contentsOf: utf8)
    }

    private static func readU32(_ b: [UInt8], _ at: inout Int) -> UInt32? {
        guard at + 4 <= b.count else { return nil }
        let v = UInt32(b[at]) | UInt32(b[at + 1]) << 8 | UInt32(b[at + 2]) << 16 | UInt32(b[at + 3]) << 24
        at += 4
        return v
    }

    private static func readString(_ b: [UInt8], _ at: inout Int) -> String? {
        guard at + 2 <= b.count else { return nil }
        let n = Int(UInt16(b[at]) | UInt16(b[at + 1]) << 8)
        at += 2
        guard at + n <= b.count else { return nil }
        let s = String(decoding: b[at..<(at + n)], as: UTF8.self)
        at += n
        return s
    }
}
