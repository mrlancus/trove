import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Typed client for the Cloudflare relay (PROTOCOL.md §4).
public struct RelayClient: Sendable {
    public let baseURL: URL
    public let vaultId: String?
    public let token: String?
    let session: URLSession

    public init(baseURL: URL, vaultId: String? = nil, token: String? = nil, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.vaultId = vaultId
        self.token = token
        self.session = session
    }

    // MARK: Types

    public struct Registration: Codable, Sendable, Equatable {
        public var vaultId: String
        public var deviceId: String
        public var deviceToken: String
        public var inboxToken: String?
    }

    public struct Pairing: Codable, Sendable { public var pairingCode: String; public var expiresAt: String }

    public struct Device: Codable, Sendable, Equatable, Identifiable {
        public var deviceId: String
        public var name: String
        public var kind: String
        public var createdAt: Double
        public var lastSeenAt: Double
        public var revoked: Bool
        public var id: String { deviceId }
    }

    public struct SegmentEntry: Codable, Sendable, Equatable {
        public var cursor: Int
        public var device: String
        public var first: Int
        public var last: Int
        public var size: Int
        public var ref: SegmentRef { SegmentRef(device: device, first: first, last: last) }
    }

    public struct InboxEntry: Codable, Sendable, Equatable, Identifiable {
        public var cursor: Int
        public var id: String
        public var size: Int
        public var source: String
        public var davPath: String?
        public var createdAt: String
    }

    public struct Enrichment: Codable, Sendable, Equatable {
        public var title: String
        public var summary: String
        public var tags: [String]
        public var kind: String
        public var truncated: Bool?
        public var model: String?
    }

    public struct Answer: Codable, Sendable, Equatable {
        public var answer: String
        public var citations: [String]
        public var omittedSources: Int?
        public var model: String?
    }

    /// A price-drop watch (PROTOCOL.md §5). Times are Unix milliseconds.
    public struct Watch: Codable, Sendable, Equatable, Identifiable {
        public struct Point: Codable, Sendable, Equatable { public var at: Double; public var price: Double }
        public var id: String
        public var url: String
        public var itemId: String?
        public var createdAt: Double
        public var checkedAt: Double?
        public var error: String?
        public var price: Double?
        public var currency: String?
        public var lowest: Double?
        public var history: [Point]
        public var droppedAt: Double?
    }

    /// A note published to a public link (PROTOCOL.md §6).
    public struct PublishedPage: Codable, Sendable, Equatable, Identifiable {
        public var slug: String
        public var title: String?
        public var updatedAt: Double?
        public var path: String
        public var id: String { slug }
    }

    /// A bridge run by the relay (PROTOCOL.md §4 "Bridges"). Tokens are never sent back.
    public struct Bridge: Codable, Sendable, Equatable, Identifiable {
        public struct Status: Codable, Sendable, Equatable {
            public var lastRunAt: Double?
            public var nextRunAt: Double?
            public var lastError: String?
            public var lastErrorAt: Double?
            public var itemsAdded: Int
            public var lastAddedAt: Double?
        }
        public struct Telegram: Codable, Sendable, Equatable {
            public var bot: String?
            public var linked: Bool
            public var linkURL: String?
        }
        public var id: String
        /// "webhook", "rss", "github" or "telegram".
        public var kind: String
        public var enabled: Bool
        public var settings: [String: JSONValue]
        public var hasToken: Bool
        public var createdAt: Double
        public var status: Status
        /// Webhook: the secret "add" address.
        public var hookURL: String?
        /// RSS: the feed's own title.
        public var title: String?
        public var telegram: Telegram?

        public func setting(_ key: String) -> String? { settings[key]?.string }
        public func flag(_ key: String) -> Bool { settings[key]?.bool ?? false }
    }

    /// What `POST /preview` returns for a link (any field may be missing).
    public struct LinkPreview: Codable, Sendable, Equatable {
        public var url: String
        public var title: String?
        public var description: String?
        public var image: String?
        public var site: String?
        public var icon: String?
        public var error: String?
    }

    // MARK: Vault lifecycle

    /// `deviceId`: the journal id this device already uses (kept if free on the relay).
    public static func createVault(baseURL: URL, publicKey: String, deviceName: String, deviceKind: String, deviceId: String? = nil,
                                   session: URLSession = .shared) async throws -> Registration {
        let client = RelayClient(baseURL: baseURL, session: session)
        var body: [String: Any] = ["vaultPublicKey": publicKey, "deviceName": deviceName, "deviceKind": deviceKind]
        if let deviceId { body["deviceId"] = deviceId }
        return try await client.json("POST", "/v1/vaults", body: body, expect: [201])
    }

    public static func join(baseURL: URL, vaultId: String, pairingCode: String, deviceName: String, deviceKind: String, deviceId: String? = nil,
                            session: URLSession = .shared) async throws -> Registration {
        let client = RelayClient(baseURL: baseURL, vaultId: vaultId, session: session)
        struct Joined: Decodable { var deviceId: String; var deviceToken: String }
        var body: [String: Any] = ["pairingCode": pairingCode, "deviceName": deviceName, "deviceKind": deviceKind]
        if let deviceId { body["deviceId"] = deviceId }
        let joined: Joined = try await client.json("POST", "/v1/vaults/\(vaultId)/devices", body: body, expect: [201])
        return Registration(vaultId: vaultId, deviceId: joined.deviceId, deviceToken: joined.deviceToken, inboxToken: nil)
    }

    public func createPairing() async throws -> Pairing { try await json("POST", vaultPath("pairings"), expect: [201]) }

    public func devices() async throws -> [Device] {
        struct List: Decodable { var devices: [Device] }
        let list: List = try await json("GET", vaultPath("devices"))
        return list.devices
    }

    public func revoke(device: String) async throws {
        _ = try await raw("DELETE", vaultPath("devices/\(device)"), expect: [204])
    }

    public func newInboxToken() async throws -> String {
        struct T: Decodable { var inboxToken: String }
        let t: T = try await json("POST", vaultPath("inbox-tokens"), expect: [201])
        return t.inboxToken
    }

    public func setAIEnabled(_ enabled: Bool) async throws {
        struct S: Decodable { var aiEnabled: Bool }
        let _: S = try await json("PUT", vaultPath("settings"), body: ["aiEnabled": enabled])
    }

    // MARK: Segments & blobs

    public func segments(after cursor: Int, limit: Int = 200) async throws -> (entries: [SegmentEntry], more: Bool) {
        struct Page: Decodable { var segments: [SegmentEntry]; var more: Bool }
        let page: Page = try await json("GET", vaultPath("segments?after=\(cursor)&limit=\(limit)"))
        return (page.segments, page.more)
    }

    public func getSegment(_ ref: SegmentRef) async throws -> Data {
        try await raw("GET", vaultPath("segments/\(ref.device)/\(ref.first)/\(ref.last)"))
    }

    @discardableResult
    public func putSegment(_ ref: SegmentRef, data: Data) async throws -> Int {
        struct C: Decodable { var cursor: Int }
        let out = try await raw("PUT", vaultPath("segments/\(ref.device)/\(ref.first)/\(ref.last)"), body: data, expect: [200, 201])
        return try JSONDecoder().decode(C.self, from: out).cursor
    }

    public func putBlob(_ id: String, data: Data) async throws {
        _ = try await raw("PUT", vaultPath("blobs/\(id)"), body: data, expect: [200, 201])
    }

    public func getBlob(_ id: String) async throws -> Data { try await raw("GET", vaultPath("blobs/\(id)")) }

    // MARK: Inbox

    /// Upload an already-sealed envelope (an inbox token is enough).
    public func postInbox(sealed: Data, source: String) async throws -> String {
        struct R: Decodable { var id: String }
        let out = try await raw("POST", vaultPath("inbox"), body: sealed, headers: ["x-trove-source": source], expect: [201])
        return try JSONDecoder().decode(R.self, from: out).id
    }

    public func inbox(after cursor: Int = 0) async throws -> [InboxEntry] {
        struct Page: Decodable { var entries: [InboxEntry] }
        let page: Page = try await json("GET", vaultPath("inbox?after=\(cursor)"))
        return page.entries
    }

    public func inboxEntry(_ id: String) async throws -> Data { try await raw("GET", vaultPath("inbox/\(id)")) }

    public func ackInbox(_ id: String) async throws { _ = try await raw("DELETE", vaultPath("inbox/\(id)"), expect: [204]) }

    // MARK: AI (opt-in, plaintext leaves the device)

    public func enrich(text: String, url: String? = nil, title: String? = nil) async throws -> Enrichment {
        var body: [String: Any] = ["text": text]
        if let url { body["url"] = url }
        if let title { body["title"] = title }
        return try await json("POST", vaultPath("ai/enrich"), body: body)
    }

    public func ask(_ question: String, sources: [(id: String, text: String)]) async throws -> Answer {
        try await json("POST", vaultPath("ai/ask"), body: ["question": question, "sources": sources.map { ["id": $0.id, "text": $0.text] }])
    }

    public func transcribe(audio: Data) async throws -> String {
        struct T: Decodable { var text: String }
        return try JSONDecoder().decode(T.self, from: try await raw("POST", vaultPath("ai/transcribe"), body: audio)).text
    }

    public func embed(_ texts: [String]) async throws -> [[Double]] {
        struct E: Decodable { var vectors: [[Double]] }
        let e: E = try await json("POST", vaultPath("ai/embed"), body: ["texts": texts])
        return e.vectors
    }

    // MARK: Price watches (the relay sees the product URL only)

    public func watches() async throws -> [Watch] {
        struct L: Decodable { var watches: [Watch] }
        let l: L = try await json("GET", vaultPath("watches"))
        return l.watches
    }

    @discardableResult
    public func putWatch(id: String, url: String, itemId: String? = nil) async throws -> Watch {
        var body: [String: Any] = ["url": url]
        if let itemId { body["itemId"] = itemId }
        return try await json("PUT", vaultPath("watches/\(id)"), body: body, expect: [200, 201])
    }

    public func deleteWatch(id: String) async throws { _ = try await raw("DELETE", vaultPath("watches/\(id)"), expect: [204]) }

    // MARK: Publish to link (the page is public plaintext by the user's choice)

    /// A random, unguessable slug for a new link.
    public static func newSlug() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        return Data(bytes).base64URL
    }

    /// Publishes (or updates) a page and returns its public URL.
    public func publish(slug: String, title: String, markdown: String) async throws -> URL {
        struct P: Decodable { var path: String }
        let p: P = try await json("PUT", vaultPath("published/\(slug)"), body: ["title": title, "markdown": markdown], expect: [201])
        guard let url = URL(string: p.path, relativeTo: baseURL)?.absoluteURL else { throw TransportError.invalidResponse }
        return url
    }

    public func unpublish(slug: String) async throws { _ = try await raw("DELETE", vaultPath("published/\(slug)"), expect: [204]) }

    public func publishedPages() async throws -> [PublishedPage] {
        struct L: Decodable { var pages: [PublishedPage] }
        let l: L = try await json("GET", vaultPath("published"))
        return l.pages
    }

    // MARK: Bridges (PROTOCOL.md §4 "Bridges")

    public func bridges() async throws -> [Bridge] {
        struct L: Decodable { var bridges: [Bridge] }
        let l: L = try await json("GET", vaultPath("bridges"))
        return l.bridges
    }

    /// `settings` holds strings, booleans and string arrays; `token` is for Telegram (required) or GitHub.
    public func addBridge(kind: String, settings: [String: Any] = [:], token: String? = nil) async throws -> Bridge {
        var body: [String: Any] = ["kind": kind, "settings": settings]
        if let token { body["token"] = token }
        return try await json("POST", vaultPath("bridges"), body: body, expect: [201])
    }

    /// Changes only what's given. A GitHub `token` of "" removes the stored token.
    public func updateBridge(_ id: String, enabled: Bool? = nil, settings: [String: Any]? = nil, token: String? = nil) async throws -> Bridge {
        var body: [String: Any] = [:]
        if let enabled { body["enabled"] = enabled }
        if let settings { body["settings"] = settings }
        if let token { body["token"] = token }
        return try await json("PUT", vaultPath("bridges/\(id)"), body: body)
    }

    public func deleteBridge(_ id: String) async throws { _ = try await raw("DELETE", vaultPath("bridges/\(id)"), expect: [204]) }

    /// Checks a feed or GitHub bridge now.
    public func runBridge(_ id: String) async throws -> Bridge { try await json("POST", vaultPath("bridges/\(id)/run"), body: [:]) }

    /// A new secret address for a webhook or Telegram bridge; the old one stops working.
    public func regenerateBridge(_ id: String) async throws -> Bridge { try await json("POST", vaultPath("bridges/\(id)/regenerate"), body: [:]) }

    /// Title, description, picture and site for a link, fetched by the relay.
    public func linkPreview(_ url: String) async throws -> LinkPreview { try await json("POST", vaultPath("preview"), body: ["url": url]) }

    /// WebSocket URL for live notifications (open with URLSessionWebSocketTask in the app).
    public var liveURL: URL? {
        guard let vaultId, let token, var c = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return nil }
        c.scheme = c.scheme == "http" ? "ws" : "wss"
        c.path = "/v1/vaults/\(vaultId)/live"
        c.queryItems = [URLQueryItem(name: "token", value: token)]
        return c.url
    }

    /// GoodNotes Auto Backup settings for this vault.
    public func webDAVSettings(inboxToken: String) -> (server: String, username: String, password: String)? {
        guard let vaultId else { return nil }
        return (baseURL.appendingPathComponent("dav").absoluteString + "/", vaultId, inboxToken)
    }

    // MARK: Plumbing

    func vaultPath(_ suffix: String) -> String { "/v1/vaults/\(vaultId ?? "")/\(suffix)" }

    func raw(_ method: String, _ path: String, body: Data? = nil, headers: [String: String] = [:], expect: Set<Int> = [200]) async throws -> Data {
        guard let url = URL(string: path, relativeTo: baseURL) else { throw TransportError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        if let body {
            request.httpBody = body
            request.setValue(String(body.count), forHTTPHeaderField: "Content-Length")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw TransportError.invalidResponse }
        if http.statusCode == 404 { throw TransportError.notFound }
        if http.statusCode == 409 { throw TransportError.conflict(String(decoding: data, as: UTF8.self)) }
        guard expect.contains(http.statusCode) else {
            throw TransportError.http(http.statusCode, String(decoding: data.prefix(500), as: UTF8.self))
        }
        return data
    }

    func json<T: Decodable>(_ method: String, _ path: String, body: [String: Any]? = nil, expect: Set<Int> = [200]) async throws -> T {
        let data = try body.map { try JSONSerialization.data(withJSONObject: $0) }
        let out = try await raw(method, path, body: data, headers: data == nil ? [:] : ["Content-Type": "application/json"], expect: expect)
        return try JSONDecoder().decode(T.self, from: out)
    }
}

/// The relay as a `SyncTransport`. Remembers how far through the relay's segment list it has read.
public final class RelayTransport: SyncTransport, @unchecked Sendable {
    public let client: RelayClient
    public var name: String { "relay" }
    private let lock = NSLock()
    private var cursor: Int
    private var pendingCursor: Int?
    private let saveCursor: @Sendable (Int) -> Void

    public init(client: RelayClient, cursor: Int = 0, saveCursor: @escaping @Sendable (Int) -> Void = { _ in }) {
        self.client = client
        self.cursor = cursor
        self.saveCursor = saveCursor
    }

    public var currentCursor: Int { lock.withLock { cursor } }

    public func listSegments() async throws -> [SegmentRef] {
        var after = currentCursor
        var refs: [SegmentRef] = []
        while true {
            let page = try await client.segments(after: after)
            refs += page.entries.map(\.ref)
            after = page.entries.last?.cursor ?? after
            if !page.more { break }
        }
        lock.withLock { pendingCursor = after }
        return refs
    }

    /// Called by the engine once every listed segment has been applied.
    public func commitCursor() {
        let value: Int? = lock.withLock {
            guard let p = pendingCursor else { return nil }
            cursor = max(cursor, p)
            pendingCursor = nil
            return cursor
        }
        if let value { saveCursor(value) }
    }

    public func fetchSegment(_ ref: SegmentRef) async throws -> Data { try await client.getSegment(ref) }
    public func pushSegment(_ ref: SegmentRef, data: Data) async throws { try await client.putSegment(ref, data: data) }
    public func hasBlob(_ id: String) async throws -> Bool { false } // PUT is idempotent
    public func pushBlob(_ id: String, data: Data) async throws { try await client.putBlob(id, data: data) }
    public func fetchBlob(_ id: String) async throws -> Data { try await client.getBlob(id) }
}
