import Foundation

/// Pulls title, description, preview image, JSON-LD and readable text out of raw HTML, with no
/// HTML parser dependency (Tier 0: works on every device, and on Linux).
public struct HTMLMetadata: Sendable, Equatable {
    public var title: String?
    public var description: String?
    public var imageURL: String?
    public var siteName: String?
    public var canonicalURL: String?
    public var author: String?
    public var published: String?
    public var jsonLD: [String] = []
    public var readableText: String = ""

    public init(html: String, baseURL: URL? = nil) {
        let metas = Self.metaTags(html)
        func meta(_ keys: String...) -> String? {
            for k in keys { if let v = metas[k], !v.isEmpty { return v } }
            return nil
        }
        title = meta("og:title", "twitter:title") ?? Self.firstMatch(#"<title[^>]*>([\s\S]*?)</title>"#, in: html).map(Self.decodeEntities)?.trimmed
        description = meta("og:description", "description", "twitter:description")
        imageURL = meta("og:image", "og:image:url", "twitter:image").map { Self.resolve($0, baseURL) }
        siteName = meta("og:site_name", "application-name")
        author = meta("author", "article:author")
        published = meta("article:published_time", "datePublished")
        canonicalURL = Self.linkHref(html, rel: "canonical").map { Self.resolve($0, baseURL) } ?? meta("og:url")
        jsonLD = Self.allMatches(#"<script[^>]+type=["']application/ld\+json["'][^>]*>([\s\S]*?)</script>"#, in: html)
        readableText = Self.readableText(html)
    }

    // MARK: Helpers

    static func metaTags(_ html: String) -> [String: String] {
        var out: [String: String] = [:]
        for tag in allMatches(#"(<meta\b[^>]*>)"#, in: html) {
            let attrs = attributes(tag)
            guard let content = attrs["content"] else { continue }
            if let key = (attrs["property"] ?? attrs["name"] ?? attrs["itemprop"])?.lowercased(), out[key] == nil {
                out[key] = decodeEntities(content).trimmed
            }
        }
        return out
    }

    static func linkHref(_ html: String, rel: String) -> String? {
        for tag in allMatches(#"(<link\b[^>]*>)"#, in: html) {
            let attrs = attributes(tag)
            if attrs["rel"]?.lowercased().split(separator: " ").contains(Substring(rel)) == true { return attrs["href"] }
        }
        return nil
    }

    static func attributes(_ tag: String) -> [String: String] {
        var out: [String: String] = [:]
        let regex = try! NSRegularExpression(pattern: #"([a-zA-Z_:][-a-zA-Z0-9_:.]*)\s*=\s*("([^"]*)"|'([^']*)'|([^\s>]+))"#)
        let ns = tag as NSString
        for m in regex.matches(in: tag, range: NSRange(location: 0, length: ns.length)) {
            let name = ns.substring(with: m.range(at: 1)).lowercased()
            let value = [3, 4, 5].compactMap { m.range(at: $0).location != NSNotFound ? ns.substring(with: m.range(at: $0)) : nil }.first ?? ""
            out[name] = value
        }
        return out
    }

    static func resolve(_ href: String, _ base: URL?) -> String {
        guard let base, let url = URL(string: href, relativeTo: base) else { return href }
        return url.absoluteString
    }

    static func firstMatch(_ pattern: String, in text: String) -> String? { allMatches(pattern, in: text).first }

    static func allMatches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap {
            $0.numberOfRanges > 1 && $0.range(at: 1).location != NSNotFound ? ns.substring(with: $0.range(at: 1)) : nil
        }
    }

    /// Main text of the page: prefers <article>/<main>, drops scripts, styles and page chrome.
    static func readableText(_ html: String) -> String {
        var body = firstMatch(#"<article\b[^>]*>([\s\S]*?)</article>"#, in: html)
            ?? firstMatch(#"<main\b[^>]*>([\s\S]*?)</main>"#, in: html)
            ?? firstMatch(#"<body\b[^>]*>([\s\S]*?)</body>"#, in: html)
            ?? html
        for tag in ["script", "style", "noscript", "svg", "nav", "footer", "header", "aside", "form", "iframe", "template"] {
            body = body.replacingOccurrences(of: "<\(tag)\\b[\\s\\S]*?</\(tag)>", with: " ", options: [.regularExpression, .caseInsensitive])
        }
        body = body.replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: " ", options: .regularExpression)
        body = body.replacingOccurrences(of: "<(br|/p|/div|/li|/h[1-6]|/tr|/blockquote)\\b[^>]*>", with: "\n", options: [.regularExpression, .caseInsensitive])
        body = body.replacingOccurrences(of: "<li\\b[^>]*>", with: "• ", options: [.regularExpression, .caseInsensitive])
        body = body.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        body = decodeEntities(body)
        let lines = body.components(separatedBy: "\n")
            .map { $0.replacingOccurrences(of: "[ \\t\\x{00A0}]+", with: " ", options: .regularExpression).trimmed }
            .filter { !$0.isEmpty }
        return lines.joined(separator: "\n")
    }

    static let entities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}", "ndash": "–", "mdash": "—",
        "hellip": "…", "rsquo": "’", "lsquo": "‘", "rdquo": "”", "ldquo": "“", "copy": "©", "reg": "®", "trade": "™", "euro": "€", "pound": "£",
    ]

    public static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        let regex = try! NSRegularExpression(pattern: "&(#x[0-9a-fA-F]+|#[0-9]+|[a-zA-Z]+);")
        let ns = s as NSString
        var out = ""
        var last = 0
        for m in regex.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let name = ns.substring(with: m.range(at: 1))
            var replacement: String?
            if name.hasPrefix("#x"), let v = UInt32(name.dropFirst(2), radix: 16), let sc = Unicode.Scalar(v) { replacement = String(sc) }
            else if name.hasPrefix("#"), let v = UInt32(name.dropFirst()), let sc = Unicode.Scalar(v) { replacement = String(sc) }
            else { replacement = entities[name.lowercased()] }
            out += replacement ?? ns.substring(with: m.range)
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out
    }
}

extension StringProtocol {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
