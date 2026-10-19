import Foundation

/// Rule-based categories and tags (Tier 0). AI tiers may refine these later.
public enum AutoTagger {
    static let videoHosts = ["youtube.com", "youtu.be", "vimeo.com", "tiktok.com", "twitch.tv", "dailymotion.com"]
    static let shopHosts = ["amazon.", "ebay.", "etsy.com", "aliexpress.", "argos.co.uk", "johnlewis.com", "bestbuy.com", "ikea.com", "asos.com", "zara.com", "apple.com/shop"]
    static let mapHosts = ["maps.apple.com", "maps.google.", "google.com/maps", "goo.gl/maps", "openstreetmap.org", "tripadvisor.", "yelp.com"]
    static let codeHosts = ["github.com", "gitlab.com", "stackoverflow.com", "developer.apple.com", "npmjs.com", "pypi.org"]
    static let socialHosts = ["twitter.com", "x.com", "threads.net", "bsky.app", "mastodon.", "instagram.com", "reddit.com", "linkedin.com"]

    static func matches(_ url: URL, _ hosts: [String]) -> Bool {
        let s = (url.host ?? "") + url.path
        return hosts.contains { s.contains($0) }
    }

    public static func category(url: URL?, schema: SchemaOrg.Result, text: String = "") -> ItemCategory {
        if schema.recipe != nil { return .recipe }
        if schema.product != nil { return .product }
        if schema.event != nil { return .event }
        if schema.place != nil { return .place }
        if schema.video != nil { return .video }
        if let url {
            if matches(url, videoHosts) { return .video }
            if matches(url, mapHosts) { return .place }
            if matches(url, shopHosts) { return .product }
            if matches(url, codeHosts) { return .code }
        }
        if schema.article != nil { return .article }
        let lower = text.lowercased()
        if lower.contains("order number") || lower.contains("receipt") && (lower.contains("total") || lower.contains("vat")) { return .receipt }
        return url == nil ? .note : .article
    }

    public static func tags(url: URL?, category: ItemCategory, schema: SchemaOrg.Result) -> [String] {
        var tags: [String] = []
        if let url, matches(url, socialHosts) { tags.append("social") }
        if let url, matches(url, codeHosts) { tags.append("code") }
        if let r = schema.recipe, r.ingredients.count > 0, r.ingredients.count <= 6 { tags.append("quick") }
        if category == .product, schema.product?.price != nil { tags.append("price-tracked") }
        return tags
    }
}
