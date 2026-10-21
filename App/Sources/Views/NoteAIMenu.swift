import SwiftUI
import TroveCore

/// The "AI" menu on a note (ROADMAP §4 A2). Shown only when `model.noteAIAvailable`: Apple
/// Intelligence on this device (the iPad), or the relay's cloud AI when it's on.
struct NoteAIMenu: View {
    let item: Item
    @Binding var text: String
    @Environment(AppModel.self) private var model
    @State private var result: NoteAI.Result?
    @State private var action: NoteAI.Action = .shorter
    @State private var working = false
    @State private var askLanguage = false
    @State private var language = "French"

    var body: some View {
        Menu {
            ForEach(NoteAI.Action.allCases) { choice in
                Button {
                    if choice == .translate { askLanguage = true } else { run(choice) }
                } label: {
                    Label(choice.label, systemImage: choice.symbol)
                }
            }
        } label: {
            if working {
                ProgressView().controlSize(.small)
            } else {
                Label("AI", systemImage: "sparkles")
            }
        }
        .fixedSize()
        .disabled(working)
        .help("Rewrite, continue, translate or make flashcards")
        .alert("Translate into", isPresented: $askLanguage) {
            TextField("Language", text: $language)
            Button("Translate") { run(.translate) }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: showingResult) { resultSheet }
    }

    private var showingResult: Binding<Bool> {
        Binding(get: { result != nil }, set: { shown in if !shown { result = nil } })
    }

    private func run(_ choice: NoteAI.Action) {
        action = choice
        working = true
        let source = text
        let target = language
        Task {
            let out = await model.runNoteAI(choice, text: source, language: target)
            working = false
            guard let out else { return }
            if choice == .flashcards {
                await model.saveFlashcards(out, from: item)
            } else {
                result = out
            }
        }
    }

    @ViewBuilder private var resultSheet: some View {
        if let result {
            VStack(alignment: .leading, spacing: 14) {
                Text(action.label.replacingOccurrences(of: "…", with: "")).font(.headline)
                ScrollView {
                    MarkdownText(markdown: result.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Text(result.label).font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Discard", role: .cancel) { self.result = nil }
                    Spacer()
                    Button("Copy") { copy(result.text) }
                    if action != .keepWriting {
                        Button("Add below") { apply(text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n" + result.text) }
                        Button("Replace") { apply(result.text) }
                            .buttonStyle(.borderedProminent)
                    } else {
                        Button("Add to the note") { apply(text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n" + result.text) }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
            .padding(20)
            #if os(macOS)
            .frame(minWidth: 460, minHeight: 360)
            #endif
        }
    }

    private func apply(_ newText: String) {
        text = newText
        result = nil
        model.toast = "Done. History has the old version."
    }

    private func copy(_ value: String) {
        Pasteboard.copy(value)
        model.toast = "Copied"
    }
}
