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
        return changed
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

    /// Clipboard history: text in copied images, then (with on-device AI, or cloud AI when the
    /// clipboard is allowed to use it) a title, a one-line summary and tags, so clips can be found
    /// by what they're about. Returns how many changed.
    @discardableResult
    func runClips(limit: Int = 15, cloudForClips: Bool) async -> Int {
        let tier: Enrichment.Tier = OnDeviceAI.isAvailable ? .onDevice : (cloudForClips && cloudEnabled && relay != nil ? .cloud : .basic)
        var changed = 0
        for clip in await library.clipsNeedingEnrichment(below: tier, limit: limit) {
            if Task.isCancelled { break }
            var ocr: String?
            if let image = clip.image, clip.ocrText == nil, let data = try? await library.attachmentData(image),
               let cg = PlatformImage.fromData(data)?.cgImageForVision {
                ocr = String(await AppleEnricher.recognizeText(in: cg).prefix(20_000))
            }
            let material = [clip.title ?? "", clip.text, ocr ?? clip.ocrText ?? "", clip.sourceTitle ?? "", clip.note]
                .filter { !$0.isEmpty }.joined(separator: "\n")
            var title: String?, summary: String?, tags: [String] = []
            let source = [clip.sourceApp, clip.sourceURL?.absoluteString].compactMap { $0 }.joined(separator: " · ")
            // Short copies (a word, a number, a colour) say all there is to say already. If the
            // model fails it isn't retried, so one awkward clip can't hold up the rest.
            if material.count < 25 || clip.kind == .color || clip.kind == .number {
            } else if tier == .onDevice {
                if let d = try? await OnDeviceAI.describe(text: material, url: source.isEmpty ? nil : "Copied from " + source, existingTitle: nil) {
                    title = d.title; summary = d.summary; tags = d.tags
                }
            } else if tier == .cloud, let relay {
                if let e = try? await relay.enrich(text: material, url: clip.sourceURL?.absoluteString, title: clip.sourceTitle) {
                    title = e.title; summary = e.summary; tags = e.tags
                }
            }
            await library.applyClipEnrichment(clip.id, title: title, summary: summary, tags: Array(tags.prefix(4)), ocrText: ocr,
                                              tier: tier, by: deviceId)
            changed += 1
        }
        return changed
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
