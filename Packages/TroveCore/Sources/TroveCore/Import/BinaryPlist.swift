import Foundation

/// Apple binary property lists ("bplist00") and NSKeyedArchiver archives inside them, read-only,
/// like web/public/core/bplist.js, for the Paste importer. Pure Swift, so it works on Linux too.
public indirect enum PlistValue: Sendable, Equatable {
    case null, bool(Bool), int(Int64), real(Double), date(Date), data(Data), string(String), uid(Int)
    case array([PlistValue]), dict([String: PlistValue])

    public var string: String? { if case .string(let s) = self { return s }; return nil }
    public var data: Data? { if case .data(let d) = self { return d }; return nil }
    public var array: [PlistValue]? { if case .array(let a) = self { return a }; return nil }
    public var dict: [String: PlistValue]? { if case .dict(let d) = self { return d }; return nil }
}

public enum BinaryPlist {
    public static func isPlist(_ data: Data) -> Bool { data.count >= 8 && data.prefix(8) == Data("bplist00".utf8) }

    public static func parse(_ data: Data) -> PlistValue? {
        guard isPlist(data), data.count >= 40 else { return nil }
        let b = [UInt8](data)
        let t = b.count - 32
        let offsetSize = Int(b[t + 6]), refSize = Int(b[t + 7])
        func uint(_ at: Int, _ size: Int) -> Int {
            guard at >= 0, at + size <= b.count else { return 0 }
            return (0..<size).reduce(0) { $0 << 8 | Int(b[at + $1]) }
        }
        let count = uint(t + 8, 8), top = uint(t + 16, 8), table = uint(t + 24, 8)
        guard offsetSize > 0, refSize > 0, count > 0, table + count * offsetSize <= b.count else { return nil }
        var cache: [Int: PlistValue] = [:]
        func read(_ i: Int, _ depth: Int) -> PlistValue {
            guard depth < 200, i < count else { return .null }
            if let hit = cache[i] { return hit }
            let at = uint(table + i * offsetSize, offsetSize)
            guard at < b.count else { return .null }
            let marker = b[at], kind = marker >> 4, low = Int(marker & 15)
            func length() -> (Int, Int) {
                guard low == 15, at + 1 < b.count else { return (low, at + 1) }
                let size = 1 << Int(b[at + 1] & 15)
                return (uint(at + 2, size), at + 2 + size)
            }
            func slice(_ s: Int, _ n: Int) -> Data { s >= 0 && s + n <= b.count ? Data(b[s..<(s + n)]) : Data() }
            let value: PlistValue
            switch kind {
            case 0: value = low == 8 ? .bool(false) : low == 9 ? .bool(true) : .null
            case 1:
                let size = 1 << low
                if size >= 8 {
                    let bits = (0..<8).reduce(UInt64(0)) { $0 << 8 | UInt64(at + 1 + (size - 8) + $1 < b.count ? b[at + 1 + (size - 8) + $1] : 0) }
                    value = .int(Int64(bitPattern: bits))
                } else {
                    value = .int(Int64(uint(at + 1, size)))
                }
            case 2:
                if low == 2 {
                    value = .real(Double(Float(bitPattern: UInt32(uint(at + 1, 4)))))
                } else {
                    value = .real(Double(bitPattern: (0..<8).reduce(UInt64(0)) { $0 << 8 | UInt64(at + 1 + $1 < b.count ? b[at + 1 + $1] : 0) }))
                }
            case 3:
                let d = Double(bitPattern: (0..<8).reduce(UInt64(0)) { $0 << 8 | UInt64(at + 1 + $1 < b.count ? b[at + 1 + $1] : 0) })
                value = .date(Date(timeIntervalSinceReferenceDate: d))
            case 4: let (n, s) = length(); value = .data(slice(s, n))
            case 5: let (n, s) = length(); value = .string(String(decoding: slice(s, n), as: UTF8.self))
            case 6:
                let (n, s) = length()
                let raw = slice(s, n * 2)
                var units: [UInt16] = []
                units.reserveCapacity(n)
                var k = raw.startIndex
                while k + 1 < raw.endIndex { units.append(UInt16(raw[k]) << 8 | UInt16(raw[k + 1])); k += 2 }
                value = .string(String(decoding: units, as: UTF16.self))
            case 7: let (n, s) = length(); value = .string(String(decoding: slice(s, n), as: UTF8.self))
            case 8: value = .uid(uint(at + 1, low + 1))
            case 10, 12:
                let (n, s) = length()
                cache[i] = .array([])
                value = .array((0..<n).map { read(uint(s + $0 * refSize, refSize), depth + 1) })
            case 13:
                let (n, s) = length()
                cache[i] = .dict([:])
                var d: [String: PlistValue] = [:]
                for k in 0..<n {
                    let key = read(uint(s + k * refSize, refSize), depth + 1)
                    let keyText: String = switch key {
                    case .string(let s): s
                    case .int(let v): String(v)
                    default: "\(k)"
                    }
                    d[keyText] = read(uint(s + (n + k) * refSize, refSize), depth + 1)
                }
                value = .dict(d)
            default: value = .null
            }
            cache[i] = value
            return value
        }
        return read(top, 0)
    }

    /// True for an NSKeyedArchiver archive.
    public static func isKeyedArchive(_ v: PlistValue) -> Bool {
        guard let d = v.dict else { return false }
        return d["$objects"]?.array != nil && d["$top"]?.dict != nil
    }

    /// A keyed archive as plain values: dictionaries and other objects as `.dict` (objects keep
    /// their class name in "$class"), arrays, strings and data.
    public static func unarchive(_ archive: PlistValue) -> PlistValue {
        guard let d = archive.dict, let objects = d["$objects"]?.array, let top = d["$top"]?.dict else { return archive }
        var visiting: Set<Int> = []
        func resolve(_ v: PlistValue, _ depth: Int) -> PlistValue {
            guard depth < 100 else { return .null }
            switch v {
            case .uid(let i): return object(i, depth + 1)
            case .array(let a): return .array(a.map { resolve($0, depth + 1) })
            default: return v
            }
        }
        func object(_ index: Int, _ depth: Int) -> PlistValue {
            guard index >= 0, index < objects.count, visiting.insert(index).inserted else { return .null }
            defer { visiting.remove(index) }
            let raw = objects[index]
            if raw.string == "$null" { return .null }
            guard let o = raw.dict else { return raw }
            var className: String?
            if case .uid(let c)? = o["$class"], c < objects.count { className = objects[c].dict?["$classname"]?.string }
            if let keys = o["NS.keys"]?.array, let values = o["NS.objects"]?.array {
                var out: [String: PlistValue] = [:]
                for (k, v) in zip(keys, values) {
                    let key = resolve(k, depth)
                    out[key.string ?? "\(out.count)"] = resolve(v, depth)
                }
                return .dict(out)
            }
            if let values = o["NS.objects"]?.array { return .array(values.map { resolve($0, depth) }) }
            for key in ["NS.string", "NS.bytes", "NS.data", "NS.relative"] { if let v = o[key] { return resolve(v, depth) } }
            if case .real(let t)? = o["NS.time"] { return .date(Date(timeIntervalSinceReferenceDate: t)) }
            var out: [String: PlistValue] = ["$class": className.map(PlistValue.string) ?? .null]
            for (k, v) in o where k != "$class" { out[k] = resolve(v, depth) }
            return .dict(out)
        }
        if let root = top["root"] { return resolve(root, 0) }
        return .dict(top.mapValues { resolve($0, 0) })
    }

    /// Any bytes as a value: a binary plist (unarchived if it's a keyed archive), else nil.
    public static func decode(_ data: Data) -> PlistValue? {
        guard let v = parse(data) else { return nil }
        return isKeyedArchive(v) ? unarchive(v) : v
    }
}
