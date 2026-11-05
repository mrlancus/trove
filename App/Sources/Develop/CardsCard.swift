import SwiftUI
import TroveCore

/// Learn → Cards (learn-pivot plan §4 B1): your flashcard decks with what's due, each studied as a block in the
/// existing StudyView; "Study everything due" is the same as ⌘K → Study flashcards.
struct CardsCard: View {
    @Environment(AppModel.self) private var model
    @State private var decks: [Deck] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !decks.isEmpty { list }
        }
        .task(id: model.dataVersion) {
            guard let library = model.library else { return }
            decks = Deck.summaries(await library.studyCards())
        }
    }

    private var list: some View {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Cards").font(.title3.weight(.semibold))
                    Spacer()
                    let due = decks.reduce(0) { $0 + $1.due }
                    if due > 0 {
                        Button("Study \(due) due") { open(nil) }.buttonStyle(.borderedProminent).controlSize(.small)
                    }
                }
                ForEach(decks.prefix(8)) { deck in DeckRow(deck: deck) { open(deck.noteId) } }
            }
            .padding(Theme.Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .card(cornerRadius: Theme.Radius.large)
    }

    private func open(_ noteId: String?) {
        model.studyDeck = noteId
        model.showStudy = true
    }
}

private struct DeckRow: View {
    let deck: Deck
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: Theme.Space.m) {
                Image(systemName: "rectangle.on.rectangle.angled").foregroundStyle(Theme.accent).frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(deck.title.isEmpty ? "Untitled deck" : deck.title).font(.body.weight(.medium)).foregroundStyle(.primary).lineLimit(1)
                    Text("\(deck.total) card\(deck.total == 1 ? "" : "s")" + (deck.new > 0 ? " · \(deck.new) new" : "")).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if deck.due > 0 {
                    Text("\(deck.due) due").font(.caption.weight(.semibold)).padding(.horizontal, Theme.Space.s).padding(.vertical, Theme.Space.xs)
                        .background(Theme.accent.opacity(0.15), in: Capsule()).foregroundStyle(Theme.accent)
                }
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
