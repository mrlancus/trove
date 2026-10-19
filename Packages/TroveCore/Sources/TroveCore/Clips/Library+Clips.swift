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
    public func addClip(text: String, sourceApp: String? = nil, sourceDevice: String? = nil) async -> String? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 256 * 1024 else { return nil }
        return await upsertClip(hash: Clip.hash(text: text), fields: [Clip.Field.text: .string(text)], sourceApp: sourceApp, sourceDevice: sourceDevice)
    }

    /// Records copied files (paths; the Mac pastes them back as file URLs while they still exist).
    @discardableResult
    public func addClip(files: [String], sourceApp: String? = nil, sourceDevice: String? = nil) async -> String? {
        guard !files.isEmpty else { return nil }
        return await upsertClip(hash: Clip.hash(files: files), fields: [Clip.Field.files: JSONValue(files),
                                Clip.Field.text: .string(files.joined(separator: "\n"))], sourceApp: sourceApp, sourceDevice: sourceDevice)
    }

    /// Records a copied image (stored encrypted as a blob, like attachments).
    @discardableResult
    public func addClip(image data: Data, mime: String = "image/png", sourceApp: String? = nil, sourceDevice: String? = nil) async throws -> String? {
        guard !data.isEmpty, data.count <= 20 * 1024 * 1024 else { return nil }
        let hash = Clip.hash(image: data)
        if let existing = await clips().first(where: { $0.hash == hash }) {
            await engine.set([Clip.Field.lastUsedAt: JSONValue(now())], record: existing.id, kind: "clip")
            return existing.id
        }
        let blob = try await engine.storeBlob(data)
        let ext = mime == "image/jpeg" ? "jpg" : (mime.split(separator: "/").last.map(String.init) ?? "png")
        let attachment = Attachment(id: blob, name: "Image.\(ext)", mime: mime, size: data.count)
        return await upsertClip(hash: hash, fields: [Clip.Field.image: attachment.json], sourceApp: sourceApp, sourceDevice: sourceDevice)
    }

    private func upsertClip(hash: String, fields: [String: JSONValue], sourceApp: String?, sourceDevice: String?) async -> String {
        let at = JSONValue(now())
        if let existing = await clips().first(where: { $0.hash == hash }) {
            var bump: [String: JSONValue] = [Clip.Field.lastUsedAt: at]
            if let sourceApp { bump[Clip.Field.sourceApp] = .string(sourceApp) }
            await engine.set(bump, record: existing.id, kind: "clip")
            return existing.id
        }
        var all = fields
        all[Clip.Field.hash] = .string(hash)
        all[Clip.Field.createdAt] = at
        all[Clip.Field.lastUsedAt] = at
        all[Clip.Field.device] = .string(await engine.device)
        if let sourceApp { all[Clip.Field.sourceApp] = .string(sourceApp) }
        if let sourceDevice { all[Clip.Field.sourceDevice] = .string(sourceDevice) }
        let id = newId()
        await engine.set(all, record: id, kind: "clip")
        return id
    }

    /// Pasting from history moves the clip to the top.
    public func markClipUsed(_ id: String) async { await engine.set([Clip.Field.lastUsedAt: JSONValue(now())], record: id, kind: "clip") }
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
        if let image = clip.image {
            itemId = try await addFile(try await attachmentData(image), name: image.name, mime: image.mime, source: .app)
        } else if clip.kind == .link, let url = URL(string: clip.text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            itemId = await addLink(url).id
        } else {
            itemId = await addNote(body: clip.text)
        }
        await engine.set([Clip.Field.savedItem: .string(itemId)], record: id, kind: "clip")
        return itemId
    }
}
