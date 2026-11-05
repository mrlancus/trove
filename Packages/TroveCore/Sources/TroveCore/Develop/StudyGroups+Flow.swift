import Foundation
import Crypto

/// What a group looks like to me, read from its entries: names, challenges, who has submitted, and (after I've
/// submitted to a challenge) everyone's answers and marks.
public struct GroupState: Sendable, Equatable {
    public var groupId: String
    public var name: String
    public var epoch: Int
    public var rotate: Bool
    public var me: String
    public var creator: String?
    public var members: [String]
    /// Names members gave themselves in this group.
    public var names: [String: String]
    public var challenges: [StudyGroup.Challenge]
    public var starts: [String: Date]
    /// Submissions I can see, by challenge then member (mine always; others' after I've submitted).
    public var submissions: [String: [String: StudyGroup.Submission]]
    /// Peer marks I can see, by challenge.
    public var marks: [String: [(by: String, mark: StudyGroup.Mark)]]
    /// How many have submitted to challenges I haven't.
    public var waiting: [String: Int]
    public var cursor: Int
    /// My own entries, by challenge and kind, so I can delete what I shared.
    public var mine: [GroupClient.Entry]

    public static func == (a: GroupState, b: GroupState) -> Bool {
        a.groupId == b.groupId && a.cursor == b.cursor && a.epoch == b.epoch && a.members == b.members && a.waiting == b.waiting && a.rotate == b.rotate
    }

    public func name(of member: String) -> String { names[member] ?? (member == me ? "You" : "A friend") }
    public func submitted(_ challenge: String) -> Bool { submissions[challenge]?[me] != nil }
    public func results(_ c: StudyGroup.Challenge) -> [StudyGroup.Question: [StudyGroup.Result]]? {
        StudyGroup.results(for: c, submissions: submissions[c.id] ?? [:], marks: marks[c.id] ?? [], me: me)
    }
}

/// The steps of study with friends, each one call: the apps only show them.
public enum GroupFlow {
    public enum Failure: LocalizedError, Equatable {
        case badLink, noKey(Int)
        public var errorDescription: String? {
            switch self {
            case .badLink: "That isn't a Trove invite link. Ask your friend to send it again."
            case .noKey: "This group's key changed and yours hasn't arrived yet. Try again in a moment."
            }
        }
    }

    /// Makes a group on my relay, names it and me, and keeps the membership in my vault.
    public static func create(name: String, myName: String, relay: RelayClient, library: Library, now: Date = Date()) async throws -> GroupMembership {
        let pair = Curve25519.KeyAgreement.PrivateKey()
        let made = try await GroupClient.create(relay, memberKey: pair.publicKey.rawRepresentation.base64URL)
        let key = StudyGroup.newGroupKey()
        let m = GroupMembership(relay: relay.baseURL, groupId: made.groupId, memberId: made.memberId, memberToken: made.memberToken,
                                memberPrivate: pair.rawRepresentation.base64URL, keys: ["1": key.withUnsafeBytes { Data($0) }.base64URL],
                                name: name, myName: myName, creator: true, joinedAt: now)
        await library.saveGroupMembership(m)
        let client = GroupClient(relay: relay, groupId: m.groupId, memberToken: m.memberToken)
        try await client.post(kind: "about", epoch: 1, body: StudyGroup.seal(StudyGroup.About(name: name), groupKey: key))
        try await client.post(kind: "profile", epoch: 1, body: StudyGroup.seal(StudyGroup.Profile(name: myName), groupKey: key))
        return m
    }

    /// An invite link for a friend (7 days, up to `maxUses` people).
    public static func invite(_ m: GroupMembership, relay: RelayClient, maxUses: Int = 20) async throws -> StudyGroup.Invite {
        let made = try await client(m, relay).invite(maxUses: maxUses)
        guard let key = m.keys[String(m.epoch)].flatMap(Data.init(base64URL:)) else { throw Failure.noKey(m.epoch) }
        return StudyGroup.Invite(relay: m.relay, groupId: m.groupId, secret: made.secret, key: key, epoch: m.epoch)
    }

    /// Joins from an invite link with my vault's device on that relay.
    public static func join(_ invite: StudyGroup.Invite, myName: String, relay: RelayClient, library: Library, now: Date = Date()) async throws -> GroupMembership {
        let pair = Curve25519.KeyAgreement.PrivateKey()
        let joined = try await GroupClient.join(relay, groupId: invite.groupId, invite: invite.secret, memberKey: pair.publicKey.rawRepresentation.base64URL)
        var m = GroupMembership(relay: invite.relay, groupId: invite.groupId, memberId: joined.memberId, memberToken: joined.memberToken,
                                memberPrivate: pair.rawRepresentation.base64URL, keys: [String(invite.epoch): invite.key.base64URL],
                                name: "", myName: myName, creator: false, joinedAt: now)
        await library.saveGroupMembership(m)
        let key = SymmetricKey(data: invite.key)
        try await client(m, relay).post(kind: "profile", epoch: invite.epoch, body: StudyGroup.seal(StudyGroup.Profile(name: myName), groupKey: key))
        if let state = try? await read(m, relay: relay, library: library), !state.name.isEmpty {
            m.name = state.name
            await library.saveGroupMembership(m)
        }
        return m
    }

    public static func client(_ m: GroupMembership, _ relay: RelayClient) -> GroupClient {
        GroupClient(relay: relay, groupId: m.groupId, memberToken: m.memberToken)
    }

    /// Posts any payload under the newest key.
    @discardableResult
    public static func post<T: Encodable>(_ payload: T, kind: String, challenge: String? = nil, about: String? = nil, in m: GroupMembership, relay: RelayClient) async throws -> Int {
        guard let key = m.key(m.epoch) else { throw Failure.noKey(m.epoch) }
        return try await client(m, relay).post(kind: kind, epoch: m.epoch, body: StudyGroup.seal(payload, groupKey: key), challenge: challenge, about: about)
    }

    public static func challenge(_ c: StudyGroup.Challenge, in m: GroupMembership, relay: RelayClient) async throws {
        try await post(c, kind: "challenge", challenge: c.id, in: m, relay: relay)
    }

    public static func start(_ c: StudyGroup.Challenge, at: Date, in m: GroupMembership, relay: RelayClient) async throws {
        try await post(StudyGroup.Start(challenge: c.id, at: at), kind: "start", challenge: c.id, in: m, relay: relay)
    }

    public static func submit(_ s: StudyGroup.Submission, in m: GroupMembership, relay: RelayClient) async throws {
        try await post(s, kind: "submission", challenge: s.challenge, in: m, relay: relay)
    }

    public static func mark(_ mark: StudyGroup.Mark, in m: GroupMembership, relay: RelayClient) async throws {
        try await post(mark, kind: "mark", challenge: mark.challenge, about: mark.member, in: m, relay: relay)
    }

    /// Reads the whole group: picks up new keys sealed to me, and as creator makes a new key when someone left.
    public static func read(_ m0: GroupMembership, relay: RelayClient, library: Library) async throws -> GroupState {
        var m = m0
        let c = client(m, relay)
        var info = try await c.info()
        // New keys sealed to me.
        if info.epoch > m.epoch || m.key(info.epoch) == nil, let mine = m.privateKey {
            for box in try await c.boxes() where m.keys[String(box.epoch)] == nil {
                if let k = try? StudyGroup.unbox(box.box, with: mine) { m.keys[String(box.epoch)] = k.withUnsafeBytes { Data($0) }.base64URL }
            }
            await library.saveGroupMembership(m)
        }
        // Someone left or was removed: the creator seals a fresh key to everyone still here.
        if info.rotate, m.creator {
            let next = StudyGroup.newGroupKey()
            let boxes = try info.members.map { ($0.memberId, try StudyGroup.box(next, to: $0.memberKey)) }
            try await c.rotate(epoch: info.epoch + 1, boxes: boxes)
            m.keys[String(info.epoch + 1)] = next.withUnsafeBytes { Data($0) }.base64URL
            await library.saveGroupMembership(m)
            info = try await c.info()
        }
        var state = GroupState(groupId: m.groupId, name: m.name, epoch: info.epoch, rotate: info.rotate, me: m.memberId,
                               creator: info.members.first(where: \.creator)?.memberId, members: info.members.map(\.memberId),
                               names: [m.memberId: m.myName], challenges: [], starts: [:], submissions: [:], marks: [:],
                               waiting: [:], cursor: 0, mine: [])
        var after = 0
        while true {
            let page = try await c.entries(after: after)
            state.waiting = Dictionary(page.waiting.map { ($0.challenge, $0.submitted) }, uniquingKeysWith: max)
            for e in page.entries {
                after = max(after, e.cursor)
                if e.member == m.memberId { state.mine.append(e) }
                guard let key = m.key(e.epoch), let body = Data(base64URL: e.body) else { continue }
                switch e.kind {
                case "profile": if let p = try? StudyGroup.open(body, as: StudyGroup.Profile.self, groupKey: key) { state.names[e.member] = p.name }
                case "about": if let a = try? StudyGroup.open(body, as: StudyGroup.About.self, groupKey: key), e.member == state.creator { state.name = a.name }
                case "challenge":
                    if var ch = try? StudyGroup.open(body, as: StudyGroup.Challenge.self, groupKey: key) {
                        ch.id = e.challenge ?? ch.id
                        state.challenges.removeAll { $0.id == ch.id }
                        state.challenges.append(ch)
                    }
                case "start": if let s = try? StudyGroup.open(body, as: StudyGroup.Start.self, groupKey: key) { state.starts[s.challenge] = s.at }
                case "submission":
                    if let s = try? StudyGroup.open(body, as: StudyGroup.Submission.self, groupKey: key), s.challenge == e.challenge {
                        state.submissions[s.challenge, default: [:]][e.member] = s
                    }
                case "mark":
                    if let mk = try? StudyGroup.open(body, as: StudyGroup.Mark.self, groupKey: key), mk.challenge == e.challenge, mk.member == e.about {
                        state.marks[mk.challenge, default: []].append((e.member, mk))
                    }
                default: break // a kind from a newer app
                }
            }
            if !page.more { break }
        }
        state.cursor = after
        return state
    }

    /// Leave (anyone) or, for the creator, delete the group; either way it goes from my vault.
    public static func leave(_ m: GroupMembership, relay: RelayClient, library: Library) async throws {
        if m.creator { try await client(m, relay).deleteGroup() } else { try await client(m, relay).remove(member: m.memberId) }
        await library.deleteGroupMembership(m.groupId)
    }
}
