import Foundation

/// Clipboard history on top of the synced records (PROTOCOL.md §8).
extension Library {
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
        let tags = ClipInsights.ruleTags(text)
        if !tags.isEmpty { fields[Clip.Field.tags] = JSONValue(tags) }
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
        if let kind = await clip(id)?.kind, await clipAutoSaveKinds().contains(kind) { _ = try? await saveClipToLibrary(id) }
        return id
    }

    // MARK: Settings

    /// Synced clipboard settings: one record every device writes (PROTOCOL.md §8).
    public static let clipSettingsId = "settings.clipboard"

    /// Kinds of copy saved into the library as soon as they're copied (by the device that copied them).
    public func clipAutoSaveKinds() async -> Set<ClipKind> {
        guard let r = await engine.record(Self.clipSettingsId), !r.isDeleted else { return [] }
        return Set((r["autoSave"]?.stringArray ?? []).compactMap(ClipKind.init(rawValue:)))
    }

    public func setClipAutoSave(_ kinds: Set<ClipKind>) async {
        await engine.set(["autoSave": JSONValue(kinds.map(\.rawValue).sorted())], record: Self.clipSettingsId, kind: "setting")
    }

    /// How much history to keep (synced, so every device prunes the same way).
    public func clipKeep() async -> ClipKeep {
        guard let r = await engine.record(Self.clipSettingsId), !r.isDeleted else { return .standard }
        return ClipKeep(days: r["keepDays"]?.number.map { max(0, Int($0)) } ?? ClipKeep.standard.days,
                        count: r["keepCount"]?.number.map { max(0, Int($0)) } ?? ClipKeep.standard.count)
    }

    /// Changes how much history is kept, then prunes to it.
    public func setClipKeep(_ keep: ClipKeep) async {
        await engine.set(["keepDays": .number(Double(max(0, keep.days))), "keepCount": .number(Double(max(0, keep.count)))],
                         record: Self.clipSettingsId, kind: "setting")
        await pruneClips()
    }

    // MARK: Tags with colours (PROTOCOL.md §8)

    public static let tagSettingsId = "settings.tags"

    /// Your own tags: each has a colour and shows as a section to filter by (clipboard and library).
    public func customTags() async -> [CustomTag] {
        guard let r = await engine.record(Self.tagSettingsId), !r.isDeleted else { return [] }
        return CustomTag.list(from: r.fields)
    }

    /// Makes a tag (or changes its colour). Returns the cleaned name, nil if it was empty.
    @discardableResult
    public func setTagColor(_ name: String, _ color: TagColor) async -> String? {
        guard let tag = Self.cleanTags([name.split(whereSeparator: \.isWhitespace).joined(separator: "-")]).first, !tag.hasPrefix("_") else { return nil }
        await engine.set([tag: .string(color.rawValue)], record: Self.tagSettingsId, kind: "setting")
        return tag
    }

    /// Removes a tag: its colour, and the tag from every clip and item that has it.
    public func deleteTag(_ name: String) async {
        guard let tag = Self.cleanTags([name]).first, !tag.hasPrefix("_") else { return }
        await engine.set([tag: .null], record: Self.tagSettingsId, kind: "setting")
        for clip in await clips() where clip.tags.contains(tag) {
            await setClipTags(clip.id, clip.tags.filter { $0 != tag })
        }
        for item in await items() where item.tags.contains(where: { $0.lowercased() == tag }) {
            await update(item.id, [Field.tags: JSONValue(item.tags.filter { $0.lowercased() != tag })])
        }
    }

    /// Adds or removes one tag on a clip.
    public func toggleClipTag(_ id: String, _ tag: String) async {
        guard let clip = await clip(id), let tag = Self.cleanTags([tag]).first else { return }
        await setClipTags(id, clip.tags.contains(tag) ? clip.tags.filter { $0 != tag } : clip.tags + [tag])
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
                                           Clip.Field.aiTitle: .null, Clip.Field.summary: .null]
        fields.merge(ClipInsights.of(text).json) { _, b in b }
        fields[Clip.Field.tags] = JSONValue(Self.cleanTags(clip.tags + ClipInsights.ruleTags(text)))
        await engine.set(fields, record: id, kind: "clip")
    }

    public func setClipTags(_ id: String, _ tags: [String]) async {
        await engine.set([Clip.Field.tags: JSONValue(Self.cleanTags(tags))], record: id, kind: "clip")
    }

    public func setClipNote(_ id: String, _ note: String) async {
        await engine.set([Clip.Field.note: .string(note)], record: id, kind: "clip")
    }

    /// A tag name as stored: spaces become "-", like clips.js `cleanTagName`.
    static func cleanTagName(_ name: String) -> String? {
        cleanTags([name.trimmingCharacters(in: .whitespacesAndNewlines).split(whereSeparator: \.isWhitespace).joined(separator: "-")]).first
    }

    static func cleanTags(_ tags: [String]) -> [String] {
        var seen: Set<String> = []
        return tags.map { $0.lowercased().replacingOccurrences(of: "#", with: "").trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    // MARK: Enrichment

    /// Clips that text recognition or AI hasn't looked at yet, newest first. With `upTo` above
    /// `.basic`, also the last two weeks' clips that only the built-in rules have seen, so a device
    /// with AI (the iPad, or cloud AI) names and tags what the others copied.
    public func clipsNeedingEnrichment(upTo tier: Enrichment.Tier = .basic, limit: Int = 10) async -> [Clip] {
        let since = now().addingTimeInterval(-14 * 86_400)
        return Array(await clips().filter { clip in
            if clip.needsEnrichment { return true }
            guard let done = clip.enrichment, done.tier == .basic, tier > .basic else { return false }
            return clip.createdAt >= since
        }.prefix(limit))
    }

    /// What enrichment found: a better title, a summary, tags (added to yours) and text in an image.
    public func applyClipEnrichment(_ id: String, title: String? = nil, summary: String? = nil, tags: [String] = [], ocrText: String? = nil,
                                    tier: Enrichment.Tier, by: String) async {
        guard let clip = await clip(id) else { return }
        var fields: [String: JSONValue] = [Clip.Field.needsEnrichment: false, Clip.Field.enrichment: Enrichment(tier: tier, by: by, at: now()).json]
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
    /// Deletes a clip and where and when it was copied and pasted.
    public func deleteClip(_ id: String) async {
        await engine.delete(id)
        for e in await clipEvents(of: id) { await engine.set(["_deleted": .bool(true)], record: e.id, kind: ClipEvent.kind) }
    }

    /// Deletes unpinned clips older than `maxAge` and the oldest past `limit`. Left out, both come from
    /// the synced setting (`clipKeep`); 0 means no limit.
    @discardableResult
    public func pruneClips(maxAge: TimeInterval? = nil, limit: Int? = nil) async -> Int {
        let keep = await clipKeep()
        let maxAge = maxAge ?? (keep.days > 0 ? TimeInterval(keep.days) * 86_400 : 0)
        let limit = limit ?? keep.count
        let cutoff = maxAge > 0 ? now().addingTimeInterval(-maxAge) : .distantPast
        var removed = 0
        for (index, clip) in await clips().enumerated() where !clip.isPinned && (clip.sortDate < cutoff || (limit > 0 && index >= limit)) {
            await deleteClip(clip.id)
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

/// The colours a tag can have. The same names on every device; each app picks its own shade.
public enum TagColor: String, CaseIterable, Sendable {
    case red, orange, yellow, green, mint, teal, blue, indigo, purple, pink, brown, gray
}

/// A tag you made, with its colour (fields of the `settings.tags` record: tag → colour name).
public struct CustomTag: Identifiable, Hashable, Sendable {
    public let name: String
    public let color: TagColor
    public var id: String { name }
    public init(name: String, color: TagColor) { self.name = name; self.color = color }

    /// Sorted by name; unknown colours read as gray, removed tags (null) are skipped.
    static func list(from fields: [String: JSONValue]) -> [CustomTag] {
        fields.compactMap { key, value -> CustomTag? in
            guard !key.hasPrefix("_"), let name = value.string else { return nil }
            return CustomTag(name: key, color: TagColor(rawValue: name) ?? .gray)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

/// How much clipboard history to keep: clips used in the last `days` days, at most `count` of them
/// (pinned clips always stay). 0 means no limit.
public struct ClipKeep: Equatable, Hashable, Sendable {
    public var days: Int
    public var count: Int
    public init(days: Int, count: Int) { self.days = days; self.count = count }

    public static let standard = ClipKeep(days: 30, count: 1_000)
    /// The choices Settings offers (0 = forever / no limit).
    public static let dayChoices = [7, 30, 90, 180, 365, 730, 0]
    public static let countChoices = [500, 1_000, 5_000, 10_000, 50_000, 0]

    public static func daysTitle(_ days: Int) -> String {
        switch days {
        case 0: "Forever"
        case 7: "1 week"
        case 30: "1 month"
        case 90: "3 months"
        case 180: "6 months"
        case 365: "1 year"
        case 730: "2 years"
        default: "\(days) days"
        }
    }

    public static func countTitle(_ count: Int) -> String {
        count == 0 ? "No limit" : "\(count.formatted()) clips"
    }
}

// MARK: - Settings that follow you to every device (PROTOCOL.md §8, `settings.app`)

/// A preference kept in the vault, so changing it on one device changes it on all of them.
/// (Things that belong to one machine, like a folder path or a permission, stay on that machine.)
public enum SharedSetting: String, CaseIterable, Sendable {
    case clipboardHistory, holdSensitive, saveCopiesOnOpen, recordPages, autoUpdate, cloudAI
    /// Keep where you were (the device's location) with each copy and paste.
    case recordPlaces

    /// The value before anyone has changed it.
    public var standard: Bool { self != .cloudAI }
}

extension Library {
    public static let appSettingsId = "settings.app"

    /// The shared settings someone has set (missing ones are at their `standard` value).
    public func sharedSettings() async -> [SharedSetting: Bool] {
        guard let r = await engine.record(Self.appSettingsId), !r.isDeleted else { return [:] }
        var out: [SharedSetting: Bool] = [:]
        for key in SharedSetting.allCases { if let value = r[key.rawValue]?.bool { out[key] = value } }
        return out
    }

    public func setSharedSetting(_ key: SharedSetting, _ value: Bool) async {
        await engine.set([key.rawValue: .bool(value)], record: Self.appSettingsId, kind: "setting")
    }
}
