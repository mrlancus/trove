import Foundation

/// What an item physically is.
public enum ItemKind: String, Codable, CaseIterable, Sendable {
    case note, link, image, pdf, audio, video, file, highlight, email
}

/// What an item is *about*: drives Smart Collections and card styles.
public enum ItemCategory: String, Codable, CaseIterable, Sendable {
    case article, recipe, product, place, event, video, note, receipt, quote, idea, code, other
}

/// Where an item came from.
public enum ItemSource: String, Codable, Sendable {
    case app, share, web, email, goodnotes, kindle, readwise, obsidian, appleNotes, notion, screenshot, voice, scan, `import`
}

public struct Attachment: Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var mime: String
    public var size: Int
    public init(id: String, name: String, mime: String, size: Int) {
        self.id = id; self.name = name; self.mime = mime; self.size = size
    }
}

/// Who/what produced the derived fields (summary, tags…), so a weaker device never overwrites a
/// stronger device's results and the UI can badge cloud processing (RESEARCH.md §3).
public struct Enrichment: Codable, Hashable, Sendable {
    public enum Tier: Int, Codable, Comparable, Sendable {
        case basic = 0, onDevice = 1, helper = 2, cloud = 3
        public static func < (a: Tier, b: Tier) -> Bool { a.rawValue < b.rawValue }
    }
    public var tier: Tier
    public var by: String       // device id or model id
    public var at: Date
    public init(tier: Tier, by: String, at: Date = Date()) { self.tier = tier; self.by = by; self.at = at }
}

/// Field names on item records. Text fields (merged with diff3) are listed separately.
public enum Field {
    public static let title = "title", url = "url", summary = "summary", tags = "tags", category = "category"
    public static let source = "source", createdAt = "createdAt", capturedOn = "capturedOn", attachments = "attachments"
    public static let extracted = "extracted", collections = "collections", space = "space", pinned = "pinned"
    public static let readAt = "readAt", enrichment = "enrichment", needsEnrichment = "needsEnrichment"
    public static let origin = "origin" // e.g. {"obsidianPath": "...", "appleNotesId": "..."}
    public static let ocrText = "ocrText", siteName = "siteName", imageURL = "imageURL", author = "author"
    public static let location = "location" // {"lat","lon","name","address"}
    public static let resolvedConflicts = "resolvedConflicts"
    public static let priceWatch = "priceWatch" // {"url","price","lowest","currency","checkedAt","droppedAt","previous"}
    public static let published = "published"   // {"slug","url"}
    public static let folder = "folder"         // folder record id (PROTOCOL.md §9)
    public static let folderAuto = "folderAuto" // true while the organiser chose the folder (the user hasn't moved it)
    public static let links = "links"           // ids of items this one is connected to by hand
    public static let fileVersions = "fileVersions" // earlier attachments, newest first: [{attachment, at, by}]
    public static let thumbnail = "thumbnail"   // a small JPEG preview (attachment JSON)
    // text fields
    public static let body = "body"
}

/// Typed, read-only view of an item record.
public struct Item: Identifiable, Hashable, Sendable {
    public let record: Record
    public init(_ record: Record) { self.record = record }

    public var id: String { record.id }
    public var kind: ItemKind { ItemKind(rawValue: record[Field.kind]?.string ?? "") ?? ItemKind(rawValue: record.kind) ?? .note }
    public var title: String { record[Field.title]?.string ?? "" }
    public var displayTitle: String {
        if !title.isEmpty { return title }
        if let firstLine = body.split(separator: "\n").first, !firstLine.isEmpty { return String(firstLine.prefix(80)) }
        if let url { return url.host ?? url.absoluteString }
        return "Untitled"
    }
    public var url: URL? { record[Field.url]?.string.flatMap(URL.init(string:)) }
    public var body: String { record.texts[Field.body] ?? "" }
    public var summary: String? { record[Field.summary]?.string }
    public var tags: [String] { record[Field.tags]?.stringArray ?? [] }
    public var category: ItemCategory { ItemCategory(rawValue: record[Field.category]?.string ?? "") ?? .other }
    public var source: ItemSource { ItemSource(rawValue: record[Field.source]?.string ?? "") ?? .app }
    public var createdAt: Date { record[Field.createdAt]?.date ?? Date(timeIntervalSince1970: 0) }
    public var collections: [String] { record[Field.collections]?.stringArray ?? [] }
    public var space: String? { record[Field.space]?.string }
    public var folder: String? { record[Field.folder]?.string }
    public var isAutoFiled: Bool { record[Field.folderAuto]?.bool ?? false }
    /// Items this one was connected to by hand (wikilinks in the body are found by `Links`).
    public var links: [String] { record[Field.links]?.stringArray ?? [] }
    public var thumbnail: Attachment? { record[Field.thumbnail].flatMap(Attachment.init(json:)) }
    /// Earlier versions of the file, newest first.
    public var fileVersions: [FileVersion] {
        (record[Field.fileVersions]?.array ?? []).compactMap { v in
            guard let o = v.object, let a = o["attachment"].flatMap(Attachment.init(json:)) else { return nil }
            return FileVersion(attachment: a, at: o["at"]?.date ?? Date(timeIntervalSince1970: 0), by: o["by"]?.string)
        }
    }
    public var isPinned: Bool { record[Field.pinned]?.bool ?? false }
    public var readAt: Date? { record[Field.readAt]?.date }
    public var ocrText: String? { record[Field.ocrText]?.string }
    public var siteName: String? { record[Field.siteName]?.string }
    public var needsEnrichment: Bool { record[Field.needsEnrichment]?.bool ?? false }
    /// Unresolved versions of the body that couldn't be merged automatically.
    public var conflictingVersions: [String] {
        Array((record.conflicts[Field.body] ?? []).dropFirst(Int(record[Field.resolvedConflicts]?.number ?? 0)))
    }
    public var hasConflicts: Bool { !conflictingVersions.isEmpty }
    public var extracted: [String: JSONValue] { record[Field.extracted]?.object ?? [:] }

    /// Set while "Track price drops" is on for this item.
    public var priceWatch: PriceWatch? {
        guard let o = record[Field.priceWatch]?.object, let url = o["url"]?.string else { return nil }
        return PriceWatch(url: url, price: o["price"]?.number, previous: o["previous"]?.number, lowest: o["lowest"]?.number,
                          currency: o["currency"]?.string, checkedAt: o["checkedAt"]?.date, droppedAt: o["droppedAt"]?.date)
    }

    /// The public link, if this note has been published.
    public var published: PublishedLink? {
        guard let o = record[Field.published]?.object, let slug = o["slug"]?.string,
              let url = o["url"]?.string.flatMap(URL.init(string:)) else { return nil }
        return PublishedLink(slug: slug, url: url)
    }

    /// The URL to watch for price drops: a product item's link.
    public var watchableURL: URL? {
        guard let url, url.scheme == "https" || url.scheme == "http" else { return nil }
        return category == .product || extracted["product"] != nil ? url : nil
    }

    public var attachments: [Attachment] {
        (record[Field.attachments]?.array ?? []).compactMap(Attachment.init(json:))
    }

    public var enrichment: Enrichment? {
        guard let o = record[Field.enrichment]?.object, let t = o["tier"]?.number, let by = o["by"]?.string else { return nil }
        return Enrichment(tier: .init(rawValue: Int(t)) ?? .basic, by: by, at: o["at"]?.date ?? Date(timeIntervalSince1970: 0))
    }

    /// Everything searchable, in one string.
    public var searchableText: String {
        ([title, body, summary ?? "", ocrText ?? "", url?.absoluteString ?? "", siteName ?? ""] + tags).joined(separator: "\n")
    }
}

extension Field { public static let kind = "kind" }

public struct PriceWatch: Hashable, Sendable {
    public var url: String
    public var price: Double?
    public var previous: Double?
    public var lowest: Double?
    public var currency: String?
    public var checkedAt: Date?
    public var droppedAt: Date?

    public init(url: String, price: Double? = nil, previous: Double? = nil, lowest: Double? = nil, currency: String? = nil,
                checkedAt: Date? = nil, droppedAt: Date? = nil) {
        self.url = url
        self.price = price
        self.previous = previous
        self.lowest = lowest
        self.currency = currency
        self.checkedAt = checkedAt
        self.droppedAt = droppedAt
    }
}

public struct PublishedLink: Hashable, Sendable {
    public var slug: String
    public var url: URL

    public init(slug: String, url: URL) {
        self.slug = slug
        self.url = url
    }
}

/// A file as it was before an edit or a newer backup replaced it.
public struct FileVersion: Hashable, Sendable {
    public var attachment: Attachment
    public var at: Date
    /// The device that replaced it.
    public var by: String?
    public var json: JSONValue {
        var o: [String: JSONValue] = ["attachment": attachment.json, "at": JSONValue(at)]
        if let by { o["by"] = .string(by) }
        return .object(o)
    }
}

extension Attachment {
    public init?(json: JSONValue) {
        guard let o = json.object, let id = o["id"]?.string else { return nil }
        self.init(id: id, name: o["name"]?.string ?? "file", mime: o["mime"]?.string ?? "application/octet-stream", size: Int(o["size"]?.number ?? 0))
    }

    public var json: JSONValue { ["id": .string(id), "name": .string(name), "mime": .string(mime), "size": .number(Double(size))] }
}

extension Enrichment {
    public var json: JSONValue { ["tier": .number(Double(tier.rawValue)), "by": .string(by), "at": JSONValue(at)] }
}
