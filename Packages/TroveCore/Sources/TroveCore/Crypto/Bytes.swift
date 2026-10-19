import Foundation
import Crypto

extension Data {
    /// base64url without padding (PROTOCOL.md).
    public var base64URL: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public init?(base64URL text: String) {
        var b64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        self.init(base64Encoded: b64)
    }

    public var hex: String { map { String(format: "%02x", $0) }.joined() }

    public var sha256Hex: String { Data(SHA256.hash(data: self)).hex }

    mutating func appendUInt32(_ value: UInt32) {
        var big = value.bigEndian
        Swift.withUnsafeBytes(of: &big) { append(contentsOf: $0) }
    }

    func uint32(at offset: Int) -> UInt32 {
        let i = startIndex + offset
        return self[i..<i + 4].reduce(0) { ($0 << 8) | UInt32($1) }
    }
}

extension String {
    public var sha256Hex: String { Data(utf8).sha256Hex }
}
