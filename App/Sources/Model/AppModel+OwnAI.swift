import Foundation
import TroveCore

/// Your own AI (Settings → AI): a provider and API key you add once, used straight from this device
/// for Ask, note and page actions, and reading handwriting. Fast (the default), Smarter and Best
/// are the models you chose, always at medium effort.
extension AppModel {
    /// The client for your AI, when it's set up. Every request it makes is logged (Activity, costs).
    var ownAI: AIClient? {
        guard aiSettings.isReady else { return nil }
        return AIClient(settings: aiSettings, meter: { [weak self] call in await self?.logAI(call) })
    }

    /// One request: shown at once, and saved for every device's totals.
    func logAI(_ call: AIUsage.Call) async {
        var call = call
        call.device = config?.deviceId ?? ""
        call.id = "live-\(UUID().uuidString)"
        aiCalls.insert(call, at: 0)
        await library?.recordAIUsage(call)
    }

    /// Totals for a period, from every device.
    func aiTotal(_ period: AIUsage.Period) -> AIUsage.Total {
        let start = period.start(sessionStart: aiSessionStart)
        if period == .session {
            let me = config?.deviceId ?? ""
            return AIUsage.Total(aiCalls.filter { $0.at >= start && $0.device == me })
        }
        return AIUsage.Total(aiCalls.lazy.filter { $0.at >= start })
    }

    /// What background reading has spent this month, and whether it may carry on.
    var backgroundAISpend: Double { AIUsage.Total(aiCalls.filter { $0.purpose.isBackground && $0.at >= AIUsage.Period.month.start(sessionStart: aiSessionStart) }).cost }

    /// Usage and chats from every device, when they changed.
    func loadAIRecords() async {
        guard let library else { return }
        let stamp = await library.stamp(of: ["aiUsage", "aiChat"])
        guard stamp != aiStamp else { return }
        aiStamp = stamp
        let since = min(AIUsage.Period.month.start(sessionStart: aiSessionStart), AIUsage.Period.week.start(sessionStart: aiSessionStart))
        aiCalls = await library.aiUsage(since: since)
        aiChats = await library.aiChats()
    }

    /// Picks up settings changed here or on another device.
    func loadAISettings() async {
        guard let library else { return }
        await loadAIRecords()
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
            let out = try await ai.action(instruction, text: text, about: action.rawValue)
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
            let out = try await ai.action(action.imageInstruction, image: image, about: "Selection: \(action.rawValue)")
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

// MARK: Ask

extension AppModel {
    /// Asks your AI in a chat (a new one when `chat` is nil), saving the turn. `progress` hears each
    /// step and the running cost.
    func askAI(_ question: String, in chat: AIChat?, tier: AISettings.Tier,
               progress: @escaping @MainActor @Sendable (AIClient.Progress) -> Void) async -> AIChat? {
        guard let library, let ai = ownAI else { return nil }
        var chat = chat ?? AIChat()
        let turn: AIChat.Turn
        do {
            let answer = try await ai.research(question, history: chat.turns, tools: AskTools(library: library), tier: tier,
                                               progress: { p in await progress(p) })
            let usage = answer.progress.usage
            turn = AIChat.Turn(question: question, answer: answer.text.isEmpty ? "No answer came back." : answer.text, sources: answer.sources,
                               steps: answer.progress.steps, model: answer.progress.model, tokens: usage.tokens,
                               cost: usage.unpriced == usage.calls && usage.calls > 0 ? nil : usage.cost)
        } catch {
            turn = AIChat.Turn(question: question, answer: "Your AI didn't answer: \(error.localizedDescription)", model: aiSettings.model(tier))
        }
        chat.turns.append(turn)
        await library.saveAIChat(chat)
        if let i = aiChats.firstIndex(where: { $0.id == chat.id }) { aiChats.remove(at: i) }
        aiChats.insert(chat, at: 0)
        return chat
    }

    func deleteAIChat(_ id: String) async {
        aiChats.removeAll { $0.id == id }
        await library?.deleteAIChat(id)
    }
}
