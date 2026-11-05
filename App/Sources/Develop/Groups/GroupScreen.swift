import SwiftUI
import TroveCore

/// One group: who's in it, what's shared with whom, invites, and its challenges. While it's open, the group's
/// socket refreshes it when a friend hands in or a live challenge starts (no push: PROTOCOL.md §4).
struct GroupScreen: View {
    let groupId: String
    @State private var groups = GroupsModel.shared
    @State private var newChallenge = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                if let m = membership {
                    GroupHeader(membership: m, state: state)
                    GroupChallenges(membership: m, state: state) { newChallenge = true }
                    GroupMembers(membership: m, state: state)
                    GroupInvites(membership: m)
                    GroupLeave(membership: m)
                } else {
                    EmptyState(symbol: "person.3", title: "Not in this group", message: "You left it, or it was deleted.")
                }
            }
            .padding(Theme.Space.xl)
            .frame(maxWidth: Theme.readingWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(title)
        .refreshable { await groups.refresh(groupId) }
        .task { await groups.refresh(groupId); groups.listen(groupId) }
        .onDisappear { groups.stopListening() }
        .sheet(isPresented: $newChallenge) {
            if let m = membership { NewChallengeSheet(membership: m) }
        }
    }

    private var membership: GroupMembership? { groups.memberships.first { $0.groupId == groupId } }
    private var state: GroupState? { groups.states[groupId] }
    private var title: String {
        let n = state?.name ?? membership?.name ?? ""
        return n.isEmpty ? "Study group" : n
    }
}

/// Says plainly what's shared with whom.
private struct GroupHeader: View {
    let membership: GroupMembership
    let state: GroupState?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Label("Friends only", systemImage: "lock.fill").font(.caption.weight(.semibold)).foregroundStyle(Theme.accent)
            Text("Everyone in this group sees your name, and your answers and marks once they've handed in too. The relay that passes them on sees none of it: it's encrypted with a key only the group has. Your own uploads are never shared.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if state?.rotate == true, !membership.creator {
                Text("Someone left; the group's key is being changed. New things show once the creator opens the group.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(Theme.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(cornerRadius: Theme.Radius.large)
    }
}

private struct GroupChallenges: View {
    let membership: GroupMembership
    let state: GroupState?
    let new: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(alignment: .firstTextBaseline) {
                Text("Challenges").font(.title3.weight(.semibold))
                Spacer()
                Button(action: new) { Label("New challenge", systemImage: "plus") }.buttonStyle(.borderedProminent).controlSize(.small)
            }
            if let state, !state.challenges.isEmpty {
                ForEach(state.challenges.reversed()) { c in
                    NavigationLink { ChallengeScreen(groupId: membership.groupId, challengeId: c.id) } label: { ChallengeRow(challenge: c, state: state) }
                        .buttonStyle(.plain)
                }
            } else {
                Text("Pick some questions or a whole paper from your courses; everyone does them, then you compare.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

private struct ChallengeRow: View {
    let challenge: StudyGroup.Challenge
    let state: GroupState

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            Image(systemName: challenge.mode == .live ? "timer" : "calendar").foregroundStyle(Theme.accent).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(challenge.title).font(.body.weight(.medium)).foregroundStyle(.primary).lineLimit(2)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(state.submitted(challenge.id) ? "Handed in" : "To do").font(.caption.weight(.semibold))
                .padding(.horizontal, Theme.Space.s).padding(.vertical, Theme.Space.xs)
                .background((state.submitted(challenge.id) ? Color.green : Theme.accent).opacity(0.15), in: Capsule())
                .foregroundStyle(state.submitted(challenge.id) ? Color.green : Theme.accent)
        }
        .padding(Theme.Space.m)
        .frame(minHeight: 44)
        .card(cornerRadius: Theme.Radius.medium)
    }

    private var detail: String {
        let n = "\(challenge.questions.count) question\(challenge.questions.count == 1 ? "" : "s")"
        let done = state.submitted(challenge.id) ? (state.submissions[challenge.id]?.count ?? 1) : (state.waiting[challenge.id] ?? 0)
        let handed = done > 0 ? " · \(done) handed in" : ""
        switch challenge.mode {
        case .live: return "\(n) · live, \(challenge.minutes ?? 30) min" + handed
        case .deadline: return "\(n)" + (challenge.deadline.map { " · by \($0.formatted(.dateTime.weekday().day().month()))" } ?? "") + handed
        }
    }
}

private struct GroupMembers: View {
    let membership: GroupMembership
    let state: GroupState?
    @State private var groups = GroupsModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text("People").font(.title3.weight(.semibold))
            ForEach(state?.members ?? [], id: \.self) { member in
                HStack {
                    Image(systemName: "person.crop.circle").foregroundStyle(.secondary)
                    Text(state?.name(of: member) ?? "").lineLimit(1)
                    if member == state?.creator { Text("started the group").font(.caption).foregroundStyle(.secondary) }
                    if member == membership.memberId { Text("you").font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    if membership.creator, member != membership.memberId {
                        Button("Remove", role: .destructive) { Task { await groups.remove(member, from: membership) } }
                            .buttonStyle(.borderless).font(.caption)
                    }
                }
                .frame(minHeight: 44)
            }
        }
    }
}

/// Make a link to send a friend; see and revoke open ones.
private struct GroupInvites: View {
    let membership: GroupMembership
    @State private var groups = GroupsModel.shared
    @State private var link: URL?
    @State private var open: [GroupClient.Info.InviteInfo] = []

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text("Invite a friend").font(.title3.weight(.semibold))
            Text("A link works for 7 days and up to 20 people. Send it only to people you know; anyone with it can join.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let link {
                HStack(spacing: Theme.Space.s) {
                    ShareLink(item: link, message: Text("Practise with me in Trove")) { Label("Send the link", systemImage: "square.and.arrow.up") }
                        .buttonStyle(.borderedProminent)
                    Button("Copy") { Pasteboard.copy(link.absoluteString) }.buttonStyle(.bordered)
                }
            } else {
                Button { Task { link = await groups.inviteLink(membership); await load() } } label: { BusyLabel("Make an invite link", busy: groups.working) }
                    .buttonStyle(.borderedProminent)
            }
            ForEach(open, id: \.id) { i in
                HStack {
                    Text("Link · \(i.uses) of \(i.maxUses) used · until \(Date(timeIntervalSince1970: i.expiresAt / 1000).formatted(.dateTime.day().month()))")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if membership.creator || i.by == membership.memberId {
                        Button("Revoke", role: .destructive) { Task { await groups.revokeInvite(i.id, in: membership); await load() } }
                            .buttonStyle(.borderless).font(.caption)
                    }
                }
                .frame(minHeight: 44)
            }
        }
        .task { await load() }
    }

    private func load() async { open = await groups.invites(membership) }
}

private struct GroupLeave: View {
    let membership: GroupMembership
    @State private var groups = GroupsModel.shared
    @State private var confirming = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Button(membership.creator ? "Delete this group" : "Leave this group", role: .destructive) { confirming = true }
            .buttonStyle(.bordered)
            .confirmationDialog(membership.creator ? "Delete the group and everything in it for everyone?" : "Leave the group? What you shared there is deleted.",
                                isPresented: $confirming, titleVisibility: .visible) {
                Button(membership.creator ? "Delete" : "Leave", role: .destructive) { Task { await groups.leave(membership); dismiss() } }
            }
    }
}
