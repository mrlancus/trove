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

    /// The best tier this device can produce right now.
    var bestTier: Enrichment.Tier {
        if OnDeviceAI.isAvailable { return .onDevice }
        if cloudEnabled, relay != nil { return .cloud }
        return .basic
    }

    /// Processes up to `limit` items; returns how many changed.
    @discardableResult
    func run(limit: Int = 25) async -> Int {
        guard !running else { return 0 }
        running = true
        defer { running = false }
        var changed = 0
        for item in await library.enrichmentQueue(below: bestTier).prefix(limit) {
            if Task.isCancelled { break }
            if await enrich(item) { changed += 1 }
        }
        for clip in await library.clipsNeedingEnrichment(upTo: bestTier, limit: 10) {
            if Task.isCancelled { break }
            await enrich(clip)
            changed += 1
        }
        // Handwriting in sketches, wherever they were drawn (it's read again only when the ink changed).
        var sketches = 0
        for item in await library.items() where item.kind == .sketch && sketches < 5 {
            if Task.isCancelled { break }
            guard item.record[Handwriting.signatureField]?.string != (await library.inkSignature(item.id)) else { continue }
            await Handwriting.read(item.id, library: library)
            sketches += 1
            changed += 1
        }
        return changed
    }

    /// Clips (PROTOCOL.md §8): read the text in images, then name, summarise and tag with the best
    /// tier here. Short copies get the rules only: AI has nothing to add to a phone number.
    private func enrich(_ clip: Clip) async {
        var ocr: String?
        var text = clip.text
        if let image = clip.image {
            if let found = clip.ocrText {
                ocr = found
            } else if let data = try? await library.attachmentData(image), let cg = PlatformImage.fromData(data)?.cgImageForVision {
                let recognized = await AppleEnricher.recognizeText(in: cg).trimmingCharacters(in: .whitespacesAndNewlines)
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
        if tier == .onDevice, let d = try? await OnDeviceAI.describe(text: prompt, url: url, existingTitle: nil) {
            await library.applyClipEnrichment(clip.id, title: d.title, summary: d.summary, tags: rulesTags + d.tags, ocrText: ocr, tier: .onDevice, by: deviceId)
        } else if tier == .cloud, let relay, let e = try? await relay.enrich(text: prompt, url: url, title: nil) {
            await library.applyClipEnrichment(clip.id, title: e.title, summary: e.summary, tags: rulesTags + e.tags, ocrText: ocr, tier: .cloud, by: e.model ?? "cloud")
        } else {
            // AI failed this time (offline, busy): keep what the rules found and try again later.
            await library.applyClipEnrichment(clip.id, title: rulesTitle, tags: rulesTags, ocrText: ocr, tier: .basic, by: deviceId)
        }
    }

    private func enrich(_ item: Item) async -> Bool {
        // ---- Tier 0 (only if never done) ----
        var text = item.body
        if item.enrichment == nil {
            var fields: [String: JSONValue] = [:]
            if item.kind == .link, let url = item.url {
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
                    recognized = await AppleEnricher.recognizeText(in: image)
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
            if let d = try? await OnDeviceAI.describe(text: material, url: item.url?.absoluteString, existingTitle: item.title) {
                await library.applyEnrichment(item.id, fields: aiFields(d.title, d.summary, d.tags, d.category), tier: .onDevice, by: deviceId)
            }
        } else if cloudEnabled, let relay {
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
