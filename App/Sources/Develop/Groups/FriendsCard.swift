import SwiftUI
import TroveCore

/// Learn → Study with friends: your groups, what's new in each, and starting or joining one. Friends only: a
/// group is joined through an invite link a member sends (study-with-friends prompt §2).
struct FriendsCard: View {
    @State private var groups = GroupsModel.shared
    @State private var making = false
    @State private var joining = false
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(alignment: .firstTextBaseline) {
                Text("Study with friends").font(.headline)
                Spacer()
                Menu {
                    Button("Start a group…", systemImage: "person.3") { making = true }
                    Button("Join with a link…", systemImage: "link") { joining = true }
                } label: { Label("New", systemImage: "plus") } primaryAction: { making = true }
                .menuStyle(.button).buttonStyle(.bordered).controlSize(.small).fixedSize()
            }
            if groups.memberships.isEmpty {
                FriendsEmpty(make: { making = true }, join: { joining = true })
            }
            ForEach(groups.memberships) { m in
                NavigationLink { GroupScreen(groupId: m.groupId) } label: { GroupRow(membership: m, state: groups.states[m.groupId]) }
                    .buttonStyle(.plain)
            }
            if let message = groups.message {
                Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Theme.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(cornerRadius: Theme.Radius.large)
        .task { await groups.start(model) }
        .sheet(isPresented: $making) { NewGroupSheet() }
        .sheet(isPresented: $joining) { JoinGroupSheet(link: "") }
    }
}

private struct FriendsEmpty: View {
    let make: () -> Void
    let join: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text("Challenge friends to the same questions or a whole mock, then compare answers once you've all handed in. Only people you send a link to can join.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Theme.Space.s) {
                Button("Start a group", action: make).buttonStyle(.borderedProminent)
                Button("Join with a link", action: join).buttonStyle(.bordered)
            }
            .controlSize(.small)
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.accent.opacity(0.08), in: .rect(cornerRadius: Theme.Radius.medium))
    }
}

private struct GroupRow: View {
    let membership: GroupMembership
    let state: GroupState?

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            Image(systemName: "person.3.fill").foregroundStyle(Theme.accent).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.body.weight(.medium)).foregroundStyle(.primary).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if open > 0 {
                Text("\(open) to do").font(.caption.weight(.semibold)).padding(.horizontal, Theme.Space.s).padding(.vertical, Theme.Space.xs)
                    .background(Theme.accent.opacity(0.15), in: Capsule()).foregroundStyle(Theme.accent)
            }
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.vertical, Theme.Space.xs)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }

    private var name: String {
        let n = state?.name ?? membership.name
        return n.isEmpty ? "Study group" : n
    }

    /// Challenges I haven't handed in yet.
    private var open: Int { state.map { s in s.challenges.filter { !s.submitted($0.id) }.count } ?? 0 }

    private var subtitle: String {
        guard let s = state else { return "Couldn't reach the group just now" }
        let people = "\(s.members.count) \(s.members.count == 1 ? "person" : "people")"
        return s.challenges.isEmpty ? "\(people) · no challenges yet" : "\(people) · \(s.challenges.count) challenge\(s.challenges.count == 1 ? "" : "s")"
    }
}

/// Name the group and yourself; nothing else is asked.
struct NewGroupSheet: View {
    @State private var groups = GroupsModel.shared
    @State private var name = ""
    @State private var myName = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Group name, e.g. Physics crew", text: $name)
                    TextField("Your name in this group", text: $myName)
                } footer: {
                    Text("Only the people you send an invite link to can join. They see your name, your answers and your marks; the relay sees none of it.")
                }
                if let message = groups.message { Section { Text(message).foregroundStyle(.secondary) } }
            }
            .navigationTitle("Start a group")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button { Task { if await groups.create(name: clean(name), myName: clean(myName)) != nil { dismiss() } } } label: {
                        BusyLabel("Start", busy: groups.working)
                    }
                    .disabled(clean(name).isEmpty || clean(myName).isEmpty || groups.working)
                }
            }
            .onAppear { if myName.isEmpty { myName = groups.defaultName } }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 260)
        #endif
    }

    private func clean(_ s: String) -> String { String(s.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60)) }
}

/// Join from a friend's link (pasted, or opened as `trove://join#…`).
struct JoinGroupSheet: View {
    @State private var groups = GroupsModel.shared
    @State var link: String
    @State private var myName = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Invite link", text: $link, axis: .vertical).lineLimit(1...3)
                        #if os(iOS)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        #endif
                    TextField("Your name in this group", text: $myName)
                } footer: {
                    Text(valid ? "Joining shares your name, and later your answers and marks, with this group only." : "Paste the link your friend sent you.")
                }
                if let message = groups.message { Section { Text(message).foregroundStyle(.secondary) } }
            }
            .navigationTitle("Join a group")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button { Task { if await groups.join(link: link, myName: name) { dismiss() } } } label: { BusyLabel("Join", busy: groups.working) }
                        .disabled(!valid || name.isEmpty || groups.working)
                }
            }
            .onAppear { if myName.isEmpty { myName = groups.defaultName } }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 260)
        #endif
    }

    private var valid: Bool { StudyGroup.Invite(link: link) != nil }
    private var name: String { String(myName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60)) }
}
