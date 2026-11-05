import SwiftUI
import TroveCore

/// The command palette (⌘K, MASTER_PLAN O2): every main action by typing a few letters.
struct CommandPalette: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @FocusState private var focused: Bool

    struct Command: Identifiable {
        var id: String { title }
        var title: String
        var symbol: String
        var run: @MainActor (AppModel) -> Void
    }

    static let commands: [Command] = [
        Command(title: "New note", symbol: "square.and.pencil") { m in Task { await m.newNote() } },
        Command(title: "New sketch", symbol: "scribble.variable") { m in Task { await m.newSketch() } },
        Command(title: "Today's note", symbol: "calendar") { m in Task { await m.openToday() } },
        Command(title: "Capture…", symbol: "plus.circle") { m in m.showCapture = true },
        Command(title: "Open quickly…", symbol: "magnifyingglass") { m in m.showSwitcher = true },
        Command(title: "Study flashcards", symbol: "rectangle.on.rectangle.angled") { m in m.studyDeck = nil; m.showStudy = true },
        Command(title: "Recently deleted", symbol: "trash") { m in m.showTrash = true },
        Command(title: "New monthly planner", symbol: "calendar.day.timeline.left") { m in Task { await m.newPlanner(.monthly) } },
        Command(title: "New weekly planner", symbol: "calendar.day.timeline.left") { m in Task { await m.newPlanner(.weekly) } },
        Command(title: "New daily planner", symbol: "calendar.day.timeline.left") { m in Task { await m.newPlanner(.daily) } },
        Command(title: "Sync now", symbol: "arrow.triangle.2.circlepath") { m in Task { await m.syncNow() } },
        Command(title: "Make this week's digest", symbol: "calendar.badge.clock") { m in Task { await m.makeDigest() } },
        Command(title: "Show clipboard", symbol: "doc.on.clipboard") { m in m.selection = .clipboard },
    ] + (Features.graph ? [Command(title: "Show connections graph", symbol: "point.3.connected.trianglepath.dotted") { m in m.selection = .graph }] : [])

    var matches: [Command] { FuzzyMatch.rank(query, Self.commands, limit: 20) { $0.title } }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Type a command…", text: $query)
                .textFieldStyle(.plain).font(.title3).padding(14)
                .focused($focused)
                .onSubmit { run(matches.first) }
            Divider()
            List(matches) { c in
                Button { run(c) } label: { Label(c.title, systemImage: c.symbol) }.buttonStyle(.plain)
            }
            .listStyle(.plain)
        }
        .frame(minWidth: 420, minHeight: 340)
        .onAppear { focused = true }
    }

    private func run(_ c: Command?) {
        guard let c else { return }
        dismiss()
        // After the sheet goes, so a command that opens another sheet can.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            c.run(model)
        }
    }
}
