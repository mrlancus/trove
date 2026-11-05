import Foundation
import Observation
import TroveCore

/// A challenge being done: the practice screen records each marked question here, then it's submitted.
struct ChallengeRun {
    var groupId: String
    var challenge: StudyGroup.Challenge
    var answers: [StudyGroup.Answer] = []
    var questionStarted = Date()

    /// Called by `DevelopModel.record` for every marked (or skipped) question while the run is on.
    mutating func add(_ p: Problem, score: Double?, marking: Marking, hints: Int, text: String?) {
        guard p.sourceKey.hasPrefix("cat:"), let q = challenge.questions.first(where: { "cat:\($0.doc)" == p.sourceKey && $0.key == p.key }) else { return }
        let of = q.marks ?? p.marks
        let how: StudyGroup.HowMarked = switch marking {
        case .selfMarked: .self
        case .aiScheme, .aiNoScheme: .ai
        case .peer: .peer
        case .none: .none
        }
        let marks = score.flatMap { s in of.map { (s * Double($0) * 2).rounded() / 2 } }
        answers.removeAll { $0.doc == q.doc && $0.key == q.key }
        answers.append(.init(doc: q.doc, key: q.key, text: text.map { String($0.prefix(4000)) }, marks: marks, of: of,
                             seconds: max(0, Int(Date().timeIntervalSince(questionStarted))), hints: hints, marking: how))
        questionStarted = Date()
    }
}

/// Study with friends (PROTOCOL.md §4 "Study groups", DEVELOP_PLAN Appendix F): the groups in my vault, what each
/// looks like now, and the steps, each a call into TroveCore's `GroupFlow`. Groups live on my vault's relay.
@MainActor @Observable
final class GroupsModel {
    static let shared = GroupsModel()

    @ObservationIgnored weak var app: AppModel?
    private(set) var memberships: [GroupMembership] = []
    private(set) var states: [String: GroupState] = [:]
    var message: String?
    var working = false
    @ObservationIgnored private var socket: URLSessionWebSocketTask?
    @ObservationIgnored private var socketGroup: String?

    var relay: RelayClient? { app?.vault.relayClient }
    var develop: DevelopModel { DevelopModel.shared }

    /// What I'm called in groups: the last name I used, else the device's owner's first name.
    var defaultName: String { memberships.last?.myName ?? "" }

    func start(_ app: AppModel) async {
        self.app = app
        await refresh()
    }

    /// Reads every group (one request each), on opening Learn: how friends find out without push.
    func refresh() async {
        guard let library = app?.library else { return }
        memberships = await library.groupMemberships()
        guard let relay else { return }
        for m in memberships where sameRelay(m, relay) {
            do { states[m.groupId] = try await GroupFlow.read(m, relay: relay, library: library) }
            catch { states[m.groupId] = nil }
        }
        memberships = await library.groupMemberships()
    }

    func refresh(_ groupId: String) async {
        guard let library = app?.library, let relay, let m = memberships.first(where: { $0.groupId == groupId }) else { return }
        if let s = try? await GroupFlow.read(m, relay: relay, library: library) { states[groupId] = s }
        memberships = await library.groupMemberships()
    }

    private func sameRelay(_ m: GroupMembership, _ relay: RelayClient) -> Bool {
        m.relay.host == relay.baseURL.host && m.relay.port == relay.baseURL.port
    }

    private func run(_ what: String, _ body: () async throws -> Void) async {
        working = true
        defer { working = false }
        do { try await body(); message = nil } catch {
            message = "\(what) didn't work: \(error.localizedDescription)"
        }
    }

    // MARK: Steps

    func create(name: String, myName: String) async -> GroupMembership? {
        guard let library = app?.library, let relay else { message = "Groups go through your relay: set it up in Settings → Sync."; return nil }
        var made: GroupMembership?
        await run("Making the group") { made = try await GroupFlow.create(name: name, myName: myName, relay: relay, library: library) }
        await refresh()
        return made
    }

    func inviteLink(_ m: GroupMembership) async -> URL? {
        guard let relay else { return nil }
        var link: URL?
        await run("Making an invite") { link = try await GroupFlow.invite(m, relay: relay).link }
        return link
    }

    func join(link: String, myName: String) async -> Bool {
        guard let library = app?.library, let relay else { message = "Joining needs your relay: set it up in Settings → Sync."; return false }
        guard let invite = StudyGroup.Invite(link: link) else { message = GroupFlow.Failure.badLink.localizedDescription; return false }
        guard invite.relay.host == relay.baseURL.host else {
            message = "This invite is for a group on another relay (\(invite.relay.host ?? "?")). Groups work between people on the same relay."
            return false
        }
        var ok = false
        await run("Joining") { _ = try await GroupFlow.join(invite, myName: myName, relay: relay, library: library); ok = true }
        await refresh()
        return ok
    }

    func newChallenge(_ m: GroupMembership, _ c: StudyGroup.Challenge) async {
        guard let relay else { return }
        await run("Sending the challenge") { try await GroupFlow.challenge(c, in: m, relay: relay) }
        await refresh(m.groupId)
    }

    /// Live mode: everyone with the group open starts together, 10 seconds from now.
    func startLive(_ m: GroupMembership, _ c: StudyGroup.Challenge) async {
        guard let relay else { return }
        await run("Starting") { try await GroupFlow.start(c, at: Date().addingTimeInterval(10), in: m, relay: relay) }
        await refresh(m.groupId)
    }

    /// The challenge's questions on this device (each device downloads the paper from the board itself).
    func problems(_ c: StudyGroup.Challenge) -> [Problem] {
        c.questions.compactMap { q in develop.problems.first { $0.sourceKey == "cat:\(q.doc)" && $0.key == q.key } }
    }

    /// Papers of the challenge that aren't on this device yet, by course (only courses I've added).
    func missingPapers(_ c: StudyGroup.Challenge) -> [(spec: Catalogue.Spec, docs: Set<String>)] {
        let have = Set(problems(c).map(\.sourceKey))
        var out: [String: (Catalogue.Spec, Set<String>)] = [:]
        for q in c.questions where !have.contains("cat:\(q.doc)") {
            guard let spec = develop.spec(ofDoc: q.doc) else { continue }
            out[spec.id, default: (spec, [])].1.insert(q.doc)
        }
        return out.values.map { (spec: $0.0, docs: $0.1) }
    }

    /// Courses of the challenge I haven't added (their catalogue spec ids), so its papers can't be fetched yet.
    func missingCourses(_ c: StudyGroup.Challenge) -> [String] {
        let have = Set(problems(c).map(\.sourceKey))
        let ids = c.questions.filter { !have.contains("cat:\($0.doc)") && develop.spec(ofDoc: $0.doc) == nil }.compactMap { q in
            develop.catalogue?.specs.first(where: { q.doc.hasPrefix($0.id + "-") })?.id
        }
        return Array(Set(ids)).sorted()
    }

    func download(_ c: StudyGroup.Challenge) {
        for (spec, docs) in missingPapers(c) { develop.download(spec, papers: docs) }
    }

    /// Starts the challenge in the practice screen; each marked question is kept for the submission.
    func begin(_ m: GroupMembership, _ c: StudyGroup.Challenge) {
        let ps = problems(c)
        guard !ps.isEmpty else { message = "Download the paper first."; return }
        develop.challengeRun = ChallengeRun(groupId: m.groupId, challenge: c)
        develop.session = DevelopModel.Session(problems: ps, seed: 1)
    }

    /// Sends what was done; unanswered questions go as unmarked.
    func submit() async {
        guard let relay, var run = develop.challengeRun, let m = memberships.first(where: { $0.groupId == run.groupId }) else { return }
        for q in run.challenge.questions where !run.answers.contains(where: { $0.doc == q.doc && $0.key == q.key }) {
            run.answers.append(.init(doc: q.doc, key: q.key, of: q.marks, seconds: 0, hints: 0, marking: .none))
        }
        let s = StudyGroup.Submission(challenge: run.challenge.id, answers: run.answers, submittedAt: Date())
        await self.run("Submitting") { try await GroupFlow.submit(s, in: m, relay: relay) }
        develop.challengeRun = nil
        develop.session = nil
        await refresh(m.groupId)
    }

    func mark(_ m: GroupMembership, _ mark: StudyGroup.Mark) async {
        guard let relay else { return }
        await run("Sending your marks") { try await GroupFlow.mark(mark, in: m, relay: relay) }
        await refresh(m.groupId)
    }

    /// A friend's marks for my answer count only when I accept them: a new attempt marked `peer`.
    func accept(_ mark: StudyGroup.Mark) async {
        guard let p = develop.problems.first(where: { $0.sourceKey == "cat:\(mark.doc)" && $0.key == mark.key }) else { return }
        await develop.record(p, score: mark.of > 0 ? min(1, mark.marks / Double(mark.of)) : 0, marking: .peer)
        message = "Added to your practice as marked by a friend."
    }

    func remove(_ member: String, from m: GroupMembership) async {
        guard let relay else { return }
        await run("Removing") { try await GroupFlow.client(m, relay).remove(member: member) }
        await refresh(m.groupId)
    }

    func revokeInvite(_ id: String, in m: GroupMembership) async {
        guard let relay else { return }
        await run("Revoking") { try await GroupFlow.client(m, relay).revokeInvite(id) }
    }

    func invites(_ m: GroupMembership) async -> [GroupClient.Info.InviteInfo] {
        guard let relay else { return [] }
        return (try? await GroupFlow.client(m, relay).info().invites) ?? []
    }

    /// Deletes one thing I shared (a submission, a mark, a challenge).
    func delete(_ entry: String, in m: GroupMembership) async {
        guard let relay else { return }
        await run("Deleting") { try await GroupFlow.client(m, relay).deleteEntry(entry) }
        await refresh(m.groupId)
    }

    func leave(_ m: GroupMembership) async {
        guard let library = app?.library, let relay else { return }
        await run(m.creator ? "Deleting the group" : "Leaving") { try await GroupFlow.leave(m, relay: relay, library: library) }
        states[m.groupId] = nil
        await refresh()
    }

    // MARK: The group's socket while its screen is open

    func listen(_ groupId: String) {
        guard socketGroup != groupId, let relay, let m = memberships.first(where: { $0.groupId == groupId }),
              let url = GroupFlow.client(m, relay).liveURL else { return }
        stopListening()
        let task = URLSession.shared.webSocketTask(with: url)
        socket = task
        socketGroup = groupId
        task.resume()
        receive(task, groupId)
    }

    func stopListening() {
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        socketGroup = nil
    }

    private func receive(_ task: URLSessionWebSocketTask, _ groupId: String) {
        task.receive { [weak self] result in
            guard case .success = result else { return }
            Task { @MainActor [weak self] in
                guard let self, self.socket === task else { return }
                await self.refresh(groupId)
                self.receive(task, groupId)
            }
        }
    }
}
