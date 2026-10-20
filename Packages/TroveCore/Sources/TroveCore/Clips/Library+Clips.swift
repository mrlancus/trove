import Foundation

/// Clipboard history on top of the synced records (PROTOCOL.md §8).
extension Library {
    public static let clipLimit = 1_000
    public static let clipMaxAge: TimeInterval = 30 * 86_400

    /// Newest first (by last copy or use).
    public func clips() async -> [Clip] {
        await engine.records.filter { $0.kind == "clip" }.map(Clip.init).sorted { $0.sortDate > $1.sortDate }
    }

    public func clip(_ id: String) async -> Clip? {
        guard let r = await engine.record(id), r.kind == "clip", !r.isDeleted else { return nil }
        return Clip(r)
    }

    /// Records a copied string. The same text again just moves its clip back to the top. Returns
    /// nil for empty text; callers keep sensitive text out (`SensitiveDetector`).
    @discardableResult
    public func addClip(text: String, sourceApp: String? = nil, sourceDevice: String? = nil, source: ClipSource = ClipSource()) async -> String? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 256 * 1024 else { return nil }
        var fields: [String: JSONValue] = [Clip.Field.text: .string(text)]
        fields.merge(ClipInsights.of(text).json) { _, b in b }
        return await upsertClip(hash: Clip.hash(text: text), fields: fields, sourceApp: sourceApp, sourceDevice: sourceDevice, source: source)
    }

    /// Records copied files (paths; the Mac pastes them back as file URLs while they still exist).
    @discardableResult
    public func addClip(files: [String], sourceApp: String? = nil, sourceDevice: String? = nil) async -> String? {
        guard !files.isEmpty else { return nil }
        var fields: [String: JSONValue] = [Clip.Field.files: JSONValue(files), Clip.Field.text: .string(files.joined(separator: "\n"))]
        fields.merge(ClipInsights.of(files.joined(separator: "\n"), kind: .file).json) { _, b in b }
        fields[Clip.Field.autoTitle] = .string(files.map { ($0 as NSString).lastPathComponent }.joined(separator: ", "))
        return await upsertClip(hash: Clip.hash(files: files), fields: fields, sourceApp: sourceApp, sourceDevice: sourceDevice)
    }

    /// Records a copied image (stored encrypted as a blob, like attachments).
    @discardableResult
    public func addClip(image data: Data, mime: String = "image/png", sourceApp: String? = nil, sourceDevice: String? = nil,
                        source: ClipSource = ClipSource()) async throws -> String? {
        guard !data.isEmpty, data.count <= 20 * 1024 * 1024 else { return nil }
        let hash = Clip.hash(image: data)
        if let existing = await clips().first(where: { $0.hash == hash }) {
            await engine.set([Clip.Field.lastUsedAt: JSONValue(now()), Clip.Field.uses: .number(Double(existing.uses + 1))], record: existing.id, kind: "clip")
            return existing.id
        }
        let blob = try await engine.storeBlob(data)
        let ext = mime == "image/jpeg" ? "jpg" : (mime.split(separator: "/").last.map(String.init) ?? "png")
        let attachment = Attachment(id: blob, name: "Image.\(ext)", mime: mime, size: data.count)
        return await upsertClip(hash: hash, fields: [Clip.Field.image: attachment.json, Clip.Field.autoTitle: "Image"],
                                sourceApp: sourceApp, sourceDevice: sourceDevice, source: source)
    }

    private func upsertClip(hash: String, fields: [String: JSONValue], sourceApp: String?, sourceDevice: String?,
                            source: ClipSource = ClipSource()) async -> String {
        let at = JSONValue(now())
        if let existing = await clips().first(where: { $0.hash == hash }) {
            var bump: [String: JSONValue] = [Clip.Field.lastUsedAt: at, Clip.Field.uses: .number(Double(existing.uses + 1))]
            if let sourceApp { bump[Clip.Field.sourceApp] = .string(sourceApp) }
            bump.merge(source.json) { _, b in b }
            await engine.set(bump, record: existing.id, kind: "clip")
            return existing.id
        }
        var all = fields
        all[Clip.Field.hash] = .string(hash)
        all[Clip.Field.createdAt] = at
        all[Clip.Field.lastUsedAt] = at
        all[Clip.Field.device] = .string(await engine.device)
        all[Clip.Field.needsEnrichment] = true
        if let sourceApp { all[Clip.Field.sourceApp] = .string(sourceApp) }
        if let sourceDevice { all[Clip.Field.sourceDevice] = .string(sourceDevice) }
        all.merge(source.json) { _, b in b }
        let id = newId()
        await engine.set(all, record: id, kind: "clip")
        return id
    }

    /// Pasting from history moves the clip to the top.
    public func markClipUsed(_ id: String) async {
        let uses = await clip(id)?.uses ?? 0
        await engine.set([Clip.Field.lastUsedAt: JSONValue(now()), Clip.Field.uses: .number(Double(uses + 1))], record: id, kind: "clip")
    }

    // MARK: Editing

    /// Your own name for a clip ("" goes back to the automatic one).
    public func renameClip(_ id: String, to title: String) async {
        await engine.set([Clip.Field.title: .string(title.trimmingCharacters(in: .whitespacesAndNewlines))], record: id, kind: "clip")
    }

    /// Changes a text clip's text. Its insights are worked out again and AI looks at it again.
    public func editClip(_ id: String, text: String) async {
        guard let clip = await clip(id), clip.image == nil, clip.text != text, !text.isEmpty else { return }
        var fields: [String: JSONValue] = [Clip.Field.text: .string(text), Clip.Field.hash: .string(Clip.hash(text: text)),
                                           Clip.Field.editedAt: JSONValue(now()), Clip.Field.needsEnrichment: true,
                                           Clip.Field.aiTitle: .null, Clip.Field.summary: .null, Clip.Field.enrichment: .null]
        fields.merge(ClipInsights.of(text).json) { _, b in b }
        await engine.set(fields, record: id, kind: "clip")
    }

    public func setClipTags(_ id: String, _ tags: [String]) async {
        await engine.set([Clip.Field.tags: JSONValue(Self.cleanTags(tags))], record: id, kind: "clip")
    }

    public func setClipNote(_ id: String, _ note: String) async {
        await engine.set([Clip.Field.note: .string(note)], record: id, kind: "clip")
    }

    static func cleanTags(_ tags: [String]) -> [String] {
        var seen: Set<String> = []
        return tags.map { $0.lowercased().replacingOccurrences(of: "#", with: "").trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    // MARK: Enrichment

    /// Clips a device producing `tier` results should look at, newest first: never looked at, or
    /// still waiting for AI and only looked at by a weaker tier (like items, PROTOCOL.md §5).
    public func clipsNeedingEnrichment(below tier: Enrichment.Tier = .cloud, limit: Int = 10) async -> [Clip] {
        Array(await clips().filter { clip in
            guard let current = clip.enrichment else { return clip.needsEnrichment }
            return clip.needsEnrichment && current.tier < tier
        }.prefix(limit))
    }

    /// What enrichment found: a better title, a summary, tags (added to yours) and text in an image.
    /// Results from a weaker tier than the clip already has are dropped. It keeps waiting for AI
    /// until an on-device or cloud tier has looked at it.
    public func applyClipEnrichment(_ id: String, title: String? = nil, summary: String? = nil, tags: [String] = [], ocrText: String? = nil,
                                    tier: Enrichment.Tier, by: String) async {
        guard let clip = await clip(id) else { return }
        if let current = clip.enrichment, current.tier > tier { return }
        var fields: [String: JSONValue] = [Clip.Field.needsEnrichment: .bool(tier < .onDevice),
                                           Clip.Field.enrichment: Enrichment(tier: tier, by: by, at: now()).json]
        if let title, !title.isEmpty { fields[Clip.Field.aiTitle] = .string(title) }
        if let summary, !summary.isEmpty { fields[Clip.Field.summary] = .string(summary) }
        if !tags.isEmpty { fields[Clip.Field.tags] = JSONValue(Self.cleanTags(clip.tags + tags)) }
        if let ocrText, !ocrText.isEmpty {
            fields[Clip.Field.ocrText] = .string(ocrText)
            fields[Clip.Field.entities] = ClipInsights.of(ocrText).json[Clip.Field.entities]
        }
        await engine.set(fields, record: id, kind: "clip")
    }
    public func setClipPinned(_ id: String, _ pinned: Bool) async { await engine.set([Clip.Field.pinned: .bool(pinned)], record: id, kind: "clip") }
    public func deleteClip(_ id: String) async { await engine.delete(id) }

    /// Unpinned clips everyone can see. Deletes the oldest past `limit` and those older than `maxAge`.
    @discardableResult
    public func pruneClips(maxAge: TimeInterval = Library.clipMaxAge, limit: Int = Library.clipLimit) async -> Int {
        let cutoff = now().addingTimeInterval(-maxAge)
        var removed = 0
        for (index, clip) in await clips().enumerated() where !clip.isPinned && (clip.sortDate < cutoff || index >= limit) {
            await engine.delete(clip.id)
            removed += 1
        }
        return removed
    }

    /// Turns a clip into a library item (link, note or file), keeping the clip linked to it.
    @discardableResult
    public func saveClipToLibrary(_ id: String) async throws -> String? {
        guard let clip = await clip(id) else { return nil }
        if let existing = clip.savedItem, await item(existing) != nil { return existing }
        let itemId: String
        let named = clip.title ?? clip.aiTitle
        if let image = clip.image {
            itemId = try await addFile(try await attachmentData(image), name: image.name, mime: image.mime, source: .clipboard, title: named)
        } else if clip.kind == .link, let url = URL(string: clip.text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            itemId = await addLink(url, title: named ?? "", note: clip.note, source: .clipboard).id
        } else {
            itemId = await addNote(title: named ?? "", body: clip.note.isEmpty ? clip.text : clip.text + "\n\n" + clip.note, source: .clipboard)
        }
        // The item keeps where the copy came from.
        var origin: [String: JSONValue] = ["clip": .string(id)]
        if let app = clip.sourceApp { origin["app"] = .string(app) }
        if let url = clip.sourceURL { origin["url"] = .string(url.absoluteString) }
        if let title = clip.sourceTitle { origin["title"] = .string(title) }
        var fields: [String: JSONValue] = [Field.origin: .object(origin)]
        if !clip.tags.isEmpty, let item = await item(itemId) { fields[Field.tags] = JSONValue(Self.cleanTags(item.tags + clip.tags).sorted()) }
        if let summary = clip.summary { fields[Field.summary] = .string(summary) }
        if let ocr = clip.ocrText { fields[Field.ocrText] = .string(ocr) }
        await update(itemId, fields)
        await engine.set([Clip.Field.savedItem: .string(itemId)], record: id, kind: "clip")
        return itemId
    }
}

/// Where a copy came from, beyond the app's name (PROTOCOL.md §8).
public struct ClipSource: Sendable, Equatable {
    public var bundle: String?
    public var url: String?
    public var title: String?

    public init(bundle: String? = nil, url: String? = nil, title: String? = nil) {
        self.bundle = bundle; self.url = url; self.title = title
    }

    var json: [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        if let bundle, !bundle.isEmpty { out[Clip.Field.sourceBundle] = .string(bundle) }
        if let url, !url.isEmpty { out[Clip.Field.sourceURL] = .string(url) }
        if let title, !title.isEmpty { out[Clip.Field.sourceTitle] = .string(title) }
        return out
    }
}
