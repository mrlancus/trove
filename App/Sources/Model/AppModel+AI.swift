import Foundation
import TroveCore

/// AI on a note (ROADMAP §4 A2): Apple Intelligence where the device has it (the iPad), otherwise the
/// relay's cloud AI when it's on; hidden when neither is.
enum NoteAI {
    enum Action: String, CaseIterable, Identifiable {
        case keepWriting = "continue"
        case shorter, clearer, grammar, bullets, translate, flashcards

        var id: String { rawValue }

        var label: String {
            switch self {
            case .keepWriting: return "Continue writing"
            case .shorter: return "Make shorter"
            case .clearer: return "Make clearer"
            case .grammar: return "Fix spelling and grammar"
            case .bullets: return "Turn into bullet points"
            case .translate: return "Translate…"
            case .flashcards: return "Make flashcards"
            }
        }

        var symbol: String {
            switch self {
            case .keepWriting: return "text.append"
            case .shorter: return "arrow.down.right.and.arrow.up.left"
            case .clearer: return "text.magnifyingglass"
            case .grammar: return "textformat.abc.dottedunderline"
            case .bullets: return "list.bullet"
            case .translate: return "globe"
            case .flashcards: return "rectangle.on.rectangle.angled"
            }
        }

        /// The task given to the on-device model (the relay has its own, server/src/ai.ts).
        func instruction(language: String) -> String {
            switch self {
            case .keepWriting: return "Continue the note in the same voice and language. Write only the new text, a paragraph or two."
            case .shorter: return "Rewrite the note to be shorter, keeping its meaning, voice and language. Keep Markdown and [[links]]."
            case .clearer: return "Rewrite the note to be clearer, keeping its meaning, voice and language. Keep Markdown and [[links]]."
            case .grammar: return "Fix spelling, grammar and punctuation. Change nothing else. Keep Markdown and [[links]]."
            case .bullets: return "Turn the note into tidy Markdown bullet points, keeping every fact. Keep [[links]]."
            case .translate: return "Translate the note into " + (language.isEmpty ? "English" : language) + ". Keep Markdown and [[links]]."
            case .flashcards: return "Make study flashcards."
            }
        }
    }

    struct Result: Sendable {
        var text: String
        var cards: [(front: String, back: String)]
        /// "device" or "cloud", for the label.
        var place: String
        var model: String

        var label: String { place == "cloud" ? "Processed in the cloud" + (model.isEmpty ? "" : " by " + model) : "Made on this device with Apple Intelligence" }
    }
}

extension AppModel {
    /// Note AI shows when this device has Apple Intelligence or the relay says cloud AI is on.
    var noteAIAvailable: Bool { OnDeviceAI.isAvailable || cloudAIStatus?.enabled == true }

    func refreshAIStatus() async {
        guard let relay = vault.relayClient else { cloudAIStatus = nil; return }
        if let status = try? await relay.aiStatus() { cloudAIStatus = status }
    }

    /// Runs a note action: on this device first, then in the cloud when it's on. Nil (with a toast) on failure.
    func runNoteAI(_ action: NoteAI.Action, text: String, language: String = "") async -> NoteAI.Result? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { toast = "Write something first"; return nil }
        if OnDeviceAI.isAvailable {
            do {
                if action == .flashcards {
                    if let cards = try await OnDeviceAI.flashcards(from: text) {
                        return NoteAI.Result(text: "", cards: cards, place: "device", model: "")
                    }
                } else if let out = try await OnDeviceAI.rewrite(text, instruction: action.instruction(language: language)) {
                    return NoteAI.Result(text: out, cards: [], place: "device", model: "")
                }
            } catch {
                // The on-device model declined or failed: try the cloud below if it's on.
            }
        }
        guard cloudAIStatus?.enabled == true, let relay = vault.relayClient else {
            toast = "AI isn't available on this device"
            return nil
        }
        do {
            let target: String? = action == .translate ? language : nil
            let out = try await relay.action(action.rawValue, text: text, language: target)
            Task { await refreshAIStatus() }
            let cards = out.cards.map { card in (front: card.front, back: card.back) }
            return NoteAI.Result(text: out.text, cards: cards, place: "cloud", model: out.model ?? "")
        } catch {
            toast = "Cloud AI didn't answer. It may be off, or this month's allowance is used up."
            await refreshAIStatus()
            return nil
        }
    }

    /// Ask AI on a lasso selection in the drawing editor: with Apple Intelligence, the on-device model
    /// works on the handwriting read off it (`text`); otherwise the relay's cloud AI gets the picture
    /// (`image`, PNG) when it's on. Nil (with a toast) when neither can.
    func runInkAI(_ action: InkAIAction, image: Data, text: String) async -> NoteAI.Result? {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if OnDeviceAI.isAvailable, !words.isEmpty {
            do {
                if action == .flashcards {
                    if let cards = try await OnDeviceAI.flashcards(from: words) {
                        return NoteAI.Result(text: "", cards: cards, place: "device", model: "")
                    }
                } else if let out = try await OnDeviceAI.rewrite(words, instruction: action.instruction) {
                    return NoteAI.Result(text: out, cards: [], place: "device", model: "")
                }
            } catch {
                // The on-device model declined or failed: try the cloud below if it's on.
            }
        }
        guard cloudAIStatus?.enabled == true, let relay = vault.relayClient else {
            toast = words.isEmpty ? "No handwriting found to ask about" : "AI isn't available on this device"
            return nil
        }
        do {
            let out = try await relay.action(action.rawValue, image: image)
            Task { await refreshAIStatus() }
            let cards = out.cards.map { card in (front: card.front, back: card.back) }
            return NoteAI.Result(text: out.text, cards: cards, place: "cloud", model: out.model ?? "")
        } catch {
            toast = "Cloud AI didn't answer. It may be off, or this month's allowance is used up."
            await refreshAIStatus()
            return nil
        }
    }

    /// Saves flashcards as a new note linked to `item`, and opens it.
    func saveFlashcards(_ result: NoteAI.Result, from item: Item) async {
        guard let library, !result.cards.isEmpty else { return }
        let id = await library.addFlashcards(result.cards, title: "Flashcards: " + item.displayTitle, from: item,
                                             where: result.place, model: result.model)
        await reload()
        selectedItemID = id
        toast = "Made \(result.cards.count) flashcards"
        Task { await syncNow() }
    }

    /// "Make this week's digest": writes (or rewrites) it and opens it.
    func makeDigest() async {
        guard let library else { return }
        let note = Digest.weekly(await library.items(), week: Digest.isoWeek(Date()))
        let id = await library.writeDigest(note)
        await reload()
        selectedItemID = id
        Task { await syncNow() }
    }

    /// The iPad's overnight AI worker (BackgroundTasks `enrich`, only scheduled where Apple Intelligence
    /// is available, while charging): works through everything other devices flagged
    /// `needsEnrichment`, a batch at a time, until the queue is empty or the system stops it.
    func enrichOvernight() async {
        guard let enrichment else { return }
        await enrichment.configure(relay: vault.relayClient, cloudEnabled: vault.config?.cloudAI ?? false)
        var rounds = 0
        while rounds < 40, !Task.isCancelled {
            let changed = await enrichment.run(limit: 20)
            rounds += 1
            if changed == 0 { break }
        }
        await reload()
    }

    /// After a sync: the relay's AI state, and (once per launch) last week's digest if no device made it yet.
    func afterSyncAI() async {
        await refreshAIStatus()
        guard !digestChecked, let library else { return }
        digestChecked = true
        if await library.autoDigest() != nil { await reload() }
    }
}
