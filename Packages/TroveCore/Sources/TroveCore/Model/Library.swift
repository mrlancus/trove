import Foundation

/// The app-facing API: add, edit, import, search. Wraps `SyncEngine` (state + sync) and keeps the
/// local `SearchIndex` in step. UI code wraps this in an @Observable model on the main actor.
public actor Library {
    public let engine: SyncEngine
    private var index = SearchIndex()
    private var indexed: [String: String] = [:]   // record id → updatedHLC already indexed
    private let now: @Sendable () -> Date

    public init(engine: SyncEngine, now: @escaping @Sendable () -> Date = { Date() }) {
        self.engine = engine
        self.now = now
    }

    // MARK: Reading

    public func items() async -> [Item] {
        await refreshIndex()
        return await engine.records.filter { $0.kind == "item" }.map(Item.init).sorted { $0.createdAt > $1.createdAt }
    }

    public func item(_ id: String) async -> Item? {
        guard let r = await engine.record(id), r.kind == "item", !r.isDeleted else { return nil }
        return Item(r)
    }

    public func search(_ text: String, semantic: [String: Double] = [:], limit: Int = 100) async -> [Item] {
        await refreshIndex()
        return index.search(.parse(text), semantic: semantic, limit: limit).map(\.item)
    }

    public func items(in smart: SmartCollection) async -> [Item] {
        await items().filter(smart.contains)
    }

    public func collections() async -> [ItemCollection] {
        await engine.records.filter { $0.kind == "collection" }.map(ItemCollection.init).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
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
        let records = await engine.store.records
        for (id, record) in records where record.kind == "item" {
            if indexed[id] != record.updatedHLC {
                index.update(Item(record))
                indexed[id] = record.updatedHLC
            }
        }
    }

    // MARK: Adding

    private func newId() -> String { UUID().uuidString.lowercased() }

    private func baseFields(kind: ItemKind, source: ItemSource, title: String, createdAt: Date? = nil) async -> [String: JSONValue] {
        [
            Field.kind: .string(kind.rawValue), Field.source: .string(source.rawValue), Field.title: .string(title),
            Field.createdAt: JSONValue(createdAt ?? now()), Field.capturedOn: .string(await engine.device),
            Field.needsEnrichment: true,
        ]
    }

    @discardableResult
    public func addNote(title: String = "", body: String, tags: [String] = [], source: ItemSource = .app) async -> String {
        let id = newId()
        var fields = await baseFields(kind: .note, source: source, title: title)
        fields[Field.category] = .string(ItemCategory.note.rawValue)
        let allTags = Array(Set(tags.map { $0.lowercased() } + Markdown.hashtags(in: body))).sorted()
        if !allTags.isEmpty { fields[Field.tags] = JSONValue(allTags) }
        await engine.set(fields, record: id, kind: "item")
        if !body.isEmpty { await engine.editText(Field.body, value: body, record: id, kind: "item") }
        return id
    }

    /// Adds a link, or returns the existing item if the same page was saved before.
    @discardableResult
    public func addLink(_ url: URL, title: String = "", note: String = "", source: ItemSource = .app) async -> (id: String, isNew: Bool) {
        let cleaned = URLCleaner.clean(url)
        let key = URLCleaner.dedupeKey(cleaned)
        if let existing = await items().first(where: { $0.url.map(URLCleaner.dedupeKey) == key }) {
            return (existing.id, false)
        }
        let id = newId()
        var fields = await baseFields(kind: .link, source: source, title: title)
        fields[Field.url] = .string(cleaned.absoluteString)
        await engine.set(fields, record: id, kind: "item")
        if !note.isEmpty { await engine.editText(Field.body, value: note, record: id, kind: "item") }
        return (id, true)
    }

    /// Stores the bytes (encrypted) and creates an item for them.
    @discardableResult
    public func addFile(_ data: Data, name: String, mime: String, kind: ItemKind? = nil, source: ItemSource = .app,
                        title: String? = nil, createdAt: Date? = nil) async throws -> String {
        let blob = try await engine.storeBlob(data)
        let id = newId()
        let resolvedKind = kind ?? Self.kind(forMime: mime)
        var fields = await baseFields(kind: resolvedKind, source: source, title: title ?? Self.titleFromFileName(name), createdAt: createdAt)
        fields[Field.attachments] = [Attachment(id: blob, name: name, mime: mime, size: data.count).json]
        await engine.set(fields, record: id, kind: "item")
        return id
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

    public func update(_ id: String, _ fields: [String: JSONValue]) async {
        await engine.set(fields, record: id, kind: "item")
    }

    public func setBody(_ id: String, _ text: String) async {
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
    @discardableResult
    public func importInbox(_ envelope: InboxEnvelope) async throws -> String {
        let h = envelope.header
        switch h.source {
        case "webdav":
            let path = h.meta?["davPath"]?.string ?? h.name ?? "notebook.pdf"
            let blob = try await engine.storeBlob(envelope.body)
            let attachment = Attachment(id: blob, name: h.name ?? "notebook.pdf", mime: h.mime ?? "application/pdf", size: envelope.body.count)
            if let existing = await items().first(where: { $0.record[Field.origin]?.object?["davPath"]?.string == path }) {
                await update(existing.id, [Field.attachments: [attachment.json], Field.needsEnrichment: true, Field.ocrText: .null, Field.enrichment: .null])
                return existing.id
            }
            let id = newId()
            var fields = await baseFields(kind: .pdf, source: .goodnotes, title: Self.titleFromFileName(h.name ?? "Notebook"))
            fields[Field.attachments] = [attachment.json]
            fields[Field.origin] = ["davPath": .string(path)]
            await engine.set(fields, record: id, kind: "item")
            return id

        case "email":
            if let mime = h.mime, mime == "text/html" || mime == "text/plain" {
                let raw = String(decoding: envelope.body, as: UTF8.self)
                let text = mime == "text/html" ? HTMLMetadata(html: raw).readableText : raw
                let id = newId()
                var fields = await baseFields(kind: .email, source: .email, title: h.title ?? "Email")
                var origin: [String: JSONValue] = [:]
                if let g = h.groupId { origin["emailGroup"] = .string(g) }
                if let from = h.meta?["from"] { origin["from"] = from }
                fields[Field.origin] = .object(origin)
                if AutoTagger.category(url: nil, schema: .init(), text: text) == .receipt { fields[Field.category] = .string(ItemCategory.receipt.rawValue) }
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
            return try await addFile(envelope.body, name: attachment.name, mime: attachment.mime, source: .email)

        default: // "web", "ios", "other": a page, selection, link or file sent from a browser / share sheet
            let source: ItemSource = h.source == "web" ? .web : .share
            if let urlString = h.url, let url = URL(string: urlString) {
                let note = String(decoding: envelope.body, as: UTF8.self)
                let (id, isNew) = await addLink(url, title: h.title ?? "", note: h.mime?.hasPrefix("text/") == true ? note : "", source: source)
                if !isNew, !note.isEmpty, let item = await item(id) {
                    await setBody(id, item.body.isEmpty ? note : item.body + "\n\n" + note)
                }
                return id
            }
            if let mime = h.mime, !mime.hasPrefix("text/") {
                return try await addFile(envelope.body, name: h.name ?? "file", mime: mime, source: source, title: h.title)
            }
            return await addNote(title: h.title ?? "", body: String(decoding: envelope.body, as: UTF8.self), source: source)
        }
    }

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
