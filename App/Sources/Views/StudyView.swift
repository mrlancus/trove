import SwiftUI
import TroveCore

/// Study mode (docs/MASTER_PLAN.md G8): flashcards come up when FSRS says you're about to forget
/// them. Front, tap (or Space) for the back, then Again / Hard / Good / Easy with what each gives.
struct StudyView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// Only this deck (a flashcards note); nil for everything due.
    var noteId: String?

    @State private var queue: [StudyCard] = []
    @State private var showingBack = false
    @State private var done = 0
    @State private var loaded = false

    var body: some View { perfBody.perfWorkflow("Study") }

    @ViewBuilder private var perfBody: some View {
        NavigationStack {
            VStack(spacing: 20) {
                if !loaded {
                    ProgressView()
                } else if let card = queue.first {
                    Text("\(queue.count) to go · \(done) done").font(.caption).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 16) {
                        Text(card.noteTitle).font(.caption).foregroundStyle(.secondary)
                        Text(card.front).font(.title3.weight(.semibold))
                        if showingBack {
                            Divider()
                            Text(card.back).font(.title3)
                        }
                    }
                    .frame(maxWidth: 560, alignment: .leading)
                    .padding(24)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 18))
                    .onTapGesture { showingBack = true }
                    if showingBack {
                        let preview = FSRS.preview(card.state, now: Date().timeIntervalSince1970 * 1000)
                        HStack(spacing: 10) {
                            ForEach(FSRS.Grade.allCases, id: \.self) { g in
                                Button { grade(card, g) } label: {
                                    VStack(spacing: 2) {
                                        Text(g.label).font(.callout.weight(.semibold))
                                        Text(preview[g] ?? "").font(.caption2).foregroundStyle(.secondary)
                                    }
                                    .frame(minWidth: 70)
                                }
                                .buttonStyle(.bordered)
                                .tint(g == .again ? .red : g == .good ? Brand.orange : .secondary)
                                .keyboardShortcut(KeyEquivalent(Character("\(g.rawValue)")), modifiers: [])
                            }
                        }
                    } else {
                        Button("Show answer") { showingBack = true }
                            .buttonStyle(.borderedProminent).tint(Brand.orange)
                            .keyboardShortcut(.space, modifiers: [])
                    }
                } else {
                    ContentUnavailableView(done > 0 ? "All done for now" : "Nothing to study",
                                           systemImage: done > 0 ? "checkmark.circle" : "rectangle.on.rectangle.angled",
                                           description: Text(done > 0 ? "You reviewed \(done) card\(done == 1 ? "" : "s"). The next ones come back when you're about to forget them."
                                                             : "Make flashcards from a note or a notebook (Ask AI → Make flashcards, or \"quiz me\" in a notebook)."))
                }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Study")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .task { await load() }
        }
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 460)
        #endif
    }

    private func load() async {
        guard let library = model.library else { return }
        queue = await library.studyQueue(from: noteId)
        loaded = true
    }

    private func grade(_ card: StudyCard, _ g: FSRS.Grade) {
        guard let library = model.library else { return }
        showingBack = false
        queue.removeFirst()
        done += 1
        Task {
            let next = await library.review(card, g)
            // Again: back in this session once its 10 minutes are up, at the end of the queue.
            if g == .again {
                var again = card
                again.state = next
                queue.append(again)
            }
        }
    }
}
