import Foundation

/// Folders (PROTOCOL.md §9), file versions and text history.
extension Library {
    // MARK: Folders

    public func folders() async -> [Folder] {
        await engine.records.filter { $0.kind == "folder" }.map(Folder.init)
    }

    /// The fields that file a new item into its folder (made if needed), chosen by `Organizer`.
    func filing(kind: ItemKind, category: ItemCategory? = nil, source: ItemSource, fileName: String? = nil,
                collection: String? = nil, importPath: [String] = []) async -> [String: JSONValue] {
        let path = Organizer.path(kind: kind, category: category, source: source, fileName: fileName, collection: collection, importPath: importPath)
        guard let id = await ensureFolder(path) else { return [:] }
        return [Field.folder: .string(id), Field.folderAuto: true]
    }

    /// The folder at this path, making any that are missing. Existing folders are matched by name
    /// (ignoring case) under the same parent, so renamed or hand-made folders are reused.
    @discardableResult
    public func ensureFolder(_ path: [String], auto: Bool = true) async -> String? {
        var parent: String?
        var all = await folders()
        for raw in path {
            let name = Organizer.cleanName(raw)
            guard !name.isEmpty else { continue }
            if let existing = all.first(where: { $0.parent == parent && $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                parent = existing.id
                continue
            }
            var id = Organizer.folderId(parent: parent, name: name)
            if let taken = await engine.record(id), !taken.isDeleted { id += "~" + String(newId().prefix(6)) }
            await engine.set(["name": .string(name), "parent": parent.map(JSONValue.string) ?? .null, "auto": .bool(auto),
                              Field.createdAt: JSONValue(now()), "_deleted": false], record: id, kind: "folder")
            all = await folders()
            parent = id
        }
        return parent
    }

    @discardableResult
    public func createFolder(_ name: String, in parent: String? = nil) async -> String {
        let trimmed = Organizer.cleanName(name).isEmpty ? "Untitled" : Organizer.cleanName(name)
        if let existing = await folders().first(where: { $0.parent == parent && $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return existing.id
        }
        var id = Organizer.folderId(parent: parent, name: trimmed)
        if let taken = await engine.record(id), !taken.isDeleted { id += "~" + String(newId().prefix(6)) }
        await engine.set(["name": .string(trimmed), "parent": parent.map(JSONValue.string) ?? .null,
                          "auto": false, Field.createdAt: JSONValue(now()), "_deleted": false], record: id, kind: "folder")
        return id
    }

    public func renameFolder(_ id: String, to name: String) async {
        let trimmed = Organizer.cleanName(name)
        guard !trimmed.isEmpty else { return }
        await engine.set(["name": .string(trimmed), "auto": false], record: id, kind: "folder")
    }

    /// Moves a folder inside another (nil = top level). Refuses to move a folder into itself.
    public func moveFolder(_ id: String, into parent: String?) async {
        let all = await folders()
        if let parent, Folder.path(of: parent, in: all).contains(where: { $0.id == id }) { return }
        await engine.set(["parent": parent.map(JSONValue.string) ?? .null], record: id, kind: "folder")
    }

    /// Deletes a folder. What was inside (items and folders) moves up to its parent.
    public func deleteFolder(_ id: String) async {
        let all = await folders()
        guard let folder = all.first(where: { $0.id == id }) else { return }
        let up: JSONValue = folder.parent.map(JSONValue.string) ?? .null
        for child in all where child.parent == id { await engine.set(["parent": up], record: child.id, kind: "folder") }
        for item in await items() where item.folder == id { await update(item.id, [Field.folder: up]) }
        await engine.delete(id)
    }

    /// Moves an item by hand (nil = no folder). The organiser leaves it there from then on.
    public func move(_ itemId: String, to folder: String?) async {
        await update(itemId, [Field.folder: folder.map(JSONValue.string) ?? .null, Field.folderAuto: false])
    }

    /// Files every item that has no folder (or whose folder was deleted). Returns how many moved.
    @discardableResult
    public func tidyUp() async -> Int {
        let live = Set(await folders().map(\.id))
        var moved = 0
        for item in await items() where item.folder.map({ !live.contains($0) }) ?? true {
            let fields = await filing(kind: item.kind, category: item.record[Field.category] == nil ? nil : item.category, source: item.source,
                                      fileName: item.attachments.first?.name)
            if !fields.isEmpty { await update(item.id, fields); moved += 1 }
        }
        return moved
    }

    // MARK: File versions

    static let maxFileVersions = 50

    /// The item's version list with `old` added at the front.
    func versions(adding old: Attachment, to item: Item) async -> JSONValue {
        let entry = FileVersion(attachment: old, at: now(), by: await engine.device)
        return .array(([entry] + item.fileVersions.filter { $0.attachment.id != old.id }).prefix(Self.maxFileVersions).map(\.json))
    }

    /// Saves an edited file as the item's current file; the previous one is kept as a version.
    public func replaceFile(_ itemId: String, data: Data, name: String? = nil, mime: String? = nil) async throws {
        guard let item = await item(itemId), let current = item.attachments.first else { return }
        let blob = try await engine.storeBlob(data)
        guard blob != current.id else { return }
        let next = Attachment(id: blob, name: name ?? current.name, mime: mime ?? current.mime, size: data.count)
        await update(itemId, [Field.attachments: .array([next.json] + item.attachments.dropFirst().map(\.json)),
                              Field.fileVersions: await versions(adding: current, to: item), Field.thumbnail: .null])
    }

    /// Makes an earlier version current again (the current file becomes a version, so nothing is lost).
    public func restoreFileVersion(_ itemId: String, _ version: FileVersion) async {
        guard let item = await item(itemId), let current = item.attachments.first, current.id != version.attachment.id else { return }
        var list = item.fileVersions.filter { $0.attachment.id != version.attachment.id }
        list.insert(FileVersion(attachment: current, at: now(), by: await engine.device), at: 0)
        await update(itemId, [Field.attachments: .array([version.attachment.json] + item.attachments.dropFirst().map(\.json)),
                              Field.fileVersions: .array(list.prefix(Self.maxFileVersions).map(\.json)), Field.thumbnail: .null])
    }

    // MARK: Text history

    /// Earlier versions of an item's text, newest first: one per editing session (edits from the
    /// same device less than `gap` apart count as one session).
    public func textVersions(_ itemId: String, field: String = Field.body, gap: TimeInterval = 120) async -> [TextVersion] {
        let ops = await engine.store.allOps.filter { $0.record == itemId && $0.type == .text && $0.text?.field == field }
        var out: [TextVersion] = []
        for op in ops {
            guard let edit = op.text, let hlc = HLC(op.hlc) else { continue }
            let at = Date(timeIntervalSince1970: Double(hlc.millis) / 1000)
            if let last = out.last, last.device == op.device, at.timeIntervalSince(last.at) < gap {
                out[out.count - 1] = TextVersion(text: edit.value, at: at, device: op.device)
            } else {
                out.append(TextVersion(text: edit.value, at: at, device: op.device))
            }
        }
        return out.reversed()
    }
}

/// A saved state of a note's text.
public struct TextVersion: Hashable, Sendable {
    public var text: String
    public var at: Date
    public var device: String
}
