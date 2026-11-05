import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Crypto
import Testing
@testable import TroveCore

/// Study with friends (PROTOCOL.md §4 "Study groups", DEVELOP_PLAN Appendix F).
@Suite struct StudyGroupTests {
    @Test func entriesOpenOnlyWithTheGroupKey() throws {
        let key = StudyGroup.newGroupKey()
        let body = try StudyGroup.seal(StudyGroup.Profile(name: "Sam"), groupKey: key)
        #expect(body.prefix(4) == Data("TRV1".utf8))
        #expect(!String(decoding: body, as: UTF8.self).contains("Sam"))
        #expect(try StudyGroup.open(body, as: StudyGroup.Profile.self, groupKey: key).name == "Sam")
        #expect(throws: (any Error).self) { try StudyGroup.open(body, as: StudyGroup.Profile.self, groupKey: StudyGroup.newGroupKey()) }
    }

    @Test func newKeysAreSealedToEachMember() throws {
        let member = Curve25519.KeyAgreement.PrivateKey()
        let other = Curve25519.KeyAgreement.PrivateKey()
        let key = StudyGroup.newGroupKey()
        let box = try StudyGroup.box(key, to: member.publicKey.rawRepresentation.base64URL)
        let opened = try StudyGroup.unbox(box, with: member)
        #expect(opened.withUnsafeBytes { Data($0) } == key.withUnsafeBytes { Data($0) })
        #expect(throws: (any Error).self) { try StudyGroup.unbox(box, with: other) }
    }

    @Test func inviteLinksKeepTheKeyInTheFragment() throws {
        let key = Data((0..<32).map { UInt8($0) })
        let invite = StudyGroup.Invite(relay: URL(string: "https://relay.example")!, groupId: "grp_abcdefghijklmnop", secret: "inv_secret", key: key, epoch: 2)
        let link = invite.link
        #expect(link.absoluteString.hasPrefix("https://relay.example/join#g=grp_abcdefghijklmnop&i=inv_secret&k="))
        #expect(link.query == nil)
        // What reaches the server: everything before the fragment.
        #expect(!link.absoluteString.components(separatedBy: "#")[0].contains(key.base64URL))
        #expect(StudyGroup.Invite(link: link.absoluteString) == invite)
        // The relay's /join page hands the same fragment to the app with the relay's origin.
        let app = "trove://join#" + (link.fragment ?? "") + "&r=" + "https%3A%2F%2Frelay.example"
        #expect(StudyGroup.Invite(link: app) == invite)
        #expect(StudyGroup.Invite(link: "https://relay.example/join#g=x&i=y") == nil)
        #expect(StudyGroup.Invite(link: "https://relay.example/join#g=x&i=y&k=short&e=1") == nil)
        #expect(StudyGroup.Invite(link: "not a link") == nil)
    }

    @Test func resultsWaitForMyOwnSubmission() {
        let q1 = StudyGroup.Question(doc: "aqa-8463-1h-2025-06-qp", key: "1.1", marks: 2)
        let q2 = StudyGroup.Question(doc: "aqa-8463-1h-2025-06-qp", key: "1.4", marks: 2)
        let c = StudyGroup.Challenge(id: "c1", title: "Energy", questions: [q1, q2], mode: .deadline)
        let theirs = StudyGroup.Submission(challenge: "c1", answers: [
            .init(doc: q1.doc, key: "1.1", text: "replenished", marks: 2, of: 2, seconds: 50, hints: 0, marking: .self),
            .init(doc: q2.doc, key: "1.4", text: "tidal", marks: nil, of: 2, seconds: 80, hints: 1, marking: .none),
        ], submittedAt: Date())
        #expect(StudyGroup.results(for: c, submissions: ["them": theirs], marks: [], me: "me") == nil)
        let mine = StudyGroup.Submission(challenge: "c1", answers: [
            .init(doc: q1.doc, key: "1.1", text: "renewable", marks: 1, of: 2, seconds: 40, hints: 0, marking: .ai),
        ], submittedAt: Date())
        let peer = StudyGroup.Mark(challenge: "c1", member: "them", doc: q2.doc, key: "1.4", marks: 1, of: 2)
        let r = StudyGroup.results(for: c, submissions: ["them": theirs, "me": mine], marks: [("me", peer)], me: "me")!
        #expect(r[q1]?.map(\.member) == ["me", "them"])
        #expect(r[q1]?.first?.answer.marking == .ai)
        #expect(r[q2]?.map(\.member) == ["them"])
        #expect(r[q2]?.first?.peerMarks["me"]?.marks == 1)
        // Totals count only marked answers.
        #expect(StudyGroup.total(theirs) == (2, 2))
        #expect(StudyGroup.total(mine) == (1, 2))
    }

    @Test func peerMarksWeighLikeAIWithAScheme() {
        #expect(Marking(rawValue: "peer") == .peer)
        #expect(MasteryConstants().markingWeight[.peer] == 0.9)
    }

    /// Two vaults on a running relay (`TROVE_RELAY_URL`, as RelayIntegrationTests): make a group, invite, run a
    /// challenge, submit, mark in each of the three ways, see results only after submitting, remove a member, and
    /// check the relay holds only ciphertext.
    @Test func twoVaultsStudyTogether() async throws {
        guard let base = ProcessInfo.processInfo.environment["TROVE_RELAY_URL"].flatMap(URL.init(string:)) else { return }
        func vault(_ name: String) async throws -> (RelayClient, Library) {
            let keys = VaultKeys.generate()
            let r = try await RelayClient.createVault(baseURL: base, publicKey: keys.publicKeyBase64URL, deviceName: name, deviceKind: "ios")
            return (RelayClient(baseURL: base, vaultId: r.vaultId, token: r.deviceToken), Library(engine: SyncEngine(device: r.deviceId, keys: keys, transports: [])))
        }
        let (aliceRelay, aliceLib) = try await vault("Alice's iPad")
        let (benRelay, benLib) = try await vault("Ben's iPhone")
        let (caraRelay, caraLib) = try await vault("Cara's Mac")

        // Alice makes a group and an invite; Ben and Cara join from the link (the key comes in the fragment).
        var alice = try await GroupFlow.create(name: "Physics crew", myName: "Alice", relay: aliceRelay, library: aliceLib)
        #expect(await aliceLib.groupMemberships().map(\.groupId) == [alice.groupId])
        let invite = try await GroupFlow.invite(alice, relay: aliceRelay)
        let parsed = try #require(StudyGroup.Invite(link: invite.link.absoluteString))
        let ben = try await GroupFlow.join(parsed, myName: "Ben", relay: benRelay, library: benLib)
        let cara = try await GroupFlow.join(parsed, myName: "Cara", relay: caraRelay, library: caraLib)
        #expect(ben.name == "Physics crew")

        // A challenge of catalogue questions only (doc ids and keys).
        let q1 = StudyGroup.Question(doc: "aqa-8463-1h-2025-06-qp", key: "1.1", marks: 2)
        let q2 = StudyGroup.Question(doc: "aqa-8463-1h-2025-06-qp", key: "1.4", marks: 2)
        let challenge = StudyGroup.Challenge(title: "Energy resources", questions: [q1, q2], mode: .deadline, deadline: Date().addingTimeInterval(86_400))
        try await GroupFlow.challenge(challenge, in: alice, relay: aliceRelay)

        // Alice submits (self-marked and AI-marked answers). Ben sees the challenge and that one has submitted, nothing else.
        try await GroupFlow.submit(.init(challenge: challenge.id, answers: [
            .init(doc: q1.doc, key: "1.1", text: "It can be replenished", marks: 2, of: 2, seconds: 45, hints: 0, marking: .self),
            .init(doc: q2.doc, key: "1.4", text: "Tidal is more reliable", marks: 1, of: 2, seconds: 90, hints: 1, marking: .ai),
        ], submittedAt: Date()), in: alice, relay: aliceRelay)
        var seenByBen = try await GroupFlow.read(ben, relay: benRelay, library: benLib)
        #expect(seenByBen.challenges.map(\.title) == ["Energy resources"])
        #expect(seenByBen.waiting[challenge.id] == 1)
        #expect(seenByBen.results(seenByBen.challenges[0]) == nil)
        #expect(seenByBen.submissions[challenge.id]?[alice.memberId] == nil)
        #expect(seenByBen.name(of: alice.memberId) == "Alice")

        // Ben submits an unmarked answer; now he sees Alice's, and Alice peer-marks his.
        try await GroupFlow.submit(.init(challenge: challenge.id, answers: [
            .init(doc: q1.doc, key: "1.1", text: "It won't run out", marks: nil, of: 2, seconds: 30, hints: 0, marking: .none),
        ], submittedAt: Date()), in: ben, relay: benRelay)
        seenByBen = try await GroupFlow.read(ben, relay: benRelay, library: benLib)
        let results = try #require(seenByBen.results(seenByBen.challenges[0]))
        #expect(results[q1]?.map { seenByBen.name(of: $0.member) }.sorted() == ["Alice", "Ben"])
        #expect(results[q2]?.first?.answer.marking == .ai)
        try await GroupFlow.mark(.init(challenge: challenge.id, member: ben.memberId, doc: q1.doc, key: "1.1", marks: 1, of: 2, note: "needs 'replenished'"),
                                 in: alice, relay: aliceRelay)
        seenByBen = try await GroupFlow.read(ben, relay: benRelay, library: benLib)
        #expect(seenByBen.results(seenByBen.challenges[0])?[q1]?.first(where: { $0.member == ben.memberId })?.peerMarks[alice.memberId]?.marks == 1)
        // Cara hasn't submitted: no answers, no marks.
        let seenByCara = try await GroupFlow.read(cara, relay: caraRelay, library: caraLib)
        #expect(seenByCara.waiting[challenge.id] == 2)
        #expect(seenByCara.marks.isEmpty && (seenByCara.submissions[challenge.id] ?? [:]).isEmpty)

        // The relay holds only ciphertext: every body is TRV1 and no name, answer or title appears anywhere it serves.
        let page = try await GroupFlow.client(ben, benRelay).entries()
        let served = String(decoding: try JSONEncoder().encode(page.entries), as: UTF8.self)
            + String(decoding: try JSONEncoder().encode(try await GroupFlow.client(ben, benRelay).info()), as: UTF8.self)
        for plain in ["Alice", "Ben", "Physics crew", "Energy resources", "replenished", "won't run out", q1.doc] { #expect(!served.contains(plain), "the relay serves \(plain)") }
        for e in page.entries { #expect(Data(base64URL: e.body)?.prefix(4) == Data("TRV1".utf8)) }

        // Alice removes Cara: Cara is out, the key moves on, and Ben picks up the new key and still reads everything.
        try await GroupFlow.client(alice, aliceRelay).remove(member: cara.memberId)
        await #expect(throws: (any Error).self) { _ = try await GroupFlow.read(cara, relay: caraRelay, library: caraLib) }
        _ = try await GroupFlow.read(alice, relay: aliceRelay, library: aliceLib) // the creator rotates
        alice = try #require(await aliceLib.groupMemberships().first)
        #expect(alice.epoch == 2)
        try await GroupFlow.post(StudyGroup.Profile(name: "Alice R."), kind: "profile", in: alice, relay: aliceRelay)
        let after = try await GroupFlow.read(ben, relay: benRelay, library: benLib)
        #expect(after.epoch == 2 && !after.rotate)
        #expect(after.name(of: alice.memberId) == "Alice R.")
        #expect(after.members.count == 2)
        #expect(try await benLib.groupMemberships().first?.epoch == 2)
        // The old invite no longer works.
        await #expect(throws: (any Error).self) { _ = try await GroupFlow.join(parsed, myName: "Dan", relay: caraRelay, library: caraLib) }

        // Ben leaves; Alice deletes the group.
        try await GroupFlow.leave(ben, relay: benRelay, library: benLib)
        #expect(await benLib.groupMemberships().isEmpty)
        try await GroupFlow.leave(alice, relay: aliceRelay, library: aliceLib)
        await #expect(throws: (any Error).self) { _ = try await GroupFlow.client(alice, aliceRelay).info() }
    }
}
