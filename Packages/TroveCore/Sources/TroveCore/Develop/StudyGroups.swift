import Foundation
import Crypto

/// Study with friends (PROTOCOL.md §4 "Study groups", DEVELOP_PLAN Appendix F): small private groups that
/// practise the same catalogue questions as a challenge. Everything a friend sees is encrypted under the group key;
/// the relay keeps only ciphertext, random ids and counts.
public enum StudyGroup {
    public static let membershipKind = "group"
    public static func membershipId(_ groupId: String) -> String { "group.\(groupId)" }

    // MARK: Keys

    /// The key entries are sealed with: HKDF(GK, "trove/v1/group-entry").
    public static func entryKey(_ groupKey: SymmetricKey) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: groupKey, info: Data("trove/v1/group-entry".utf8), outputByteCount: 32)
    }

    public static func newGroupKey() -> SymmetricKey { SymmetricKey(size: .bits256) }

    /// An entry body: the payload's JSON as TRV1 under the epoch's entry key.
    public static func seal<T: Encodable>(_ payload: T, groupKey: SymmetricKey) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try TRV1.encrypt(encoder.encode(payload), key: entryKey(groupKey))
    }

    public static func open<T: Decodable>(_ body: Data, as type: T.Type, groupKey: SymmetricKey) throws -> T {
        try JSONDecoder().decode(type, from: TRV1.decrypt(body, key: entryKey(groupKey)))
    }

    /// A new group key sealed to a member's public key (TRV1 mode 2), for the relay to hand them.
    public static func box(_ groupKey: SymmetricKey, to memberKey: String) throws -> String {
        guard let raw = Data(base64URL: memberKey) else { throw TRV1.Failure.missingKey }
        let bytes = groupKey.withUnsafeBytes { Data($0) }
        return try TRV1.seal(bytes, to: Curve25519.KeyAgreement.PublicKey(rawRepresentation: raw)).base64URL
    }

    public static func unbox(_ box: String, with memberPrivate: Curve25519.KeyAgreement.PrivateKey) throws -> SymmetricKey {
        guard let data = Data(base64URL: box) else { throw TRV1.Failure.truncated }
        return SymmetricKey(data: try TRV1.unseal(data, with: memberPrivate))
    }

    // MARK: Invite links

    /// `https://<relay>/join#g=<group>&i=<invite>&k=<GK>&e=<epoch>`; the fragment never reaches the relay.
    public struct Invite: Sendable, Equatable {
        public var relay: URL
        public var groupId: String
        public var secret: String
        public var key: Data
        public var epoch: Int

        public init(relay: URL, groupId: String, secret: String, key: Data, epoch: Int) {
            self.relay = relay; self.groupId = groupId; self.secret = secret; self.key = key; self.epoch = epoch
        }

        public var link: URL {
            var c = URLComponents(url: relay, resolvingAgainstBaseURL: false)!
            c.path = "/join"
            c.query = nil
            c.fragment = "g=\(groupId)&i=\(secret)&k=\(key.base64URL)&e=\(epoch)"
            return c.url!
        }

        /// From a pasted `https://…/join#…` link or the app's `trove://join#…&r=<relay>`.
        public init?(link text: String) {
            guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), let fragment = url.fragment else { return nil }
            var fields: [String: String] = [:]
            for pair in fragment.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
                if kv.count == 2 { fields[kv[0]] = kv[1].removingPercentEncoding ?? kv[1] }
            }
            let relay: URL?
            if url.scheme == "trove" { relay = fields["r"].flatMap(URL.init(string:)) }
            else if let scheme = url.scheme, let host = url.host { relay = URL(string: "\(scheme)://\(host)\(url.port.map { ":\($0)" } ?? "")") }
            else { relay = nil }
            guard let relay, let g = fields["g"], !g.isEmpty, let i = fields["i"], !i.isEmpty,
                  let k = fields["k"].flatMap(Data.init(base64URL:)), k.count == 32, let e = fields["e"].flatMap(Int.init), e >= 1 else { return nil }
            self.init(relay: relay, groupId: g, secret: i, key: k, epoch: e)
        }
    }

    // MARK: What's shared (entry bodies, all v1)

    public struct Profile: Codable, Sendable, Equatable { public var v = 1; public var name: String; public init(name: String) { self.name = name } }
    public struct About: Codable, Sendable, Equatable { public var v = 1; public var name: String; public init(name: String) { self.name = name } }

    /// Only catalogue questions, as doc ids and keys: each device downloads the paper from the board.
    public struct Question: Codable, Sendable, Equatable, Hashable {
        public var doc: String
        public var key: String
        public var marks: Int?
        public init(doc: String, key: String, marks: Int? = nil) { self.doc = doc; self.key = key; self.marks = marks }
    }

    public struct Challenge: Codable, Sendable, Equatable, Identifiable {
        public enum Mode: String, Codable, Sendable { case deadline, live }
        public var v = 1
        public var id: String
        public var title: String
        public var questions: [Question]
        public var mode: Mode
        public var deadline: Date?
        public var minutes: Int?
        public init(id: String = UUID().uuidString.lowercased(), title: String, questions: [Question], mode: Mode, deadline: Date? = nil, minutes: Int? = nil) {
            self.id = id; self.title = title; self.questions = questions; self.mode = mode; self.deadline = deadline; self.minutes = minutes
        }
    }

    public struct Start: Codable, Sendable, Equatable { public var v = 1; public var challenge: String; public var at: Date
        public init(challenge: String, at: Date) { self.challenge = challenge; self.at = at } }

    /// How an answer was marked. Shown with every result.
    public enum HowMarked: String, Codable, Sendable { case `self`, ai, none, peer }

    public struct Answer: Codable, Sendable, Equatable {
        public var doc: String
        public var key: String
        public var text: String?
        public var marks: Double?
        public var of: Int?
        public var seconds: Int
        public var hints: Int
        public var marking: HowMarked
        public init(doc: String, key: String, text: String? = nil, marks: Double? = nil, of: Int? = nil, seconds: Int, hints: Int, marking: HowMarked) {
            self.doc = doc; self.key = key; self.text = text; self.marks = marks; self.of = of; self.seconds = seconds; self.hints = hints; self.marking = marking
        }
    }

    public struct Submission: Codable, Sendable, Equatable {
        public var v = 1
        public var challenge: String
        public var answers: [Answer]
        public var submittedAt: Date
        public init(challenge: String, answers: [Answer], submittedAt: Date) { self.challenge = challenge; self.answers = answers; self.submittedAt = submittedAt }
    }

    /// A friend's marks for one of my answers: they saw my answer and the board's mark scheme, never my files.
    public struct Mark: Codable, Sendable, Equatable {
        public var v = 1
        public var challenge: String
        public var member: String
        public var doc: String
        public var key: String
        public var marks: Double
        public var of: Int
        public var note: String?
        public init(challenge: String, member: String, doc: String, key: String, marks: Double, of: Int, note: String? = nil) {
            self.challenge = challenge; self.member = member; self.doc = doc; self.key = key; self.marks = marks; self.of = of; self.note = note
        }
    }

    // MARK: Results

    /// One member's line for one question of a challenge.
    public struct Result: Sendable, Equatable {
        public var member: String
        public var answer: Answer
        /// Friends' marks for it, by marker.
        public var peerMarks: [String: Mark]
    }

    /// Per question: everyone's answer, but only once I've submitted (no peeking). Nil means "not yet".
    public static func results(for challenge: Challenge, submissions: [String: Submission], marks: [(by: String, mark: Mark)], me: String) -> [Question: [Result]]? {
        guard submissions[me] != nil else { return nil }
        var out: [Question: [Result]] = [:]
        for q in challenge.questions {
            out[q] = submissions.keys.sorted().compactMap { member in
                guard let a = submissions[member]?.answers.first(where: { $0.doc == q.doc && $0.key == q.key }) else { return nil }
                var peers: [String: Mark] = [:]
                for (by, m) in marks where m.challenge == challenge.id && m.member == member && m.doc == q.doc && m.key == q.key { peers[by] = m }
                return Result(member: member, answer: a, peerMarks: peers)
            }
        }
        return out
    }

    /// A simple total for one member: marks over marks available, counting only marked answers.
    public static func total(_ s: Submission) -> (marks: Double, of: Int) {
        s.answers.reduce((0, 0)) { t, a in
            guard let m = a.marks, let of = a.of else { return t }
            return (t.0 + m, t.1 + of)
        }
    }
}

/// My membership of a group, kept as a record in my own vault (synced to my devices, encrypted like the rest).
public struct GroupMembership: Codable, Sendable, Equatable, Identifiable {
    public var relay: URL
    public var groupId: String
    public var memberId: String
    public var memberToken: String
    /// My X25519 private key for this group (b64u raw).
    public var memberPrivate: String
    /// Every group key I've had, by epoch (b64u).
    public var keys: [String: String]
    public var name: String
    public var myName: String
    public var creator: Bool
    public var joinedAt: Date
    public var id: String { groupId }

    public init(relay: URL, groupId: String, memberId: String, memberToken: String, memberPrivate: String, keys: [String: String], name: String, myName: String, creator: Bool, joinedAt: Date) {
        self.relay = relay; self.groupId = groupId; self.memberId = memberId; self.memberToken = memberToken; self.memberPrivate = memberPrivate
        self.keys = keys; self.name = name; self.myName = myName; self.creator = creator; self.joinedAt = joinedAt
    }

    public var epoch: Int { keys.keys.compactMap(Int.init).max() ?? 1 }
    public func key(_ epoch: Int) -> SymmetricKey? { keys[String(epoch)].flatMap(Data.init(base64URL:)).map(SymmetricKey.init(data:)) }
    public var privateKey: Curve25519.KeyAgreement.PrivateKey? {
        Data(base64URL: memberPrivate).flatMap { try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: $0) }
    }
}

extension Library {
    public func groupMemberships() async -> [GroupMembership] {
        await engine.records(kind: StudyGroup.membershipKind).compactMap { r in
            guard let json = r.fields["membership"]?.string, let data = json.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(GroupMembership.self, from: data)
        }.sorted { $0.joinedAt < $1.joinedAt }
    }

    public func saveGroupMembership(_ m: GroupMembership) async {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(m) else { return }
        await engine.set(["membership": .string(String(decoding: data, as: UTF8.self))], record: StudyGroup.membershipId(m.groupId), kind: StudyGroup.membershipKind)
    }

    public func deleteGroupMembership(_ groupId: String) async { await engine.delete(StudyGroup.membershipId(groupId)) }
}

// MARK: Relay calls

/// A group's routes on the relay, as one member (device token for the vault, member token for the group).
public struct GroupClient: Sendable {
    public let relay: RelayClient
    public let groupId: String
    public let memberToken: String

    public init(relay: RelayClient, groupId: String, memberToken: String) {
        self.relay = relay; self.groupId = groupId; self.memberToken = memberToken
    }

    public struct Created: Codable, Sendable { public var groupId: String; public var memberId: String; public var memberToken: String; public var epoch: Int }
    public struct Joined: Codable, Sendable { public var memberId: String; public var memberToken: String; public var epoch: Int }
    public struct Info: Codable, Sendable, Equatable {
        public struct Member: Codable, Sendable, Equatable { public var memberId: String; public var memberKey: String; public var creator: Bool; public var joinedAt: Double }
        public struct InviteInfo: Codable, Sendable, Equatable { public var id: String; public var by: String; public var uses: Int; public var maxUses: Int; public var expiresAt: Double }
        public var groupId: String
        public var epoch: Int
        public var rotate: Bool
        public var members: [Member]
        public var invites: [InviteInfo]
    }
    public struct NewInvite: Codable, Sendable { public var id: String; public var secret: String; public var expiresAt: Double }
    public struct Entry: Codable, Sendable, Equatable, Identifiable {
        public var id: String
        public var cursor: Int
        public var kind: String
        public var member: String
        public var epoch: Int
        public var body: String
        public var challenge: String?
        public var about: String?
        public var createdAt: Double
    }
    public struct Waiting: Codable, Sendable, Equatable { public var challenge: String; public var submitted: Int }
    public struct Page: Codable, Sendable { public var entries: [Entry]; public var waiting: [Waiting]; public var more: Bool }
    public struct Box: Codable, Sendable { public var epoch: Int; public var box: String }

    private var path: String { relay.vaultPath("groups/\(groupId)") }
    private var headers: [String: String] { ["x-trove-member": memberToken, "Content-Type": "application/json"] }

    private func send(_ method: String, _ suffix: String = "", _ body: [String: Any]? = nil, expect: Set<Int> = [200]) async throws -> Data {
        let data = try body.map { try JSONSerialization.data(withJSONObject: $0) }
        return try await relay.raw(method, path + suffix, body: data, headers: headers, expect: expect)
    }

    public static func create(_ relay: RelayClient, memberKey: String) async throws -> Created {
        let data = try JSONSerialization.data(withJSONObject: ["memberKey": memberKey])
        let out = try await relay.raw("POST", relay.vaultPath("groups"), body: data, headers: ["Content-Type": "application/json"], expect: [201])
        return try JSONDecoder().decode(Created.self, from: out)
    }

    public static func join(_ relay: RelayClient, groupId: String, invite: String, memberKey: String) async throws -> Joined {
        let data = try JSONSerialization.data(withJSONObject: ["invite": invite, "memberKey": memberKey])
        let out = try await relay.raw("POST", relay.vaultPath("groups/\(groupId)/members"), body: data, headers: ["Content-Type": "application/json"], expect: [201])
        return try JSONDecoder().decode(Joined.self, from: out)
    }

    public func info() async throws -> Info { try JSONDecoder().decode(Info.self, from: try await send("GET")) }
    public func deleteGroup() async throws { _ = try await send("DELETE", expect: [204]) }
    public func invite(maxUses: Int = 20) async throws -> NewInvite {
        try JSONDecoder().decode(NewInvite.self, from: try await send("POST", "/invites", ["maxUses": maxUses], expect: [201]))
    }
    public func revokeInvite(_ id: String) async throws { _ = try await send("DELETE", "/invites/\(id)", expect: [204]) }
    /// Leave (my own id) or remove someone (creator).
    public func remove(member: String) async throws { _ = try await send("DELETE", "/members/\(member)", expect: [204]) }
    public func boxes() async throws -> [Box] {
        struct R: Codable { var boxes: [Box] }
        return try JSONDecoder().decode(R.self, from: try await send("GET", "/keys")).boxes
    }
    public func rotate(epoch: Int, boxes: [(memberId: String, box: String)]) async throws {
        _ = try await send("POST", "/keys", ["epoch": epoch, "boxes": boxes.map { ["memberId": $0.memberId, "box": $0.box] }])
    }
    @discardableResult
    public func post(kind: String, epoch: Int, body: Data, challenge: String? = nil, about: String? = nil) async throws -> Int {
        var b: [String: Any] = ["kind": kind, "epoch": epoch, "body": body.base64URL]
        if let challenge { b["challenge"] = challenge }
        if let about { b["about"] = about }
        struct R: Codable { var id: String; var cursor: Int }
        return try JSONDecoder().decode(R.self, from: try await send("POST", "/entries", b, expect: [201])).cursor
    }
    public func entries(after cursor: Int = 0) async throws -> Page {
        try JSONDecoder().decode(Page.self, from: try await send("GET", "/entries?after=\(cursor)"))
    }
    public func deleteEntry(_ id: String) async throws { _ = try await send("DELETE", "/entries/\(id)", expect: [204]) }

    /// The group's socket while its screen is open (live mode, "3 have submitted").
    public var liveURL: URL? {
        guard var c = URLComponents(url: relay.baseURL, resolvingAgainstBaseURL: false) else { return nil }
        c.scheme = c.scheme == "http" ? "ws" : "wss"
        c.path = path + "/live"
        c.queryItems = [URLQueryItem(name: "token", value: relay.token), URLQueryItem(name: "member", value: memberToken)]
        return c.url
    }
}
