import Foundation
import TroveCore

/// Runs the enrichment tiers over the library (RESEARCH.md §3):
///  - Tier 0 everywhere: fetch link pages, schema.org, OCR images/PDFs, dates/places/people.
///  - Tier 1 where Foundation Models exist (the iPad): smart title, summary, tags, category.
///    Because AI results sync, the iPad effectively enriches items saved on the iPhone and Mac.
///  - Tier 3 (opt-in): the relay's Claude route, for when no on-device model is around.
actor EnrichmentService {
    let library: Library
    let deviceId: String
    var relay: RelayClient?
    var cloudEnabled: Bool
    /// Your own AI (Settings → AI), when it reads handwriting.
    private var ownAI: AIClient?
    /// After your AI fails to read (offline, out of credit), it's left alone for a while.
    private var aiPausedUntil = Date.distantPast
    private var running = false

    init(library: Library, deviceId: String, relay: RelayClient?, cloudEnabled: Bool) {
        self.library = library
        self.deviceId = deviceId
        self.relay = relay
        self.cloudEnabled = cloudEnabled
    }

    func configure(relay: RelayClient?, cloudEnabled: Bool) {
        self.relay = relay
        self.cloudEnabled = cloudEnabled
    }

    /// Background reading has spent this month's limit (it falls back to Vision until next month).
    private(set) var aiLimitReached = false

    func setOwnAI(_ ai: AIClient?) {
        ownAI = ai
        aiPausedUntil = .distantPast
    }

    /// Your AI, when it should read handwriting now.
    private var reader: AIClient? {
        guard let ownAI, ownAI.settings.readHandwriting, Date() >= aiPausedUntil else { return nil }
        return ownAI
    }

    /// The best tier this device can produce right now.
    var bestTier: Enrichment.Tier {
        if OnDeviceAI.isAvailable { return .onDevice }
        if cloudEnabled, relay != nil { return .cloud }
        return .basic
    }

    /// What one round did, for Settings → Battery.
    struct Round {
        var changed = 0
        var aiCalls = 0
        var visionPages = 0
        var requests = 0
    }

    /// One round within `budget` (`PowerPolicy.enrichment`: on battery only what this device saved in
    /// the last hour, a few at a time; everything on the charger). Stops early when the device gets hot.
    @discardableResult
    func run(budget: EnrichmentBudget) async -> Round {
        var round = Round()
        guard !running, !budget.isNone else { return round }
        running = true
        defer { running = false }
        let now = Date().timeIntervalSince1970
        let fast = budget.recognition == .fast
        func takes(_ record: Record, created: Date) -> Bool {
            budget.takes(creator: HLC(record.createdHLC)?.device, device: deviceId, created: created.timeIntervalSince1970, now: now)
        }
        let items = await library.enrichmentQueue(below: bestTier).filter { takes($0.record, created: $0.createdAt) }
        for item in items.prefix(budget.items) {
            if Task.isCancelled || PowerMonitor.tooHot { break }
            if await enrich(item, fast: fast, round: &round) { round.changed += 1 }
        }
        // Without AI, a text clip only needs marking as seen: do those in big batches, telling the
        // app once (a history imported from another app can be thousands of clips). Pictures (text
        // recognition) and AI naming stay a few at a time.
        let cheap = bestTier == .basic
        let queue = await library.clipsNeedingEnrichment(upTo: bestTier, limit: cheap ? 400 : 10)
        await library.engine.hold()
        var slow = 0
        for clip in queue {
            if Task.isCancelled || PowerMonitor.tooHot { break }
            if clip.image != nil || !cheap {
                guard slow < min(10, budget.items), takes(clip.record, created: clip.createdAt) else { continue }
                slow += 1
            }
            await enrich(clip, fast: fast, round: &round)
            round.changed += 1
        }
        await library.engine.release()
        // Handwriting in sketches, wherever they were drawn (it's read again only when the ink changed).
        // On battery it waits for the charger: the editor reads this device's own sketches when it closes.
        // With your AI the reading happens on its servers, so it doesn't wait for the charger: whatever
        // arrives (a GoodNotes notebook, a sketch from another device, a photo of a page) is read now.
        // Background reading stops for the month at your limit (Settings → AI), counted on every device.
        var ai = reader
        if let r = ai, r.settings.monthlyLimit > 0, await library.backgroundAISpend() >= r.settings.monthlyLimit {
            ai = nil
            aiLimitReached = true
        } else {
            aiLimitReached = false
        }
        let allowance = ai != nil ? max(budget.handwriting, 10) : budget.handwriting
        let all = await library.items()
        var sketches = 0
        for item in all where item.kind == .sketch && sketches < allowance {
            if Task.isCancelled || PowerMonitor.tooHot { break }
            let ink = await library.inkSignature(item.id)
            // Your AI reads what's new since live reading was turned on (older sketches wait for Read
            // all past handwriting); kept from your AI or older, Vision reads it on this device.
            let itemAI = ai.flatMap { a in item.aiAllowed && a.settings.isLive(item.record, inkSignature: ink) ? a : nil }
            let sig = ink + (itemAI == nil ? "" : "|ai")
            guard item.record[Handwriting.signatureField]?.string != sig else { continue }
            // Read by your AI before: keep that reading rather than redo it with Vision.
            if itemAI == nil, item.record[Handwriting.signatureField]?.string == ink + "|ai" { continue }
            round.visionPages += await Handwriting.read(item.id, library: library, fast: fast, ai: itemAI)
            sketches += 1
            round.changed += 1
            if itemAI != nil, await library.item(item.id)?.record[Handwriting.signatureField]?.string != sig { pauseAI(); break }
            if let r = ai, r.settings.monthlyLimit > 0, await library.backgroundAISpend() >= r.settings.monthlyLimit { aiLimitReached = true; break }
        }
        if let ai = reader, !aiLimitReached {
            var files = 0
            for item in all where files < 10 && item.aiAllowed && Handwriting.wantsFileRead(item) {
                if Task.isCancelled { break }
                let ink = await library.inkSignature(item.id)
                guard ai.settings.isLive(item.record, inkSignature: ink) else { continue }
                let sig = Handwriting.fileSignature(item, ink: ink)
                guard item.record[Handwriting.filesField]?.string != sig else { continue }
                round.requests += await Handwriting.readFiles(item.id, library: library, ai: ai)
                files += 1
                round.changed += 1
                if await library.item(item.id)?.record[Handwriting.filesField]?.string != sig { pauseAI(); break }
                if ai.settings.monthlyLimit > 0, await library.backgroundAISpend() >= ai.settings.monthlyLimit { aiLimitReached = true; break }
            }
        }
        // Keywords from your AI for what's new or changed this week (older items wait for Improve
        // keywords): one request of up to 40 a round, inside the monthly limit.
        if let ai = ownAI, ai.settings.liveKeywords, Date() >= aiPausedUntil, !aiLimitReached, !Task.isCancelled {
            let limit = ai.settings.monthlyLimit
            if limit == 0 || (await library.backgroundAISpend()) < limit {
                let recent = Int64(Date().addingTimeInterval(-7 * 86_400).timeIntervalSince1970 * 1000)
                let due = await library.itemsNeedingAIKeywords().filter { (HLC($0.record.updatedHLC)?.millis ?? 0) >= recent }
                if !due.isEmpty {
                    let local = await KeywordCache.shared.keywords(for: all.filter(\.aiAllowed))
                    do {
                        try await ai.improveKeywords(Array(due.prefix(AIKeywording.batchSize)), local: local, library: library)
                        round.requests += 1
                        round.changed += 1
                    } catch {
                        pauseAI()
                    }
                }
            } else {
                aiLimitReached = true
            }
        }
        return round
    }

    private func pauseAI() { aiPausedUntil = Date().addingTimeInterval(15 * 60) }

    /// Clips (PROTOCOL.md §8): read the text in images, then name, summarise and tag with the best
    /// tier here. Short copies get the rules only: AI has nothing to add to a phone number.
    private func enrich(_ clip: Clip, fast: Bool, round: inout Round) async {
        var ocr: String?
        var text = clip.text
        if let image = clip.image {
            if let found = clip.ocrText {
                ocr = found
            } else if let data = try? await library.attachmentData(image), let cg = PlatformImage.fromData(data)?.cgImageForVision {
                let recognized = await AppleEnricher.recognizeText(in: cg, fast: fast).trimmingCharacters(in: .whitespacesAndNewlines)
                round.visionPages += 1
                if !recognized.isEmpty { ocr = String(recognized.prefix(20_000)) }
            }
            text = ocr ?? ""
        }
        let rulesTitle = clip.image != nil ? text.split(separator: "\n").first.map { ClipInsights.of(String($0)).autoTitle } : nil
        let rulesTags = clip.image != nil && !text.isEmpty ? ClipInsights.ruleTags(text) : []
        let material = [clip.sourceTitle ?? "", text].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let tier = bestTier
        guard tier > .basic, material.count >= 40, clip.kind != .color, clip.kind != .file else {
            // Nothing more to learn: record it at this device's best tier so no one asks again.
            await library.applyClipEnrichment(clip.id, title: rulesTitle, tags: rulesTags, ocrText: ocr,
                                              tier: material.count >= 40 && clip.kind != .file ? .basic : tier, by: deviceId)
            return
        }
        let url = clip.kind == .link ? clip.text.trimmingCharacters(in: .whitespacesAndNewlines) : clip.sourceURL?.absoluteString
        let from = clip.sourceApp.map { " (from " + $0 + ")" } ?? ""
        let prompt = "A copy from the clipboard" + from + ". Name it for a clipboard history list.\n\n" + material
        round.aiCalls += 1
        if tier == .cloud { round.requests += 1 }
        if tier == .onDevice, let d = try? await OnDeviceAI.describe(text: prompt, url: url, existingTitle: nil) {
            await library.applyClipEnrichment(clip.id, title: d.title, summary: d.summary, tags: rulesTags + d.tags, ocrText: ocr, tier: .onDevice, by: deviceId)
        } else if tier == .cloud, let relay, let e = try? await relay.enrich(text: prompt, url: url, title: nil) {
            await library.applyClipEnrichment(clip.id, title: e.title, summary: e.summary, tags: rulesTags + e.tags, ocrText: ocr, tier: .cloud, by: e.model ?? "cloud")
        } else {
            // AI failed this time (offline, busy): keep what the rules found and try again later.
            await library.applyClipEnrichment(clip.id, title: rulesTitle, tags: rulesTags, ocrText: ocr, tier: .basic, by: deviceId)
        }
    }

    private func enrich(_ item: Item, fast: Bool, round: inout Round) async -> Bool {
        // ---- Tier 0 (only if never done) ----
        var text = item.body
        if item.enrichment == nil {
            var fields: [String: JSONValue] = [:]
            if item.kind == .link, let url = item.url {
                round.requests += 1
                if let html = try? await AppleEnricher.fetchHTML(url) {
                    let link = BasicEnricher.enrich(html: html, url: url)
                    fields.merge(link.fields(existingTitle: item.title)) { _, new in new }
                    text = link.readableText
                }
            }
            for attachment in item.attachments.prefix(3) {
                guard let data = try? await library.attachmentData(attachment) else { continue }
                var recognized = ""
                if attachment.mime == "application/pdf" {
                    recognized = await AppleEnricher.pdfText(data)
                } else if attachment.mime.hasPrefix("image/"), let image = PlatformImage.fromData(data)?.cgImageForVision {
                    recognized = await AppleEnricher.recognizeText(in: image, fast: fast)
                    round.visionPages += 1
                }
                if !recognized.isEmpty {
                    fields[Field.ocrText] = .string(String(recognized.prefix(50_000)))
                    text += "\n" + recognized
                }
            }
            let detected = AppleEnricher.detect(in: [item.title, text].joined(separator: "\n"))
            fields.merge(AppleEnricher.fields(for: detected, existing: (fields[Field.extracted]?.object) ?? item.extracted)) { old, new in
                // tags from the page + entity tags
                if let a = old.stringArray.nilIfEmpty, let b = new.array { return JSONValue(Array(Set(a + b.compactMap(\.string)))) }
                return new
            }
            if fields[Field.category] == nil, item.kind == .note { fields[Field.category] = .string(ItemCategory.note.rawValue) }
            if fields[Field.summary] == nil, item.kind != .note, let s = BasicEnricher.firstSentences(text, maxLength: 220) {
                fields[Field.summary] = .string(s)
            }
            await library.applyEnrichment(item.id, fields: fields, tier: .basic, by: deviceId)
        } else {
            text = [item.body, item.ocrText ?? "", item.summary ?? ""].joined(separator: "\n")
        }

        // ---- Tier 1 / Tier 3 ----
        let material = [item.title, text].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard material.count >= 40 else { return true }
        if OnDeviceAI.isAvailable {
            round.aiCalls += 1
            if let d = try? await OnDeviceAI.describe(text: material, url: item.url?.absoluteString, existingTitle: item.title) {
                await library.applyEnrichment(item.id, fields: aiFields(d.title, d.summary, d.tags, d.category), tier: .onDevice, by: deviceId)
            }
        } else if cloudEnabled, let relay {
            round.aiCalls += 1
            round.requests += 1
            if let e = try? await relay.enrich(text: material, url: item.url?.absoluteString, title: item.title) {
                await library.applyEnrichment(item.id, fields: aiFields(e.title, e.summary, e.tags, e.kind), tier: .cloud, by: e.model ?? "cloud")
            }
        }
        return true
    }

    private func aiFields(_ title: String, _ summary: String, _ tags: [String], _ category: String) -> [String: JSONValue] {
        var f: [String: JSONValue] = [Field.summary: .string(summary), Field.tags: JSONValue(tags)]
        f[Field.title] = .string(title)  // Library keeps a title the user typed
        if ItemCategory(rawValue: category) != nil { f[Field.category] = .string(category) }
        return f
    }
}

private extension Array {
    var nilIfEmpty: Self? { isEmpty ? nil : self }
}
