import Foundation
import Crypto

/// Plaintext inside a sealed inbox entry: `u32 headerLength | header JSON | body` (PROTOCOL.md §4).
public struct InboxEnvelope: Sendable, Equatable {
    public struct Header: Codable, Sendable, Equatable {
        public var v: Int = 1
        public var source: String          // email | webdav | web | ios | other
        public var receivedAt: String
        public var name: String?
        public var mime: String?
        public var url: String?
        public var title: String?
        public var groupId: String?
        public var meta: [String: JSONValue]?

        public init(source: String, receivedAt: Date = Date(), name: String? = nil, mime: String? = nil,
                    url: String? = nil, title: String? = nil, groupId: String? = nil, meta: [String: JSONValue]? = nil) {
            self.source = source
            self.receivedAt = ISO8601DateFormatter().string(from: receivedAt)
            self.name = name
            self.mime = mime
            self.url = url
            self.title = title
            self.groupId = groupId
            self.meta = meta
        }
    }

    public var header: Header
    public var body: Data

    public init(header: Header, body: Data) {
        self.header = header
        self.body = body
    }

    public func encoded() throws -> Data {
        let json = try JSONEncoder().encode(header)
        var out = Data()
        out.appendUInt32(UInt32(json.count))
        out.append(json)
        out.append(body)
        return out
    }

    public init(decoding data: Data) throws {
        let data = Data(data)
        guard data.count >= 4 else { throw TRV1.Failure.truncated }
        let length = Int(data.uint32(at: 0))
        guard data.count >= 4 + length else { throw TRV1.Failure.truncated }
        header = try JSONDecoder().decode(Header.self, from: data[4..<(4 + length)])
        body = Data(data[(4 + length)...])
    }

    /// Seal for the inbox (what the share extension and browser extensions do).
    public func sealed(for keys: VaultKeys) throws -> Data {
        try TRV1.seal(encoded(), to: keys.publicKey)
    }

    /// Seal with just the vault public key (b64u raw X25519), as extensions do.
    public func sealed(toPublicKey base64URL: String) throws -> Data {
        guard let raw = Data(base64URL: base64URL) else { throw TRV1.Failure.missingKey }
        return try TRV1.seal(encoded(), to: Curve25519.KeyAgreement.PublicKey(rawRepresentation: raw))
    }

    public static func open(_ sealed: Data, with keys: VaultKeys) throws -> InboxEnvelope {
        try InboxEnvelope(decoding: TRV1.unseal(sealed, with: keys.agreementKey))
    }
}
