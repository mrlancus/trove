import Foundation

/// What every device works out about a copy as soon as it's made (PROTOCOL.md §8): a title, counts,
/// and the links, emails, phone numbers, colours and hashtags in it. Deterministic, so the website
/// (web/public/core/clips.js `insights`) gets the same; both check Fixtures/clip-cases.json.
/// AI titles, summaries and tags come later from enrichment (`aiTitle`, `summary`, `tags`).
public struct ClipInsights: Equatable, Sendable {
    public var autoTitle: String
    public var chars: Int
    public var words: Int
    public var lines: Int
    public var links: [String]
    public var emails: [String]
    public var phones: [String]
    public var colors: [String]
    public var hashtags: [String]

    static let maxEntities = 20
    static let titleLength = 60

    public static func of(_ text: String, kind: ClipKind? = nil) -> ClipInsights {
        let kind = kind ?? ClipClassifier.classify(text)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = text.split(whereSeparator: { $0.isWhitespace }).count
        return ClipInsights(
            autoTitle: title(trimmed, kind: kind),
            chars: text.unicodeScalars.count,
            words: words,
            lines: text.isEmpty ? 0 : text.split(separator: "\n", omittingEmptySubsequences: false).count,
            links: unique(matches(#"https?://[^\s<>"'`]+"#, in: text).map(trimPunctuation)),
            emails: unique(matches(#"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, in: text)),
            phones: unique(matches(#"\+?[0-9][0-9 ()\-.]{6,}[0-9]"#, in: text).filter { $0.filter(\.isNumber).count >= 7 && $0.filter(\.isNumber).count <= 15 }),
            colors: unique(matches(#"#(?:[0-9a-fA-F]{6}|[0-9a-fA-F]{3})(?![0-9a-zA-Z])"#, in: text).map { $0.lowercased() }),
            hashtags: unique(Markdown.hashtags(in: text).filter { !isHexColour($0) }))
    }

    /// The built-in rules' tags, for devices without AI: the kind, the site a link is on, the
    /// language of code, `contact` for text with an email or phone number, and the text's hashtags.
    public static func ruleTags(_ text: String, kind: ClipKind? = nil) -> [String] {
        let kind = kind ?? ClipClassifier.classify(text)
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var tags: [String] = []
        switch kind {
        case .link:
            tags.append("link")
            if let site = URL(string: s)?.host.flatMap(siteName) { tags.append(site) }
        case .email: tags.append("email")
        case .phone: tags.append("phone")
        case .color: tags.append("colour")
        case .json: tags.append("json")
        case .path: tags.append("path")
        case .code:
            tags.append("code")
            if let language = language(of: text) { tags.append(language) }
        default: break
        }
        let found = of(text, kind: kind)
        if kind == .text, !found.emails.isEmpty || !found.phones.isEmpty { tags.append("contact") }
        return Array(unique(tags + found.hashtags).prefix(8))
    }

    /// "github" for github.com, "bbc" for www.bbc.co.uk.
    static func siteName(_ host: String) -> String? {
        let labels = host.lowercased().split(separator: ".").map(String.init)
        guard labels.count >= 2 else { return nil }
        let n = labels.count
        let second = ["co", "com", "org", "net", "gov", "ac", "edu"]
        if n >= 3, labels[n - 1].count == 2, second.contains(labels[n - 2]) { return labels[n - 3] }
        return labels[n - 2]
    }

    static func language(of code: String) -> String? {
        let has = { (s: String) in code.contains(s) }
        if has("#include") { return "c" }
        if has("fn ") && has("let mut") { return "rust" }
        if has("func ") && (has("let ") || has("var ") || has("->")) { return "swift" }
        if has("def ") || (has("import ") && has("print(")) { return "python" }
        if has("SELECT ") && has(" FROM ") { return "sql" }
        if has("</") || has("/>") { return "html" }
        if has("const ") || has("=>") || has("console.") || has("function ") { return "javascript" }
        return nil
    }

    /// A colour like #ff8800 isn't a hashtag.
    static func isHexColour(_ tag: String) -> Bool {
        (tag.count == 3 || tag.count == 6) && tag.allSatisfy { "0123456789abcdef".contains($0) }
    }

    /// A short name for the list: the link's address, a colour, the first line…
    static func title(_ s: String, kind: ClipKind) -> String {
        switch kind {
        case .link:
            guard let url = URL(string: s), let host = url.host else { return clip(s) }
            let h = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            let path = url.path == "/" ? "" : url.path
            return clip(h + path)
        case .color: return "Colour " + s
        case .path: return (s as NSString).lastPathComponent.isEmpty ? s : (s as NSString).lastPathComponent
        case .json: return "JSON"
        default:
            let line = s.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
            return clip(line.split(whereSeparator: { $0.isWhitespace }).joined(separator: " "))
        }
    }

    /// At most `titleLength` characters, cut at a word when there's one near the end.
    static func clip(_ s: String) -> String {
        let scalars = Array(s.unicodeScalars)
        guard scalars.count > titleLength else { return s }
        var cut = String(String.UnicodeScalarView(scalars.prefix(titleLength)))
        if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) > titleLength / 2 { cut = String(cut[..<space]) }
        return cut.trimmingCharacters(in: .whitespaces) + "…"
    }

    static func matches(_ pattern: String, in text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        return re.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range, in: text).map { String(text[$0]) } }
    }

    static func trimPunctuation(_ s: String) -> String {
        var s = s
        while let last = s.last, ".,;:!?)]}".contains(last) { s.removeLast() }
        return s
    }

    static func unique(_ list: [String]) -> [String] {
        var seen: Set<String> = []
        return Array(list.filter { seen.insert($0).inserted }.prefix(maxEntities))
    }

    /// As record fields.
    public var json: [String: JSONValue] {
        [Clip.Field.autoTitle: .string(autoTitle),
         Clip.Field.stats: ["chars": .number(Double(chars)), "words": .number(Double(words)), "lines": .number(Double(lines))],
         Clip.Field.entities: ["links": JSONValue(links), "emails": JSONValue(emails), "phones": JSONValue(phones),
                               "colors": JSONValue(colors), "hashtags": JSONValue(hashtags)]]
    }
}
