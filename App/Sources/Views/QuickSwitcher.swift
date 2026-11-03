import SwiftUI
import TroveCore

/// Open Quickly (⌘O, MASTER_PLAN O1): type a few letters of any title; ⏎ opens the best match,
/// ⇧⏎ makes a new note with what you typed when nothing fits.
struct QuickSwitcher: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @FocusState private var focused: Bool

    var matches: [Item] { FuzzyMatch.rank(query, model.items, limit: 30) { $0.displayTitle } }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Open quickly…", text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .padding(14)
                .focused($focused)
                .onSubmit { open(matches.first) }
            Divider()
            List(matches) { item in
                Button { open(item) } label: {
                    HStack {
                        Image(systemName: ItemStyle.symbol(for: item)).foregroundStyle(.secondary).frame(width: 20)
                        Text(item.displayTitle).lineLimit(1)
                        Spacer()
                        Text(item.createdAt, style: .date).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
            if !query.isEmpty {
                Button("New note “\(query)”") { Task { await model.openWikilink(query); dismiss() } }
                    .keyboardShortcut(.return, modifiers: .shift)
                    .padding(10)
            }
        }
        .frame(minWidth: 480, minHeight: 360)
        .onAppear { focused = true }
    }

    private func open(_ item: Item?) {
        guard let item else { return }
        model.selectedItemID = item.id
        dismiss()
    }
}
