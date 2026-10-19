import Foundation

/// Reads .zip archives (stored and deflated entries, Zip64), so exports from Notion, Obsidian,
/// Google Takeout, Pocket and others can be imported in one go.
public struct ZipArchive: Sendable {
    public struct Entry: Sendable, Equatable {
        public let path: String
        public let method: Int
        public let crc32: UInt32
        public let compressedSize: Int
        public let size: Int
        public let isEncrypted: Bool
        let localHeaderOffset: Int

        public var isDirectory: Bool { path.hasSuffix("/") }
        public var name: String { path.split(separator: "/").last.map(String.init) ?? path }
    }

    public enum Failure: Error, Equatable { case notAZip, corrupt, unsupported(String) }

    public let entries: [Entry]
    private let data: Data

    public static func isZip(_ data: Data) -> Bool { data.starts(with: [0x50, 0x4B, 0x03, 0x04]) || data.starts(with: [0x50, 0x4B, 0x05, 0x06]) }

    public init(_ data: Data) throws {
        let data = data.startIndex == 0 ? data : Data(data)
        self.data = data
        // End of central directory: the last "PK\5\6" within the final 64 KB + 22 bytes.
        let floor = max(0, data.count - 65_557)
        guard data.count >= 22 else { throw Failure.notAZip }
        var eocd = data.count - 22
        while eocd >= floor, data.u32(eocd) != 0x0605_4B50 { eocd -= 1 }
        guard eocd >= floor else { throw Failure.notAZip }
        var count = Int(data.u16(eocd + 10))
        var cdOffset = Int(data.u32(eocd + 16))
        if count == 0xFFFF || cdOffset == 0xFFFF_FFFF {
            // Zip64: a locator just before the EOCD points at the Zip64 end record.
            let locator = eocd - 20
            guard locator >= 0, data.u32(locator) == 0x0706_4B50 else { throw Failure.corrupt }
            let end = Int(data.u64(locator + 8))
            guard end >= 0, end + 56 <= data.count, data.u32(end) == 0x0606_4B50 else { throw Failure.corrupt }
            count = Int(data.u64(end + 32))
            cdOffset = Int(data.u64(end + 48))
        }
        var entries: [Entry] = []
        var p = cdOffset
        for _ in 0..<count {
            guard p >= 0, p + 46 <= data.count, data.u32(p) == 0x0201_4B50 else { throw Failure.corrupt }
            let flags = data.u16(p + 8)
            let nameLen = Int(data.u16(p + 28)), extraLen = Int(data.u16(p + 30)), commentLen = Int(data.u16(p + 32))
            guard p + 46 + nameLen + extraLen <= data.count else { throw Failure.corrupt }
            let nameBytes = data[(p + 46)..<(p + 46 + nameLen)]
            // Names are UTF-8 when flagged, and in practice usually even when not; else Latin-1.
            let path = String(data: nameBytes, encoding: .utf8) ?? String(data: nameBytes, encoding: .isoLatin1) ?? ""
            var csize = Int(data.u32(p + 20)), usize = Int(data.u32(p + 24)), offset = Int(data.u32(p + 42))
            // Zip64 extra field: the 64-bit values, in order, for whichever fields were maxed out.
            var e = p + 46 + nameLen
            let extraEnd = e + extraLen
            while e + 4 <= extraEnd {
                let id = data.u16(e), size = Int(data.u16(e + 2))
                if id == 0x0001 {
                    var q = e + 4
                    if usize == 0xFFFF_FFFF, q + 8 <= extraEnd { usize = Int(data.u64(q)); q += 8 }
                    if csize == 0xFFFF_FFFF, q + 8 <= extraEnd { csize = Int(data.u64(q)); q += 8 }
                    if offset == 0xFFFF_FFFF, q + 8 <= extraEnd { offset = Int(data.u64(q)) }
                }
                e += 4 + size
            }
            entries.append(Entry(path: path, method: Int(data.u16(p + 10)), crc32: data.u32(p + 16), compressedSize: csize,
                                 size: usize, isEncrypted: flags & 1 != 0, localHeaderOffset: offset))
            p += 46 + nameLen + extraLen + commentLen
        }
        self.entries = entries
    }

    /// The entry's contents, checked against its CRC.
    public func data(for entry: Entry) throws -> Data {
        guard !entry.isEncrypted else { throw Failure.unsupported("encrypted") }
        let h = entry.localHeaderOffset
        guard h >= 0, h + 30 <= data.count, data.u32(h) == 0x0403_4B50 else { throw Failure.corrupt }
        let start = h + 30 + Int(data.u16(h + 26)) + Int(data.u16(h + 28))
        guard start + entry.compressedSize <= data.count else { throw Failure.corrupt }
        let raw = data[start..<(start + entry.compressedSize)]
        let out: Data
        switch entry.method {
        case 0: out = Data(raw)
        case 8: out = try Inflate.decompress(Data(raw), expectedSize: entry.size)
        default: throw Failure.unsupported("compression method \(entry.method)")
        }
        guard out.count == entry.size, CRC32.checksum(out) == entry.crc32 else { throw Failure.corrupt }
        return out
    }
}

enum CRC32 {
    static let table: [UInt32] = (0..<256).map { n in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func checksum(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { buf in
            for b in buf { c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        }
        return c ^ 0xFFFF_FFFF
    }
}

private extension Data {
    func u16(_ i: Int) -> UInt16 { UInt16(self[i]) | UInt16(self[i + 1]) << 8 }
    func u32(_ i: Int) -> UInt32 { UInt32(u16(i)) | UInt32(u16(i + 2)) << 16 }
    func u64(_ i: Int) -> UInt64 { UInt64(u32(i)) | UInt64(u32(i + 4)) << 32 }
}
