import Foundation

/// Small, dependency-free Markdown helpers: YAML front matter, `[[wikilinks]]`, `#tags`.
/// Enough for Obsidian round-trips. Rendering is the app's job (AttributedString(markdown:)).
public enum Markdown {
    public struct Document: Equatable, Sendable {
        public var frontMatter: [String: FrontMatterValue]
        public var body: String
    }

    public enum FrontMatterValue: Equatable, Sendable {
        case string(String)
        case list([String])

        public var string: String? { if case .string(let s) = self { s } else { nil } }
        public var list: [String] {
            switch self {
            case .list(let l): l
            case .string(let s): s.split(separator: ",").map { String($0).trimmed }.filter { !$0.isEmpty }
            }
        }
    }

    /// Parses `---\nkey: value\nlist:\n  - a\n---\nbody`. Supports scalars, `[a, b]` and `- item` lists.
    public static func parse(_ text: String) -> Document {
        let normalised = text.replacingOccurrences(of: "\r\n", with: "\n")
        guard normalised.hasPrefix("---\n") else { return Document(frontMatter: [:], body: normalised) }
        let rest = normalised.dropFirst(4)
        guard let end = rest.range(of: "\n---\n") ?? (rest.hasSuffix("\n---") ? rest.range(of: "\n---", options: .backwards) : nil) else {
            return Document(frontMatter: [:], body: normalised)
        }
        let yaml = rest[..<end.lowerBound]
        var body = String(rest[end.upperBound...])
        if body.hasPrefix("\n") { body.removeFirst() }

        var fm: [String: FrontMatterValue] = [:]
        var currentKey: String?
        for rawLine in yaml.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.trimmed.isEmpty || line.trimmed.hasPrefix("#") { continue }
            if line.trimmed.hasPrefix("- "), let key = currentKey {
                let item = unquote(String(line.trimmed.dropFirst(2)))
                fm[key] = .list((fm[key]?.list ?? []) + [item])
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmed
            let value = line[line.index(after: colon)...].trimmed
            currentKey = key
            if value.isEmpty {
                fm[key] = .list([])
            } else if value.hasPrefix("["), value.hasSuffix("]") {
                fm[key] = .list(value.dropFirst().dropLast().split(separator: ",").map { unquote(String($0).trimmed) }.filter { !$0.isEmpty })
            } else {
                fm[key] = .string(unquote(value))
            }
        }
        return Document(frontMatter: fm, body: body)
    }

    public static func render(frontMatter: [(String, FrontMatterValue)], body: String) -> String {
        guard !frontMatter.isEmpty else { return body }
        var out = "---\n"
        for (key, value) in frontMatter {
            switch value {
            case .string(let s): out += "\(key): \(quoteIfNeeded(s))\n"
            case .list(let l):
                if l.isEmpty { out += "\(key): []\n" } else { out += "\(key):\n" + l.map { "  - \(quoteIfNeeded($0))\n" }.joined() }
            }
        }
        return out + "---\n" + body
    }

    static func unquote(_ s: String) -> String {
        if s.count >= 2, (s.hasPrefix("\"") && s.hasSuffix("\"")) || (s.hasPrefix("'") && s.hasSuffix("'")) {
            return String(s.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"")
        }
        return s
    }

    static func quoteIfNeeded(_ s: String) -> String {
        let special = CharacterSet(charactersIn: ":#[]{},&*!|>'\"%@`")
        if s.isEmpty || s.rangeOfCharacter(from: special) != nil || s.hasPrefix(" ") || s.hasPrefix("-") {
            return "\"" + s.replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        return s
    }

    /// `[[Note]]`, `[[Note|alias]]`, `[[Note#Heading]]` → link targets ("Note").
    public static func wikilinks(in text: String) -> [String] {
        HTMLMetadata.allMatches(#"\[\[([^\]\|#\n]+)(?:#[^\]\|\n]*)?(?:\|[^\]\n]*)?\]\]"#, in: text).map(\.trimmed)
    }

    /// Inline `#tag` and `#nested/tag` (not headings, not inside code spans, not URL fragments).
    public static func hashtags(in text: String) -> [String] {
        var tags: [String] = []
        var inFence = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.trimmed.hasPrefix("```") { inFence.toggle(); continue }
            if inFence { continue }
            let noCode = String(line).replacingOccurrences(of: "`[^`]*`", with: "", options: .regularExpression)
            for tag in HTMLMetadata.allMatches(#"(?:^|[\s(])#([\p{L}\p{N}_][\p{L}\p{N}_/-]*)"#, in: noCode) where !tag.allSatisfy(\.isNumber) {
                if !tags.contains(tag.lowercased()) { tags.append(tag.lowercased()) }
            }
        }
        return tags
    }

    /// First `# Heading` if the note starts with one.
    public static func leadingTitle(_ body: String) -> String? {
        guard let first = body.split(separator: "\n", omittingEmptySubsequences: true).first, first.hasPrefix("# ") else { return nil }
        return String(first.dropFirst(2)).trimmed
    }
}
