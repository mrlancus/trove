import Foundation
import TroveCore

/// Your own AI (Settings → AI): a provider and API key you add once, used straight from this device
/// for Ask, note and page actions, and reading handwriting. Fast (the default), Smarter and Best
/// are the models you chose, at low effort for simple jobs (pages, keywords) and medium for Ask.
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
            let answer = try await ai.research(question, history: chat.turns, tools: askTools(library), tier: tier,
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

    /// The library as Ask sees it: pages it asks to look at are drawn here.
    func askTools(_ library: Library) -> AskTools {
        AskTools(library: library, pages: { item, first, count, section in
            let drawn = await Handwriting.pageImages(item, library: library, first: first, count: count, section: section)
            return AskTools.PageView(images: drawn.images, total: drawn.total, note: drawn.note)
        }, clipboard: aiSettings.clipboardAccess, pageBudget: aiSettings.pageBudget)
    }

    /// Lets your AI see an item or not.
    func setAIAllowed(_ item: Item, _ allowed: Bool) async {
        await library?.setAIAllowed(item.id, allowed)
        await reload()
        toast = allowed ? "Your AI can see this" : "Hidden from your AI"
    }

    /// Every item at once (Settings → AI).
    func setAIAllowedForAll(_ allowed: Bool) async {
        guard let library else { return }
        let changed = await library.setAIAllowedForAll(allowed)
        await reload()
        toast = changed == 0 ? "Nothing to change" : allowed ? "Your AI can see all \(items.count) items" : "Everything is hidden from your AI"
        Task { await syncNow() }
    }

    func deleteAIChat(_ id: String) async {
        aiChats.removeAll { $0.id == id }
        await library?.deleteAIChat(id)
    }
}

// MARK: Read all past handwriting

extension AppModel {
    /// Reading everything older with your AI, by hand (Settings → AI): how far it's got.
    struct HandwritingScan: Equatable {
        var total = 0
        var done = 0
        var pages = 0
        var current: String?
        var started = Date()
        var finished = false
        var stopped = false
        var fraction: Double { total == 0 ? 1 : Double(done) / Double(total) }
    }

    /// What it has cost so far (this device's handwriting requests since it started).
    var handwritingScanCost: Double {
        guard let scan = handwritingScan else { return 0 }
        let me = config?.deviceId ?? ""
        return AIUsage.Total(aiCalls.filter { $0.purpose == .handwriting && $0.at >= scan.started && $0.device == me }).cost
    }

    /// Items your AI hasn't read yet: sketches with ink, and GoodNotes notebooks, PDFs and pictures.
    func unreadHandwriting() async -> [Item] {
        guard let library else { return [] }
        var out: [Item] = []
        for item in await library.items() where item.aiAllowed {
            let ink = await library.inkSignature(item.id)
            if item.kind == .sketch {
                if !ink.hasPrefix("0-"), item.record[Handwriting.signatureField]?.string != ink + "|ai" { out.append(item) }
            } else if Handwriting.wantsFileRead(item), item.record[Handwriting.filesField]?.string != Handwriting.fileSignature(item, ink: ink) {
                out.append(item)
            }
        }
        return out
    }

    /// Reads every item your AI hasn't, one at a time, until done or stopped.
    func scanAllHandwriting() {
        guard handwritingScanTask == nil, let library, let ai = ownAI else { return }
        handwritingScanTask = Task { [weak self] in
            guard let self else { return }
            let items = await self.unreadHandwriting()
            var scan = HandwritingScan(total: items.count)
            self.handwritingScan = scan
            for item in items {
                if Task.isCancelled { break }
                scan.current = item.displayTitle
                self.handwritingScan = scan
                if item.kind == .sketch {
                    scan.pages += await Handwriting.read(item.id, library: library, ai: ai)
                } else {
                    scan.pages += await Handwriting.readFiles(item.id, library: library, ai: ai)
                }
                scan.done += 1
                self.handwritingScan = scan
            }
            scan.current = nil
            scan.stopped = Task.isCancelled
            scan.finished = true
            self.handwritingScan = scan
            self.handwritingScanTask = nil
            await self.reload()
            Task { await self.syncNow() }
        }
    }

    func stopHandwritingScan() {
        handwritingScanTask?.cancel()
    }
}

// MARK: Improve keywords with your AI

extension AppModel {
    /// Making AI keywords for everything, by hand (Settings → AI): how far it's got.
    struct KeywordRun: Equatable {
        var total = 0
        var done = 0
        var started = Date()
        var finished = false
        var stopped = false
        var error: String?
        var fraction: Double { total == 0 ? 1 : Double(done) / Double(total) }
    }

    /// What it has cost so far (this device's keyword requests since it started).
    var keywordRunCost: Double {
        guard let run = keywordRun else { return 0 }
        let me = config?.deviceId ?? ""
        return AIUsage.Total(aiCalls.filter { $0.purpose == .keywords && $0.at >= run.started && $0.device == me }).cost
    }

    /// How many items still need keywords and roughly what doing them all would cost.
    func keywordEstimate() async -> AIKeywording.Estimate? {
        guard let library else { return nil }
        let items = await library.itemsNeedingAIKeywords()
        let local = await KeywordCache.shared.keywords(for: await library.items().filter(\.aiAllowed))
        return AIKeywording.estimate(items, local: local, model: aiSettings.model(.fast))
    }

    /// Every item that needs them, 40 to a request, until done or stopped.
    func improveAllKeywords() {
        guard keywordTask == nil, let library, let ai = ownAI else { return }
        keywordTask = Task { [weak self] in
            guard let self else { return }
            let items = await library.itemsNeedingAIKeywords()
            let local = await KeywordCache.shared.keywords(for: await library.items().filter(\.aiAllowed))
            var run = KeywordRun(total: items.count)
            self.keywordRun = run
            var rest = items[...]
            while !rest.isEmpty, !Task.isCancelled {
                let batch = Array(rest.prefix(AIKeywording.batchSize))
                rest = rest.dropFirst(batch.count)
                do {
                    try await ai.improveKeywords(batch, local: local, library: library)
                } catch {
                    run.error = error.localizedDescription
                    break
                }
                run.done += batch.count
                self.keywordRun = run
            }
            run.stopped = Task.isCancelled
            run.finished = true
            self.keywordRun = run
            self.keywordTask = nil
            await self.reload()
            Task { await self.syncNow() }
        }
    }

    func stopKeywords() { keywordTask?.cancel() }
}
