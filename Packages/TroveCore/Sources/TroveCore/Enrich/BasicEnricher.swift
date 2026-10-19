import Foundation

/// Tier 0 enrichment for links: everything we can learn from the page itself, on any device.
/// Apple-only extras (OCR, NSDataDetector, NLTagger, Foundation Models) live in the app target and
/// add to this result.
public struct LinkEnrichment: Sendable, Equatable {
    public var title: String?
    public var summary: String?
    public var siteName: String?
    public var imageURL: String?
    public var author: String?
    public var category: ItemCategory
    public var tags: [String]
    public var extracted: [String: JSONValue]
    public var readableText: String

    /// Fields to write onto the item record (never overwrites a user-set title).
    public func fields(existingTitle: String?) -> [String: JSONValue] {
        var f: [String: JSONValue] = [Field.category: .string(category.rawValue)]
        if (existingTitle ?? "").isEmpty, let title { f[Field.title] = .string(title) }
        if let summary { f[Field.summary] = .string(summary) }
        if let siteName { f[Field.siteName] = .string(siteName) }
        if let imageURL { f[Field.imageURL] = .string(imageURL) }
        if let author { f[Field.author] = .string(author) }
        if !tags.isEmpty { f[Field.tags] = JSONValue(tags) }
        if !extracted.isEmpty { f[Field.extracted] = .object(extracted) }
        return f
    }
}

public enum BasicEnricher {
    public static func enrich(html: String, url: URL) -> LinkEnrichment {
        let meta = HTMLMetadata(html: html, baseURL: url)
        let schema = SchemaOrg.extract(jsonLD: meta.jsonLD)
        var extracted: [String: JSONValue] = [:]

        if let r = schema.recipe {
            extracted["recipe"] = [
                "name": .string(r.name), "ingredients": JSONValue(r.ingredients), "steps": JSONValue(r.steps),
                "totalTime": r.totalTime.map(JSONValue.string) ?? .null, "yield": r.yield.map(JSONValue.string) ?? .null,
            ]
        }
        if let p = schema.product {
            extracted["product"] = [
                "name": .string(p.name), "price": p.price.map(JSONValue.number) ?? .null,
                "currency": p.currency.map(JSONValue.string) ?? .null, "brand": p.brand.map(JSONValue.string) ?? .null,
                "availability": p.availability.map(JSONValue.string) ?? .null,
            ]
        }
        if let e = schema.event {
            extracted["event"] = [
                "name": .string(e.name), "startDate": e.startDate.map(JSONValue.string) ?? .null,
                "endDate": e.endDate.map(JSONValue.string) ?? .null, "venue": e.venue.map(JSONValue.string) ?? .null,
                "address": e.address.map(JSONValue.string) ?? .null,
            ]
        }
        if let pl = schema.place {
            extracted["place"] = [
                "name": .string(pl.name), "address": pl.address.map(JSONValue.string) ?? .null,
                "lat": pl.latitude.map(JSONValue.number) ?? .null, "lon": pl.longitude.map(JSONValue.number) ?? .null,
                "telephone": pl.telephone.map(JSONValue.string) ?? .null,
            ]
        }

        let category = AutoTagger.category(url: url, schema: schema, text: meta.readableText)
        let summary = meta.description ?? firstSentences(meta.readableText, maxLength: 240)
        return LinkEnrichment(
            title: schema.recipe?.name.nilIfEmpty ?? schema.product?.name.nilIfEmpty ?? meta.title,
            summary: summary,
            siteName: meta.siteName ?? url.host?.replacingOccurrences(of: "www.", with: ""),
            imageURL: meta.imageURL ?? schema.recipe?.image ?? schema.product?.image,
            author: schema.article?.author ?? meta.author,
            category: category,
            tags: AutoTagger.tags(url: url, category: category, schema: schema),
            extracted: extracted,
            readableText: meta.readableText
        )
    }

    /// A short summary without AI: the opening sentences, cut on a word boundary.
    public static func firstSentences(_ text: String, maxLength: Int) -> String? {
        let flat = text.replacingOccurrences(of: "\n", with: " ").trimmed
        guard flat.count > 40 else { return flat.nilIfEmpty }
        if flat.count <= maxLength { return flat }
        let cut = flat.prefix(maxLength)
        if let end = cut.lastIndex(where: { ".!?".contains($0) }), cut.distance(from: cut.startIndex, to: end) > maxLength / 3 {
            return String(cut[...end])
        }
        if let space = cut.lastIndex(of: " ") { return String(cut[..<space]) + "…" }
        return String(cut) + "…"
    }
}
