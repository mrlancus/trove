import Foundation

/// A source-neutral item ready to be added to the library.
public struct ImportedItem: Equatable, Sendable {
    public var kind: ItemKind
    public var source: ItemSource
    public var title: String
    public var body: String = ""
    public var url: String?
    public var tags: [String] = []
    public var createdAt: Date?
    public var author: String?
    public var collection: String?
    /// Stable id from the source, used to skip duplicates on re-import.
    public var externalId: String?

    public init(kind: ItemKind, source: ItemSource, title: String, body: String = "", url: String? = nil, tags: [String] = [],
                createdAt: Date? = nil, author: String? = nil, collection: String? = nil, externalId: String? = nil) {
        self.kind = kind; self.source = source; self.title = title; self.body = body; self.url = url; self.tags = tags
        self.createdAt = createdAt; self.author = author; self.collection = collection; self.externalId = externalId
    }
}

// MARK: - Kindle "My Clippings.txt"

public enum KindleClippings {
    /// Highlights and notes, grouped by book title. Bookmarks are skipped; repeated highlights de-dupe.
    public static func parse(_ text: String) -> [ImportedItem] {
        let clean = text.replacingOccurrences(of: "\u{FEFF}", with: "").replacingOccurrences(of: "\r\n", with: "\n")
        var items: [ImportedItem] = []
        var seen = Set<String>()
        for entry in clean.components(separatedBy: "==========") {
            let lines = entry.split(separator: "\n", omittingEmptySubsequences: false).map { String($0).trimmed }
            let content = lines.drop { $0.isEmpty }
            guard content.count >= 2 else { continue }
            let header = content[content.startIndex]
            let info = content[content.startIndex + 1]
            let text = content.dropFirst(2).filter { !$0.isEmpty }.joined(separator: "\n")
            guard !text.isEmpty, !info.lowercased().contains("bookmark") else { continue }
            let (book, author) = splitAuthor(header)
            let isNote = info.lowercased().contains("your note")
            let location = HTMLMetadata.firstMatch(#"(?:Location|location|Loc\.)\s*([0-9-]+)"#, in: info)
            let page = HTMLMetadata.firstMatch(#"[Pp]age\s*([0-9ivxlc-]+)"#, in: info)
            let added = info.components(separatedBy: "Added on").last.flatMap { parseDate($0.trimmed) }
            let key = "\(book)|\(text)"
            guard seen.insert(key).inserted else { continue }
            var ref = [page.map { "p. \($0)" }, location.map { "loc. \($0)" }].compactMap { $0 }.joined(separator: ", ")
            if !ref.isEmpty { ref = " (\(ref))" }
            items.append(ImportedItem(kind: .highlight, source: .kindle, title: book,
                                      body: isNote ? "Note: \(text)" : "> \(text)\n\n— \(author ?? book)\(ref)",
                                      tags: isNote ? ["kindle", "note"] : ["kindle"], createdAt: added, author: author,
                                      collection: book, externalId: "kindle:\(key.sha256Hex.prefix(16))"))
        }
        return items
    }

    static func splitAuthor(_ header: String) -> (String, String?) {
        guard header.hasSuffix(")"), let open = header.lastIndex(of: "(") else { return (header, nil) }
        let title = header[..<open].trimmed
        let author = header[header.index(after: open)..<header.index(before: header.endIndex)].trimmed
        return (title.isEmpty ? header : title, author.isEmpty ? nil : author)
    }

    static func parseDate(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        for format in ["EEEE, d MMMM yyyy HH:mm:ss", "EEEE, MMMM d, yyyy h:mm:ss a", "EEEE, d MMMM yyyy h:mm:ss a", "EEEE, MMMM d, yyyy HH:mm:ss"] {
            f.dateFormat = format
            if let d = f.date(from: s) { return d }
        }
        return nil
    }
}

// MARK: - Browser bookmarks (Netscape HTML: Safari, Chrome, Firefox, Pocket, Raindrop exports)

public enum NetscapeBookmarks {
    public static func parse(_ html: String) -> [ImportedItem] {
        var items: [ImportedItem] = []
        var folders: [String] = []
        let pattern = #"<DT><H3[^>]*>([\s\S]*?)</H3>|</DL>|<DT><A\b([^>]*)>([\s\S]*?)</A>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let ns = html as NSString
        for m in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let whole = ns.substring(with: m.range)
            if m.range(at: 1).location != NSNotFound {
                folders.append(HTMLMetadata.decodeEntities(ns.substring(with: m.range(at: 1))).trimmed)
            } else if whole.lowercased() == "</dl>" {
                if !folders.isEmpty { folders.removeLast() }
            } else if m.range(at: 2).location != NSNotFound {
                let attrs = HTMLMetadata.attributes("<a " + ns.substring(with: m.range(at: 2)) + ">")
                guard let href = attrs["href"], href.hasPrefix("http") else { continue }
                let title = HTMLMetadata.decodeEntities(ns.substring(with: m.range(at: 3))).trimmed
                let added = attrs["add_date"].flatMap(Double.init).map { Date(timeIntervalSince1970: $0 > 1e11 ? $0 / 1000 : $0) }
                let tags = (attrs["tags"] ?? "").split(separator: ",").map { String($0).trimmed.lowercased() }.filter { !$0.isEmpty }
                items.append(ImportedItem(kind: .link, source: .import, title: title.isEmpty ? href : title, url: href, tags: tags,
                                          createdAt: added, collection: folders.last, externalId: "url:" + URLCleaner.dedupeKey(URL(string: href) ?? URL(string: "about:blank")!)))
            }
        }
        return items
    }
}

// MARK: - CSV (Raindrop, Pocket, mymind and generic exports)

public enum CSVImport {
    /// RFC 4180 parser: quoted fields, escaped quotes, newlines inside quotes.
    public static func rows(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var chars = Array(text.replacingOccurrences(of: "\r\n", with: "\n"))
        if chars.first == "\u{FEFF}" { chars.removeFirst() }
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < chars.count, chars[i + 1] == "\"" { field.append("\""); i += 1 } else { inQuotes = false }
                } else { field.append(c) }
            } else {
                switch c {
                case "\"": inQuotes = true
                case ",": row.append(field); field = ""
                case "\n": row.append(field); rows.append(row); row = []; field = ""
                default: field.append(c)
                }
            }
            i += 1
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows.filter { !($0.count == 1 && $0[0].isEmpty) }
    }

    /// Maps common column names from Raindrop (`title,note,excerpt,url,folder,tags,created`),
    /// Pocket (`title,url,time_added,tags,status`) and similar exports.
    public static func importLinks(_ text: String) -> [ImportedItem] {
        let all = rows(text)
        guard let header = all.first?.map({ $0.trimmed.lowercased() }) else { return [] }
        func col(_ names: String...) -> Int? { names.lazy.compactMap { header.firstIndex(of: $0) }.first }
        guard let urlCol = col("url", "link", "href") else { return [] }
        let titleCol = col("title", "name"), noteCol = col("note", "excerpt", "description", "content")
        let tagsCol = col("tags", "tag"), folderCol = col("folder", "collection", "list")
        let dateCol = col("created", "time_added", "date", "created_at", "added")
        return all.dropFirst().compactMap { r in
            func value(_ i: Int?) -> String { i.flatMap { $0 < r.count ? r[$0].trimmed : nil } ?? "" }
            let url = value(urlCol)
            guard url.hasPrefix("http") else { return nil }
            let tags = value(tagsCol).split(whereSeparator: { $0 == "," || $0 == "|" }).map { String($0).trimmed.lowercased() }.filter { !$0.isEmpty }
            let rawDate = value(dateCol)
            let date = Double(rawDate).map { Date(timeIntervalSince1970: $0 > 1e11 ? $0 / 1000 : $0) } ?? ISO8601DateFormatter().date(from: rawDate)
            let title = value(titleCol)
            return ImportedItem(kind: .link, source: .import, title: title.isEmpty ? url : title, body: value(noteCol), url: url, tags: tags,
                                createdAt: date, collection: value(folderCol).nilIfEmpty, externalId: "url:" + URLCleaner.dedupeKey(URL(string: url)!))
        }
    }
}

// MARK: - Readwise export API (v2 /export) JSON

public enum ReadwiseExport {
    public static func parse(_ data: Data) throws -> [ImportedItem] {
        struct Page: Decodable { var results: [Book] }
        struct Book: Decodable {
            var user_book_id: Int?
            var title: String?
            var author: String?
            var source_url: String?
            var category: String?
            var highlights: [Highlight]
        }
        struct Highlight: Decodable {
            var id: Int
            var text: String
            var note: String?
            var highlighted_at: String?
            var tags: [Tag]?
        }
        struct Tag: Decodable { var name: String }
        let page = try JSONDecoder().decode(Page.self, from: data)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return page.results.flatMap { book in
            book.highlights.map { h in
                var body = "> \(h.text)"
                if let note = h.note, !note.isEmpty { body += "\n\n\(note)" }
                body += "\n\n— \(book.author ?? book.title ?? "")"
                return ImportedItem(kind: .highlight, source: .readwise, title: book.title ?? "Highlight", body: body, url: book.source_url,
                                    tags: ["readwise"] + (h.tags ?? []).map { $0.name.lowercased() },
                                    createdAt: h.highlighted_at.flatMap { iso.date(from: $0) ?? ISO8601DateFormatter().date(from: $0) },
                                    author: book.author, collection: book.title, externalId: "readwise:\(h.id)")
            }
        }
    }
}

// MARK: - Notion blocks → Markdown (for the official API's block children)

public enum NotionBlocks {
    /// Converts the `results` array of `GET /v1/blocks/{id}/children` into Markdown.
    public static func markdown(fromBlocksJSON data: Data) throws -> String {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = root["results"] as? [[String: Any]] else { return "" }
        var lines: [(text: String, isList: Bool)] = []
        var number = 0
        for block in results {
            guard let type = block["type"] as? String, let content = block[type] as? [String: Any] else { continue }
            let text = richText(content["rich_text"])
            number = type == "numbered_list_item" ? number + 1 : 0
            switch type {
            case "paragraph": lines.append((text, false))
            case "heading_1": lines.append(("# \(text)", false))
            case "heading_2": lines.append(("## \(text)", false))
            case "heading_3": lines.append(("### \(text)", false))
            case "bulleted_list_item": lines.append(("- \(text)", true))
            case "numbered_list_item": lines.append(("\(number). \(text)", true))
            case "to_do": lines.append(("- [\((content["checked"] as? Bool) == true ? "x" : " ")] \(text)", true))
            case "quote", "callout": lines.append(("> \(text)", false))
            case "code": lines.append(("```\((content["language"] as? String) ?? "")\n\(text)\n```", false))
            case "divider": lines.append(("---", false))
            case "bookmark", "embed", "link_preview":
                if let url = content["url"] as? String { lines.append(("<\(url)>", false)) }
            case "image", "file", "pdf", "video":
                let file = (content["file"] as? [String: Any]) ?? (content["external"] as? [String: Any])
                if let url = file?["url"] as? String { lines.append(("![\(richText(content["caption"]))](\(url))", false)) }
            default: if !text.isEmpty { lines.append((text, false)) }
            }
        }
        // Blank line between blocks, but keep consecutive list items together.
        var out = ""
        for (i, line) in lines.enumerated() {
            if i > 0 { out += line.isList && lines[i - 1].isList ? "\n" : "\n\n" }
            out += line.text
        }
        return out
    }

    static func richText(_ value: Any?) -> String {
        guard let parts = value as? [[String: Any]] else { return "" }
        return parts.map { part in
            var t = (part["plain_text"] as? String) ?? ""
            let a = part["annotations"] as? [String: Any] ?? [:]
            if a["code"] as? Bool == true { t = "`\(t)`" }
            if a["bold"] as? Bool == true { t = "**\(t)**" }
            if a["italic"] as? Bool == true { t = "*\(t)*" }
            if a["strikethrough"] as? Bool == true { t = "~~\(t)~~" }
            if let href = part["href"] as? String { t = "[\(t)](\(href))" }
            return t
        }.joined()
    }
}

// MARK: - Apple Notes HTML (from AppleScript `body of note`) → Markdown

public enum AppleNotesHTML {
    public static func markdown(_ html: String) -> String {
        var s = html.replacingOccurrences(of: "\r", with: "")
        let rules: [(String, String)] = [
            ("<h1[^>]*>([\\s\\S]*?)</h1>", "\n# $1\n"), ("<h2[^>]*>([\\s\\S]*?)</h2>", "\n## $1\n"), ("<h3[^>]*>([\\s\\S]*?)</h3>", "\n### $1\n"),
            ("<(b|strong)>([\\s\\S]*?)</(b|strong)>", "**$2**"), ("<(i|em)>([\\s\\S]*?)</(i|em)>", "*$2*"),
            ("<strike>([\\s\\S]*?)</strike>", "~~$1~~"), ("<tt>([\\s\\S]*?)</tt>", "`$1`"),
            ("<a [^>]*href=\"([^\"]+)\"[^>]*>([\\s\\S]*?)</a>", "[$2]($1)"),
            ("<li[^>]*>", "\n- "), ("</li>", ""), ("<br\\s*/?>", "\n"), ("</div>", "\n"), ("<div[^>]*>", ""),
            ("</?(ul|ol|p|span|font|object|blockquote)[^>]*>", "\n"), ("<img[^>]*>", "[image]"), ("<[^>]+>", ""),
        ]
        for (pattern, template) in rules {
            s = s.replacingOccurrences(of: pattern, with: template, options: [.regularExpression, .caseInsensitive])
        }
        s = HTMLMetadata.decodeEntities(s)
        s = s.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        return s.trimmed
    }
}
