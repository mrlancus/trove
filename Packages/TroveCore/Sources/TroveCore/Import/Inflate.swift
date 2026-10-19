import Foundation
#if canImport(Compression)
import Compression
#endif

/// Raw DEFLATE (RFC 1951) decompression, for zip files. Apple platforms use the Compression
/// framework; elsewhere (Linux, where TroveCore is tested) a small canonical-Huffman decoder in the
/// style of zlib's puff.c does it.
public enum Inflate {
    public struct Corrupt: Error {}

    /// `expectedSize` is the size the zip says the output has; it's also the cap, so a lying entry
    /// can't balloon.
    public static func decompress(_ input: Data, expectedSize: Int) throws -> Data {
        #if canImport(Compression)
        if expectedSize > 0, let out = apple(input, expectedSize: expectedSize) { return out }
        #endif
        return try portable(input, limit: expectedSize)
    }

    #if canImport(Compression)
    private static func apple(_ input: Data, expectedSize: Int) -> Data? {
        var out = Data(count: expectedSize)
        let written = out.withUnsafeMutableBytes { dst in
            input.withUnsafeBytes { src in
                compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, expectedSize,
                                          src.bindMemory(to: UInt8.self).baseAddress!, input.count, nil, COMPRESSION_ZLIB)
            }
        }
        return written == expectedSize ? out : nil
    }
    #endif

    static func portable(_ input: Data, limit: Int) throws -> Data {
        var s = State(input: [UInt8](input), limit: limit)
        var last = false
        while !last {
            last = try s.bits(1) == 1
            switch try s.bits(2) {
            case 0: try s.stored()
            case 1: try s.codes(Self.fixed.lit, Self.fixed.dist)
            case 2:
                let (lit, dist) = try s.dynamicTables()
                try s.codes(lit, dist)
            default: throw Corrupt()
            }
        }
        return Data(s.out)
    }

    struct Huffman {
        var count = [Int](repeating: 0, count: 16)  // codes of each length
        var symbol: [Int] = []                      // symbols ordered by code

        /// Fails on over-subscribed lengths; incomplete codes are allowed (single distance codes are legal).
        init(_ lengths: ArraySlice<Int>) throws {
            for l in lengths { count[l] += 1 }
            var left = 1
            for len in 1..<16 {
                left = left * 2 - count[len]
                if left < 0 { throw Corrupt() }
            }
            var offs = [Int](repeating: 0, count: 16)
            for len in 1..<15 { offs[len + 1] = offs[len] + count[len] }
            symbol = [Int](repeating: 0, count: lengths.count)
            for (sym, l) in lengths.enumerated() where l != 0 {
                symbol[offs[l]] = sym
                offs[l] += 1
            }
        }
    }

    static let fixed: (lit: Huffman, dist: Huffman) = {
        var l = [Int](repeating: 8, count: 288)
        for i in 144..<256 { l[i] = 9 }
        for i in 256..<280 { l[i] = 7 }
        return (try! Huffman(l[...]), try! Huffman([Int](repeating: 5, count: 30)[...]))
    }()

    static let lengthBase = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
    static let lengthExtra = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
    static let distBase = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073,
                           4097, 6145, 8193, 12289, 16385, 24577]
    static let distExtra = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]
    static let codeOrder = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]

    struct State {
        let input: [UInt8]
        let limit: Int
        var pos = 0
        var bitBuf = 0
        var bitCount = 0
        var out: [UInt8] = []

        init(input: [UInt8], limit: Int) {
            self.input = input
            self.limit = limit
            out.reserveCapacity(min(limit, 64 << 20))
        }

        mutating func bits(_ need: Int) throws -> Int {
            var val = bitBuf
            while bitCount < need {
                guard pos < input.count else { throw Corrupt() }
                val |= Int(input[pos]) << bitCount
                pos += 1
                bitCount += 8
            }
            bitBuf = val >> need
            bitCount -= need
            return val & ((1 << need) - 1)
        }

        mutating func stored() throws {
            bitBuf = 0
            bitCount = 0
            guard pos + 4 <= input.count else { throw Corrupt() }
            let len = Int(input[pos]) | Int(input[pos + 1]) << 8
            let nlen = Int(input[pos + 2]) | Int(input[pos + 3]) << 8
            pos += 4
            guard len == ~nlen & 0xFFFF, pos + len <= input.count, out.count + len <= limit else { throw Corrupt() }
            out.append(contentsOf: input[pos..<pos + len])
            pos += len
        }

        mutating func decode(_ h: Huffman) throws -> Int {
            var code = 0, first = 0, index = 0
            for len in 1..<16 {
                code |= try bits(1)
                let count = h.count[len]
                if code - count < first { return h.symbol[index + (code - first)] }
                index += count
                first = (first + count) << 1
                code <<= 1
            }
            throw Corrupt()
        }

        mutating func codes(_ lit: Huffman, _ dist: Huffman) throws {
            while true {
                let sym = try decode(lit)
                if sym < 256 {
                    guard out.count < limit else { throw Corrupt() }
                    out.append(UInt8(sym))
                } else if sym == 256 {
                    return
                } else {
                    let i = sym - 257
                    guard i < 29 else { throw Corrupt() }
                    let len = Inflate.lengthBase[i] + (try bits(Inflate.lengthExtra[i]))
                    let d = try decode(dist)
                    guard d < 30 else { throw Corrupt() }
                    let back = Inflate.distBase[d] + (try bits(Inflate.distExtra[d]))
                    guard back <= out.count, out.count + len <= limit else { throw Corrupt() }
                    let start = out.count - back
                    for k in 0..<len { out.append(out[start + k]) }
                }
            }
        }

        mutating func dynamicTables() throws -> (Huffman, Huffman) {
            let nlen = try bits(5) + 257, ndist = try bits(5) + 1, ncode = try bits(4) + 4
            guard nlen <= 286, ndist <= 30 else { throw Corrupt() }
            var lengths = [Int](repeating: 0, count: 19)
            for i in 0..<ncode { lengths[Inflate.codeOrder[i]] = try bits(3) }
            let lencode = try Huffman(lengths[...])
            lengths = []
            while lengths.count < nlen + ndist {
                let sym = try decode(lencode)
                switch sym {
                case 0..<16: lengths.append(sym)
                case 16:
                    guard let prev = lengths.last else { throw Corrupt() }
                    lengths += repeatElement(prev, count: 3 + (try bits(2)))
                case 17: lengths += repeatElement(0, count: 3 + (try bits(3)))
                default: lengths += repeatElement(0, count: 11 + (try bits(7)))
                }
            }
            guard lengths.count == nlen + ndist, lengths[256] != 0 else { throw Corrupt() }
            return (try Huffman(lengths[0..<nlen]), try Huffman(lengths[nlen...]))
        }
    }
}
