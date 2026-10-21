import Foundation

/// The app-facing API: add, edit, import, search. Wraps `SyncEngine` (state + sync) and keeps the
/// local `SearchIndex` in step. UI code wraps this in an @Observable model on the main actor.
public actor Library {
    public let engine: SyncEngine
    private var index = SearchIndex()
    private var indexed: [String: String] = [:]   // record id → updatedHLC already indexed
    let now: @Sendable () -> Date

    public init(engine: SyncEngine, now: @escaping @Sendable () -> Date = { Date() }) {
        self.engine = engine
        self.now = now
    }

    // MARK: Reading

    public func items() async -> [Item] {
        await refreshIndex()
        return await engine.records(kind: "item").filter { !$0.isStrayItem }.map(Item.init).sorted { $0.createdAt > $1.createdAt }
    }

    public func item(_ id: String) async -> Item? {
        guard let r = await engine.record(id), r.kind == "item", !r.isDeleted, !r.isStrayItem else { return nil }
        return Item(r)
    }

    public func search(_ text: String, semantic: [String: Double] = [:], limit: Int = 100) async -> [Item] {
        await refreshIndex()
        return index.search(.parse(text), semantic: semantic, limit: limit).map(\.item)
    }

    /// The search index as it stands, for searching on every keystroke without waiting on this actor
    /// (it's a value, so the copy is cheap and the caller's searches don't block syncing).
    /// Changes when any record of these kinds is added, changed or deleted (count and newest HLC),
    /// so a screen can skip refreshing when a sync brought nothing new.
    public func stamp(of kinds: Set<String>) async -> String {
        let s = await engine.store.stamp(of: kinds)
        return "\(s.count)|\(s.newest)"
    }

    public func searchIndex() async -> SearchIndex {
        await refreshIndex()
        return index
    }

    public func items(in smart: SmartCollection) async -> [Item] {
        await items().filter(smart.contains)
    }

    public func collections() async -> [ItemCollection] {
        await engine.records(kind: "collection").map(ItemCollection.init).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Work for this device's enrichment pass: never-enriched items, plus items still flagged as
    /// wanting more whose current tier is below what this device can do (the iPad passes `.onDevice`).
    public func enrichmentQueue(below tier: Enrichment.Tier) async -> [Item] {
        await items().filter { item in
            guard let current = item.enrichment else { return true }
            return item.needsEnrichment && current.tier < tier
        }
    }

    private func refreshIndex() async {
        for record in await engine.store.all(kind: "item") where !record.isStrayItem {
            let id = record.id
            if indexed[id] != record.updatedHLC {
                index.update(Item(record))
                indexed[id] = record.updatedHLC
            }
        }
        index.prepare()
    }

    // MARK: Adding

    func newId() -> String { UUID().uuidString.lowercased() }

    func baseFields(kind: ItemKind, source: ItemSource, title: String, createdAt: Date? = nil) async -> [String: JSONValue] {
        [
            Field.kind: .string(kind.rawValue), Field.source: .string(source.rawValue), Field.title: .string(title),
            Field.createdAt: JSONValue(createdAt ?? now()), Field.capturedOn: .string(await engine.device),
            Field.needsEnrichment: true,
        ]
    }

    @discardableResult
    public func addNote(title: String = "", body: String, tags: [String] = [], source: ItemSource = .app,
                        id: String? = nil, folder: [String] = []) async -> String {
        let id = id ?? newId()
        var fields = await baseFields(kind: .note, source: source, title: title)
        fields[Field.category] = .string(ItemCategory.note.rawValue)
        fields.merge(await filing(kind: .note, source: source, importPath: folder)) { _, b in b }
        let allTags = Array(Set(tags.map { $0.lowercased() } + Markdown.hashtags(in: body))).sorted()
        if !allTags.isEmpty { fields[Field.tags] = JSONValue(allTags) }
        await engine.set(fields, record: id, kind: "item")
        if !body.isEmpty { await engine.editText(Field.body, value: body, record: id, kind: "item") }
        return id
    }

    /// Adds a link, or returns the existing item if the same page was saved before.
    @discardableResult
    public func addLink(_ url: URL, title: String = "", note: String = "", source: ItemSource = .app,
                        id: String? = nil, folder: [String] = []) async -> (id: String, isNew: Bool) {
        let cleaned = URLCleaner.clean(url)
        let key = URLCleaner.dedupeKey(cleaned)
        if let existing = await items().first(where: { $0.url.map(URLCleaner.dedupeKey) == key }) {
            await noteSource(source, on: existing)
            return (existing.id, false)
        }
        let id = id ?? newId()
        var fields = await baseFields(kind: .link, source: source, title: title)
        fields[Field.url] = .string(cleaned.absoluteString)
        fields.merge(await filing(kind: .link, source: source, importPath: folder)) { _, b in b }
        await engine.set(fields, record: id, kind: "item")
        if !note.isEmpty { await engine.editText(Field.body, value: note, record: id, kind: "item") }
        return (id, true)
    }

    /// Stores the bytes (encrypted) and creates an item for them.
    @discardableResult
    public func addFile(_ data: Data, name: String, mime: String, kind: ItemKind? = nil, source: ItemSource = .app,
                        title: String? = nil, createdAt: Date? = nil, id: String? = nil, folder: [String] = []) async throws -> String {
        let blob = try await engine.storeBlob(data)
        let id = id ?? newId()
        let resolvedKind = kind ?? Self.kind(forMime: mime)
        var fields = await baseFields(kind: resolvedKind, source: source, title: title ?? Self.titleFromFileName(name), createdAt: createdAt)
        fields[Field.attachments] = [Attachment(id: blob, name: name, mime: mime, size: data.count).json]
        fields.merge(await filing(kind: resolvedKind, source: source, fileName: name, importPath: folder)) { _, b in b }
        await engine.set(fields, record: id, kind: "item")
        return id
    }

    /// The same thing arrived again from somewhere else: list it under that source too.
    func noteSource(_ source: ItemSource, on item: Item) async {
        guard !item.sources.contains(source), source != .app else { return }
        await update(item.id, [Field.alsoFrom: JSONValue(item.sources.dropFirst().map(\.rawValue) + [source.rawValue])])
    }

    public static func kind(forMime mime: String) -> ItemKind {
        if mime.hasPrefix("image/") { return .image }
        if mime == "application/pdf" { return .pdf }
        if mime.hasPrefix("audio/") { return .audio }
        if mime.hasPrefix("video/") { return .video }
        return .file
    }

    static func titleFromFileName(_ name: String) -> String {
        let base = (name as NSString).deletingPathExtension
        return base.replacingOccurrences(of: "[_-]+", with: " ", options: .regularExpression).trimmed
    }

    public func attachmentData(_ attachment: Attachment) async throws -> Data {
        try await engine.loadBlob(attachment.id)
    }

    // MARK: Editing

    /// Changes an item's fields. An id with no item behind it is left alone: writing to it would
    /// make an empty "Untitled" item dated 1970 on every device (PROTOCOL.md §3).
    public func update(_ id: String, _ fields: [String: JSONValue]) async {
        guard let r = await engine.record(id), r.kind == "item" else { return }
        await engine.set(fields, record: id, kind: "item")
    }

    public func setBody(_ id: String, _ text: String) async {
        guard let r = await engine.record(id), r.kind == "item" else { return }
        await engine.editText(Field.body, value: text, record: id, kind: "item")
        let tags = Markdown.hashtags(in: text)
        if let item = await item(id), !tags.isEmpty, !Set(tags).isSubset(of: Set(item.tags)) {
            await update(id, [Field.tags: JSONValue(Array(Set(item.tags + tags)).sorted())])
        }
    }

    public func setPinned(_ id: String, _ pinned: Bool) async { await update(id, [Field.pinned: .bool(pinned)]) }
    public func markRead(_ id: String, _ read: Bool = true) async { await update(id, [Field.readAt: read ? JSONValue(now()) : .null]) }
    public func delete(_ id: String) async { await engine.delete(id) }

    /// Keeps the current body and drops the stored conflict copies (after the user resolved them).
    public func resolveConflicts(_ id: String, keeping text: String) async {
        await engine.editText(Field.body, value: text, record: id, kind: "item")
        let seen = await engine.record(id)?.conflicts[Field.body]?.count ?? 0
        await update(id, [Field.resolvedConflicts: .number(Double(seen))])
    }

    /// Writes enrichment results unless a stronger tier already wrote them.
    @discardableResult
    public func applyEnrichment(_ id: String, fields: [String: JSONValue], tier: Enrichment.Tier, by: String) async -> Bool {
        guard let item = await item(id) else { return false }
        if let current = item.enrichment, current.tier > tier { return false }
        var f = fields
        if !item.title.isEmpty { f[Field.title] = nil }  // never replace a title the user typed
        if let tags = f[Field.tags]?.stringArray {      // merge, don't replace, tags
            f[Field.tags] = JSONValue(Array(Set(item.tags + tags.map { $0.lowercased() })).sorted())
        }
        f[Field.enrichment] = Enrichment(tier: tier, by: by, at: now()).json
        f[Field.needsEnrichment] = .bool(tier < .onDevice)
        // Re-file an item the organiser placed when it turns out to be, say, a recipe.
        if item.isAutoFiled || item.folder == nil, let raw = f[Field.category]?.string, let category = ItemCategory(rawValue: raw),
           category != item.category {
            let filed = await filing(kind: item.kind, category: category, source: item.source, fileName: item.attachments.first?.name)
            if filed[Field.folder] != item.record[Field.folder] { f.merge(filed) { _, b in b } }
        }
        await update(id, f)
        return true
    }

    // MARK: Price watches and published links

    /// Turns "Track price drops" on or off. The relay watch itself is created by `PriceWatchSync`
    /// on whichever device has the relay, so this works on iCloud-only devices too.
    public func setWatching(_ id: String, url: URL?) async {
        await update(id, [Field.priceWatch: url.map { ["url": .string($0.absoluteString)] } ?? .null])
    }

    public func setPublished(_ id: String, _ link: PublishedLink?) async {
        await update(id, [Field.published: link.map { ["slug": .string($0.slug), "url": .string($0.url.absoluteString)] } ?? .null])
    }

    /// Copies relay watch results onto their items. Returns the drops this device hadn't seen yet.
    @discardableResult
    public func applyWatches(_ watches: [RelayClient.Watch]) async -> [PriceDrop] {
        var drops: [PriceDrop] = []
        for watch in watches {
            guard let item = await item(watch.itemId ?? watch.id), let current = item.priceWatch, current.url == watch.url,
                  let price = watch.price else { continue }
            let droppedAt = watch.droppedAt.map { Date(timeIntervalSince1970: $0 / 1000) }
            let previous = watch.history.count >= 2 ? watch.history[watch.history.count - 2].price : nil
            let checkedAt = watch.checkedAt.map { Date(timeIntervalSince1970: $0 / 1000) }
            if current.price == price, current.lowest == watch.lowest, current.droppedAt == droppedAt, current.currency == watch.currency {
                continue
            }
            var o: [String: JSONValue] = ["url": .string(watch.url), "price": .number(price)]
            if let lowest = watch.lowest { o["lowest"] = .number(lowest) }
            if let currency = watch.currency { o["currency"] = .string(currency) }
            if let checkedAt { o["checkedAt"] = JSONValue(checkedAt) }
            if let droppedAt { o["droppedAt"] = JSONValue(droppedAt) }
            if let previous { o["previous"] = .number(previous) }
            await update(item.id, [Field.priceWatch: .object(o)])
            if let droppedAt, droppedAt != current.droppedAt, let previous, price < previous {
                drops.append(PriceDrop(itemId: item.id, title: item.displayTitle, price: price, previous: previous, currency: watch.currency))
            }
        }
        return drops
    }

    // MARK: Collections

    @discardableResult
    public func createCollection(_ name: String, symbol: String = "folder", color: String = "blue") async -> String {
        if let existing = await collections().first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) { return existing.id }
        let id = newId()
        await engine.set(["name": .string(name), "symbol": .string(symbol), "color": .string(color), Field.createdAt: JSONValue(now())],
                         record: id, kind: "collection")
        return id
    }

    public func add(_ itemId: String, to collectionId: String) async {
        guard let item = await item(itemId), !item.collections.contains(collectionId) else { return }
        await update(itemId, [Field.collections: JSONValue(item.collections + [collectionId])])
    }

    public func remove(_ itemId: String, from collectionId: String) async {
        guard let item = await item(itemId) else { return }
        await update(itemId, [Field.collections: JSONValue(item.collections.filter { $0 != collectionId })])
    }

    // MARK: Imports

    /// Adds imported items, skipping ones already imported (by external id). Returns how many were added.
    @discardableResult
    public func importItems(_ imported: [ImportedItem]) async -> Int {
        let existing = Set(await items().compactMap { $0.record[Field.origin]?.object?["externalId"]?.string })
        var collectionIds: [String: String] = [:]
        var added = 0
        for entry in imported {
            if let ext = entry.externalId, existing.contains(ext) { continue }
            let id = newId()
            var fields = await baseFields(kind: entry.kind, source: entry.source, title: entry.title, createdAt: entry.createdAt)
            if let url = entry.url { fields[Field.url] = .string(url) }
            if !entry.tags.isEmpty { fields[Field.tags] = JSONValue(entry.tags) }
            if let author = entry.author { fields[Field.author] = .string(author) }
            if entry.kind == .highlight { fields[Field.category] = .string(ItemCategory.quote.rawValue) }
            if let ext = entry.externalId { fields[Field.origin] = ["externalId": .string(ext)] }
            fields.merge(await filing(kind: entry.kind, category: entry.kind == .highlight ? .quote : nil, source: entry.source,
                                      collection: entry.collection)) { _, b in b }
            if let name = entry.collection {
                if collectionIds[name] == nil { collectionIds[name] = await createCollection(name) }
                fields[Field.collections] = JSONValue([collectionIds[name]!])
            }
            await engine.set(fields, record: id, kind: "item")
            if !entry.body.isEmpty { await engine.editText(Field.body, value: entry.body, record: id, kind: "item") }
            added += 1
        }
        return added
    }

    /// Turns a decrypted inbox envelope (email, GoodNotes WebDAV, browser, iOS share) into an item.
    /// A newer GoodNotes backup of the same notebook replaces the older PDF instead of duplicating it.
    ///
    /// `entryId` is the relay's inbox id. The new item's id is made from it, so when two devices
    /// (say the website and the Mac) import the same entry at once they write the same item.
    @discardableResult
    public func importInbox(_ envelope: InboxEnvelope, entryId: String? = nil) async throws -> String {
        let h = envelope.header
        let newItemId = entryId.map(Self.inboxItemId) ?? newId()
        switch h.source {
        case "webdav":
            let path = h.meta?["davPath"]?.string ?? h.name ?? "notebook.pdf"
            let blob = try await engine.storeBlob(envelope.body)
            let name = h.name ?? "notebook.pdf"
            let mime = h.mime ?? FileImport.mime(forExtension: (name as NSString).pathExtension)
            let attachment = Attachment(id: blob, name: name, mime: mime == "application/octet-stream" && name.hasSuffix(".pdf") ? "application/pdf" : mime,
                                        size: envelope.body.count)
            if let existing = await items().first(where: { $0.record[Field.origin]?.object?["davPath"]?.string == path }) {
                // A newer backup of the same notebook: keep the old one as a version.
                var fields: [String: JSONValue] = [Field.attachments: [attachment.json], Field.needsEnrichment: true, Field.ocrText: .null,
                                                   Field.enrichment: .null, Field.thumbnail: .null]
                if let old = existing.attachments.first, old.id != attachment.id {
                    fields[Field.fileVersions] = await versions(adding: old, to: existing)
                }
                await update(existing.id, fields)
                return existing.id
            }
            let id = newItemId
            var fields = await baseFields(kind: attachment.mime == "application/pdf" ? .pdf : .file, source: .goodnotes,
                                          title: Self.titleFromFileName(name))
            fields[Field.attachments] = [attachment.json]
            fields[Field.origin] = ["davPath": .string(path)]
            fields.merge(await filing(kind: .pdf, source: .goodnotes)) { _, b in b }
            await engine.set(fields, record: id, kind: "item")
            return id

        case "email":
            if let mime = h.mime, mime == "text/html" || mime == "text/plain" {
                let raw = String(decoding: envelope.body, as: UTF8.self)
                let text = mime == "text/html" ? HTMLMetadata(html: raw).readableText : raw
                let id = newItemId
                var fields = await baseFields(kind: .email, source: .email, title: h.title ?? "Email")
                var origin: [String: JSONValue] = [:]
                if let g = h.groupId { origin["emailGroup"] = .string(g) }
                if let from = h.meta?["from"] { origin["from"] = from }
                fields[Field.origin] = .object(origin)
                let isReceipt = AutoTagger.category(url: nil, schema: .init(), text: text) == .receipt
                if isReceipt { fields[Field.category] = .string(ItemCategory.receipt.rawValue) }
                fields.merge(await filing(kind: .email, category: isReceipt ? .receipt : nil, source: .email)) { _, b in b }
                await engine.set(fields, record: id, kind: "item")
                await engine.editText(Field.body, value: text, record: id, kind: "item")
                return id
            }
            // An attachment: add it to the email item of the same group if we have it.
            let blob = try await engine.storeBlob(envelope.body)
            let attachment = Attachment(id: blob, name: h.name ?? "attachment", mime: h.mime ?? "application/octet-stream", size: envelope.body.count)
            if let g = h.groupId, let parent = await items().first(where: { $0.record[Field.origin]?.object?["emailGroup"]?.string == g }) {
                await update(parent.id, [Field.attachments: .array((parent.attachments + [attachment]).map(\.json))])
                return parent.id
            }
            return try await addFile(envelope.body, name: attachment.name, mime: attachment.mime, source: .email, id: newItemId)

        default: // "web", "ios", "other": a page, selection, link or file sent from a browser / share sheet
            let source: ItemSource = h.source == "web" ? .web : .share
            let folder = h.folderPath
            if let urlString = h.url, let url = URL(string: urlString) {
                let note = String(decoding: envelope.body, as: UTF8.self)
                let (id, isNew) = await addLink(url, title: h.title ?? "", note: h.mime?.hasPrefix("text/") == true ? note : "", source: source,
                                                id: newItemId, folder: folder)
                if !isNew, !note.isEmpty, let item = await item(id) {
                    await setBody(id, item.body.isEmpty ? note : item.body + "\n\n" + note)
                }
                return await applyInboxHints(id, isNew: isNew, header: h)
            }
            if let mime = h.mime, !mime.hasPrefix("text/") {
                let id = try await addFile(envelope.body, name: h.name ?? "file", mime: mime, source: source, title: h.title, id: newItemId,
                                           folder: folder)
                return await applyInboxHints(id, isNew: true, header: h)
            }
            let id = await addNote(title: h.title ?? "", body: String(decoding: envelope.body, as: UTF8.self), source: source, id: newItemId,
                                   folder: folder)
            return await applyInboxHints(id, isNew: true, header: h)
        }
    }

    /// Bridges' hints (PROTOCOL.md §4 "Bridges"): an item filed into the folder the entry asked for
    /// stays there (later enrichment doesn't move it), gets the entry's tags, and remembers the bridge.
    /// Mirrors `applyInboxHints` in web/public/core/vault.js.
    func applyInboxHints(_ id: String, isNew: Bool, header h: InboxEnvelope.Header) async -> String {
        guard let item = await item(id) else { return id }
        var fields: [String: JSONValue] = [:]
        if isNew, !h.folderPath.isEmpty { fields[Field.folderAuto] = false }
        if isNew, InboxEnvelope.bridgeSources.contains(h.source) {
            var origin = item.record[Field.origin]?.object ?? [:]
            origin["bridge"] = .string(h.source)
            fields[Field.origin] = .object(origin)
        }
        let merged = Array(Set(item.tags + h.tagList)).sorted()
        if merged.count != item.tags.count { fields[Field.tags] = JSONValue(merged) }
        if !fields.isEmpty { await update(id, fields) }
        return id
    }

    /// The item id for an inbox entry (the same on every device).
    public static func inboxItemId(_ entryId: String) -> String { "inbox-" + entryId.lowercased() }

    // MARK: Sync passthrough

    @discardableResult
    public func sync() async -> SyncEngine.Report {
        let report = await engine.sync()
        await refreshIndex()
        return report
    }
}

/// A user-made collection record.
public struct ItemCollection: Identifiable, Hashable, Sendable {
    public let record: Record
    public init(_ record: Record) { self.record = record }
    public var id: String { record.id }
    public var name: String { record["name"]?.string ?? "Untitled" }
    public var symbol: String { record["symbol"]?.string ?? "folder" }
    public var color: String { record["color"]?.string ?? "blue" }
}

public struct PriceDrop: Hashable, Sendable {
    public var itemId: String
    public var title: String
    public var price: Double
    public var previous: Double
    public var currency: String?
}
