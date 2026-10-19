import Foundation

/// Two-way mapping between Trove notes and an Obsidian-style Markdown folder.
/// Trove writes `trove-id` in the front matter so edits made in Obsidian find their way back.
public enum ObsidianMirror {
    public struct ParsedNote: Equatable, Sendable {
        public var troveId: String?
        public var title: String
        public var tags: [String]
        public var url: String?
        public var body: String
        public var links: [String]
    }

    /// Relative path for an item, e.g. `Notes/Recipes/Best ever ramen.md`. Collisions get a short id suffix.
    public static func relativePath(for item: Item, folder: String = "Notes", taken: Set<String> = []) -> String {
        let sub: String
        switch item.category {
        case .recipe: sub = "Recipes/"
        case .place: sub = "Places/"
        case .product: sub = "Things to buy/"
        case .article, .video: sub = "Reading/"
        default: sub = ""
        }
        let base = "\(folder)/\(sub)\(safeFileName(item.displayTitle))"
        let path = base + ".md"
        if !taken.contains(path) { return path }
        return "\(base) (\(item.id.prefix(6))).md"
    }

    public static func safeFileName(_ title: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|#^[]").union(.controlCharacters).union(.newlines)
        let cleaned = title.components(separatedBy: bad).joined(separator: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmed
        let short = String(cleaned.prefix(120))
        return short.isEmpty || short.hasPrefix(".") ? "Untitled" + short : short
    }

    public static func render(_ item: Item) -> String {
        var fm: [(String, Markdown.FrontMatterValue)] = [("trove-id", .string(item.id))]
        if let url = item.url { fm.append(("url", .string(url.absoluteString))) }
        if !item.tags.isEmpty { fm.append(("tags", .list(item.tags))) }
        if item.category != .other && item.category != .note { fm.append(("category", .string(item.category.rawValue))) }
        fm.append(("created", .string(ISO8601DateFormatter().string(from: item.createdAt))))
        var body = item.body
        if body.isEmpty, let summary = item.summary { body = summary }
        if Markdown.leadingTitle(body) == nil, !item.title.isEmpty { body = "# \(item.title)\n\n" + body }
        if !body.hasSuffix("\n") { body += "\n" }
        return Markdown.render(frontMatter: fm, body: body)
    }

    public static func parse(_ text: String, fileName: String) -> ParsedNote {
        let doc = Markdown.parse(text)
        var body = doc.body
        var title = doc.frontMatter["title"]?.string ?? ""
        if let heading = Markdown.leadingTitle(body) {
            if title.isEmpty { title = heading }
            // Drop the heading Trove added so it doesn't become part of the body on re-import.
            if heading == title, let range = body.range(of: "# \(heading)") {
                body.removeSubrange(range)
                while body.hasPrefix("\n") { body.removeFirst() }
            }
        }
        if title.isEmpty { title = fileName.hasSuffix(".md") ? String(fileName.dropLast(3)) : fileName }
        let tags = (doc.frontMatter["tags"]?.list ?? []).map { $0.lowercased().replacingOccurrences(of: "#", with: "") }
        var allTags = tags
        for t in Markdown.hashtags(in: body) where !allTags.contains(t) { allTags.append(t) }
        if body.hasSuffix("\n") { body.removeLast() }
        return ParsedNote(troveId: doc.frontMatter["trove-id"]?.string, title: title, tags: allTags,
                          url: doc.frontMatter["url"]?.string ?? doc.frontMatter["source"]?.string, body: body,
                          links: Markdown.wikilinks(in: body))
    }
}
