import Foundation
import Crypto

/// Plaintext inside a sealed inbox entry: `u32 headerLength | header JSON | body` (PROTOCOL.md §4).
public struct InboxEnvelope: Sendable, Equatable {
    public struct Header: Codable, Sendable, Equatable {
        public var v: Int = 1
        public var source: String          // email | webdav | web | ios | other | rss | github | telegram | webhook
        public var receivedAt: String
        public var name: String?
        public var mime: String?
        public var url: String?
        public var title: String?
        public var groupId: String?
        /// Bridges: the folder path to file the item in (PROTOCOL.md §4 "Bridges").
        public var folder: [String]?
        /// Bridges: tags to add to the item.
        public var tags: [String]?
        public var meta: [String: JSONValue]?

        public init(source: String, receivedAt: Date = Date(), name: String? = nil, mime: String? = nil,
                    url: String? = nil, title: String? = nil, groupId: String? = nil, folder: [String]? = nil,
                    tags: [String]? = nil, meta: [String: JSONValue]? = nil) {
            self.source = source
            self.receivedAt = ISO8601DateFormatter().string(from: receivedAt)
            self.name = name
            self.mime = mime
            self.url = url
            self.title = title
            self.groupId = groupId
            self.folder = folder
            self.tags = tags
            self.meta = meta
        }

        enum CodingKeys: String, CodingKey {
            case v, source, receivedAt, name, mime, url, title, groupId, folder, tags, meta
        }

        /// Lenient: an odd `folder`, `tags` or `meta` never makes the whole entry unreadable.
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            v = (try? c.decodeIfPresent(Int.self, forKey: .v)) ?? 1
            source = try c.decode(String.self, forKey: .source)
            receivedAt = (try? c.decodeIfPresent(String.self, forKey: .receivedAt)) ?? ""
            name = try? c.decodeIfPresent(String.self, forKey: .name)
            mime = try? c.decodeIfPresent(String.self, forKey: .mime)
            url = try? c.decodeIfPresent(String.self, forKey: .url)
            title = try? c.decodeIfPresent(String.self, forKey: .title)
            groupId = try? c.decodeIfPresent(String.self, forKey: .groupId)
            meta = try? c.decodeIfPresent([String: JSONValue].self, forKey: .meta)
            folder = Self.strings(c, .folder, separator: "/")
            tags = Self.strings(c, .tags, separator: ",")
        }

        private static func strings(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys, separator: Character) -> [String]? {
            if let list = try? c.decodeIfPresent(JSONValue.self, forKey: key) {
                if case .string(let text) = list { return text.split(separator: separator).map(String.init) }
                return list.stringArray
            }
            return nil
        }

        /// The folder path asked for: trimmed, no empty parts, at most 5 deep (`inboxFolder` in vault.js).
        public var folderPath: [String] {
            Array((folder ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.prefix(5))
        }

        /// The tags asked for: lowercased, without '#', no repeats (`inboxTags` in vault.js).
        public var tagList: [String] {
            var out: [String] = []
            for raw in tags ?? [] {
                var tag = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if tag.hasPrefix("#") { tag.removeFirst() }
                tag = tag.lowercased()
                if !tag.isEmpty, !out.contains(tag) { out.append(tag) }
            }
            return out
        }
    }

    /// Sources used by bridges (PROTOCOL.md §4 "Bridges").
    public static let bridgeSources: Set<String> = ["rss", "github", "telegram", "webhook"]

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
