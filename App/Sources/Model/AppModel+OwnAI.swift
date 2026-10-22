import Foundation
import TroveCore

/// Your own AI (Settings → AI): a provider and API key you add once, used straight from this device
/// for Ask, note and page actions, and reading handwriting. Fast (the default), Smarter and Best
/// are the models you chose, always at medium effort.
extension AppModel {
    /// The client for your AI, when it's set up.
    var ownAI: AIClient? { aiSettings.isReady ? AIClient(settings: aiSettings) : nil }

    /// Picks up settings changed here or on another device.
    func loadAISettings() async {
        guard let library else { return }
        let s = await library.aiSettings()
        guard s != aiSettings || !aiSettingsLoaded else { return }
        aiSettingsLoaded = true
        aiSettings = s
        await enrichment?.setOwnAI(ownAI)
    }

    /// Saves them for every device and starts reading handwriting if that's on.
    func saveAISettings(_ s: AISettings) async {
        guard let library else { return }
        aiSettings = s
        await library.setAISettings(s)
        await enrichment?.setOwnAI(ownAI)
        Task {
            await syncNow()
            await enrichSoon()
        }
    }

    /// A note action with your AI (nil when it isn't set up; a toast when it fails).
    func runOwnNoteAI(_ action: NoteAI.Action, text: String, language: String) async -> NoteAI.Result? {
        guard let ai = ownAI else { return nil }
        let instruction = action == .flashcards
            ? "Make 3 to 15 study flashcards from the text in <content>: a short question on the front, a short answer on the back. Put a one-line description of the set in text."
            : action.instruction(language: language) + " Work on the text in <content>; put the result in text."
        do {
            let out = try await ai.action(instruction, text: text)
            return NoteAI.Result(text: out.text, cards: out.cards, place: "cloud", model: out.model)
        } catch {
            toast = "Your AI didn't answer: \(error.localizedDescription)"
            return nil
        }
    }

    /// Ask AI on a lasso selection with your AI: it gets the picture, so it reads the handwriting itself.
    func runOwnInkAI(_ action: InkAIAction, image: Data) async -> NoteAI.Result? {
        guard let ai = ownAI else { return nil }
        do {
            let out = try await ai.action(action.imageInstruction, image: image)
            return NoteAI.Result(text: out.text, cards: out.cards, place: "cloud", model: out.model)
        } catch {
            toast = "Your AI didn't answer: \(error.localizedDescription)"
            return nil
        }
    }
}

extension InkAIAction {
    /// The task for a model that sees the picture of the selection.
    var imageInstruction: String {
        switch self {
        case .summarise: "The image is part of a page from the user's notes. Summarise it in a few short sentences or bullet points, in text."
        case .explain: "The image is part of a page from the user's notes. Explain it simply, as a good tutor would, in text (Markdown)."
        case .solve: "Solve the maths in the image. Show the working step by step in Markdown in text, with maths in LaTeX between $ signs, and say clearly if a written step looks wrong."
        case .flashcards: "Make 3 to 15 study flashcards from the page in the image: a short question on the front, a short answer on the back. Put a one-line description of the set in text."
        }
    }
}
