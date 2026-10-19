import Foundation

/// Structured data most sites embed as schema.org JSON-LD. No AI needed and very accurate:
/// recipes, products & prices, events, articles, places, videos.
public enum SchemaOrg {
    public struct Recipe: Equatable, Sendable {
        public var name: String
        public var ingredients: [String]
        public var steps: [String]
        public var totalTime: String?
        public var yield: String?
        public var image: String?
    }

    public struct Product: Equatable, Sendable {
        public var name: String
        public var price: Double?
        public var currency: String?
        public var brand: String?
        public var availability: String?
        public var image: String?
    }

    public struct Event: Equatable, Sendable {
        public var name: String
        public var startDate: String?
        public var endDate: String?
        public var venue: String?
        public var address: String?
    }

    public struct Article: Equatable, Sendable {
        public var headline: String
        public var author: String?
        public var published: String?
    }

    public struct Place: Equatable, Sendable {
        public var name: String
        public var address: String?
        public var latitude: Double?
        public var longitude: Double?
        public var telephone: String?
    }

    public struct Video: Equatable, Sendable {
        public var name: String
        public var duration: String?
        public var uploadDate: String?
    }

    public struct Result: Equatable, Sendable {
        public var recipe: Recipe?
        public var product: Product?
        public var event: Event?
        public var article: Article?
        public var place: Place?
        public var video: Video?
        public var types: [String] = []

        public var isEmpty: Bool { recipe == nil && product == nil && event == nil && article == nil && place == nil && video == nil }
    }

    public static func extract(jsonLD blocks: [String]) -> Result {
        var result = Result()
        for block in blocks {
            guard let data = HTMLMetadata.decodeEntities(block).trimmed.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) else { continue }
            for node in flatten(json) { absorb(node, into: &result) }
        }
        return result
    }

    static func flatten(_ json: Any) -> [[String: Any]] {
        if let array = json as? [Any] { return array.flatMap(flatten) }
        guard let object = json as? [String: Any] else { return [] }
        var out = [object]
        if let graph = object["@graph"] { out += flatten(graph) }
        if let main = object["mainEntity"] { out += flatten(main) }
        return out
    }

    static func types(_ node: [String: Any]) -> [String] {
        if let t = node["@type"] as? String { return [t] }
        return (node["@type"] as? [Any])?.compactMap { $0 as? String } ?? []
    }

    static func text(_ value: Any?) -> String? {
        switch value {
        case let s as String: return HTMLMetadata.decodeEntities(s).trimmed.nilIfEmpty
        case let n as NSNumber: return n.stringValue
        case let a as [Any]: return a.lazy.compactMap(text).first
        case let o as [String: Any]: return text(o["name"] ?? o["text"] ?? o["@value"] ?? o["url"])
        default: return nil
        }
    }

    static func number(_ value: Any?) -> Double? {
        switch value {
        case let n as NSNumber: return n.doubleValue
        case let s as String: return Double(s.replacingOccurrences(of: ",", with: "").trimmed)
        case let a as [Any]: return a.lazy.compactMap(number).first
        default: return nil
        }
    }

    static func strings(_ value: Any?) -> [String] {
        if let a = value as? [Any] { return a.compactMap(text) }
        return text(value).map { [$0] } ?? []
    }

    static func image(_ value: Any?) -> String? {
        if let o = value as? [String: Any] { return text(o["url"]) }
        if let a = value as? [Any] { return a.lazy.compactMap(image).first }
        return text(value)
    }

    static func address(_ value: Any?) -> String? {
        if let s = value as? String { return s }
        guard let o = value as? [String: Any] else { return text(value) }
        let parts = ["streetAddress", "addressLocality", "postalCode", "addressRegion", "addressCountry"].compactMap { text(o[$0]) }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    static func steps(_ value: Any?) -> [String] {
        if let s = value as? String {
            return s.components(separatedBy: CharacterSet.newlines).map(\.trimmed).filter { !$0.isEmpty }
        }
        guard let a = value as? [Any] else { return [] }
        return a.flatMap { item -> [String] in
            if let o = item as? [String: Any] {
                if types(o).contains("HowToSection") { return steps(o["itemListElement"]) }
                return text(o["text"] ?? o["name"]).map { [$0] } ?? []
            }
            return text(item).map { [$0] } ?? []
        }
    }

    static func absorb(_ node: [String: Any], into result: inout Result) {
        let t = types(node)
        result.types += t.filter { !result.types.contains($0) }
        let set = Set(t)
        let name = text(node["name"] ?? node["headline"]) ?? ""

        if set.contains("Recipe"), result.recipe == nil {
            result.recipe = Recipe(name: name, ingredients: strings(node["recipeIngredient"] ?? node["ingredients"]),
                                   steps: steps(node["recipeInstructions"]), totalTime: text(node["totalTime"]),
                                   yield: text(node["recipeYield"]), image: image(node["image"]))
        }
        if set.contains("Product"), result.product == nil {
            let offers = (node["offers"] as? [String: Any]) ?? (node["offers"] as? [Any])?.first as? [String: Any]
            let offer = (offers?["offers"] as? [Any])?.first as? [String: Any] ?? offers
            result.product = Product(name: name, price: number(offer?["price"] ?? offer?["lowPrice"]),
                                     currency: text(offer?["priceCurrency"]), brand: text(node["brand"]),
                                     availability: text(offer?["availability"]).map { $0.components(separatedBy: "/").last ?? $0 },
                                     image: image(node["image"]))
        }
        if !set.isDisjoint(with: ["Event", "MusicEvent", "SportsEvent", "TheaterEvent", "ScreeningEvent", "Festival"]), result.event == nil {
            let location = node["location"] as? [String: Any]
            result.event = Event(name: name, startDate: text(node["startDate"]), endDate: text(node["endDate"]),
                                 venue: text(location?["name"]), address: address(location?["address"]))
        }
        if !set.isDisjoint(with: ["Article", "NewsArticle", "BlogPosting", "TechArticle", "Report", "ScholarlyArticle"]), result.article == nil {
            result.article = Article(headline: name, author: text(node["author"]), published: text(node["datePublished"]))
        }
        if !set.isDisjoint(with: ["Place", "LocalBusiness", "Restaurant", "CafeOrCoffeeShop", "BarOrPub", "Hotel", "Museum",
                                  "TouristAttraction", "Store", "FoodEstablishment", "Bakery", "Park"]), result.place == nil {
            let geo = node["geo"] as? [String: Any]
            result.place = Place(name: name, address: address(node["address"]), latitude: number(geo?["latitude"]),
                                 longitude: number(geo?["longitude"]), telephone: text(node["telephone"]))
        }
        if set.contains("VideoObject"), result.video == nil {
            result.video = Video(name: name, duration: text(node["duration"]), uploadDate: text(node["uploadDate"]))
        }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
