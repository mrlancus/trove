import SwiftUI
import TroveCore

/// While a group challenge is being done: how far through, and handing it in (in practice and on Learn).
struct HandInBanner: View {
    let develop: DevelopModel
    @State private var groups = GroupsModel.shared

    var body: some View {
        if let run = develop.challengeRun {
            HStack(spacing: Theme.Space.m) {
                Image(systemName: "person.3.fill").foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(run.challenge.title).font(.callout.weight(.semibold)).lineLimit(1)
                    Text("\(run.answers.count) of \(run.challenge.questions.count) done · friends see it after they hand in")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Button { Task { await groups.submit() } } label: { BusyLabel("Hand in", busy: groups.working) }
                    .buttonStyle(.borderedProminent).controlSize(.small).disabled(groups.working)
            }
            .padding(Theme.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.accent.opacity(0.08), in: .rect(cornerRadius: Theme.Radius.medium))
        }
    }
}
