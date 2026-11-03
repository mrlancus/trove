import Foundation

/// What the live notes editor styles (docs/MASTER_PLAN.md N1): headings, bold, italic,
/// strikethrough, `code`, ==highlights==, links, [[wikilinks]], #tags, checklists, bullets, quotes
/// and fenced code. Notes stay plain Markdown (sync, merge, search and the website don't change);
/// the editor only colours them. Ranges are in UTF-16 units from the start of the line, as
/// NSString/TextKit count, so a paragraph can be restyled on its own while typing.
public enum MarkdownSyntax {
    public enum Style: Equatable, Sendable {
        case heading(Int)
        case bold, italic, strike, code, highlight
        case link, wikilink, tag
        /// The characters that make the style (`**`, `#`, `[[`, …), shown faint.
        case marker
        case checkbox(checked: Bool)
        case bullet
        case quote
        case codeBlock
        /// The text of a ticked checklist item.
        case done
    }

    public struct Span: Equatable, Sendable {
        public var location: Int
        public var length: Int
        public var style: Style
        public init(_ location: Int, _ length: Int, _ style: Style) { self.location = location; self.length = length; self.style = style }
    }

    /// Whether a line opens or closes a fenced code block.
    public static func isFence(_ line: String) -> Bool { line.trimmingCharacters(in: .whitespaces).hasPrefix("```") }

    /// Every line's spans, tracking fenced code blocks from the top.
    public static func spans(text: String) -> [[Span]] {
        var inFence = false
        return text.components(separatedBy: "\n").map { line in
            let s = spans(line: line, inFence: inFence)
            if isFence(line) { inFence.toggle() }
            return s
        }
    }

    /// One line's spans. `inFence`: the line sits inside a fenced code block.
    public static func spans(line: String, inFence: Bool = false) -> [Span] {
        let u = Array(line.utf16)
        let n = u.count
        if isFence(line) { return [Span(0, n, .codeBlock), Span(0, n, .marker)] }
        if inFence { return n == 0 ? [] : [Span(0, n, .codeBlock)] }
        var out: [Span] = []
        var start = 0
        // Leading spaces (nested lists).
        while start < n, u[start] == 32 { start += 1 }
        func at(_ i: Int) -> UInt16? { i < n ? u[i] : nil }
        let hash: UInt16 = 35, dash: UInt16 = 45, star: UInt16 = 42, plus: UInt16 = 43, gt: UInt16 = 62, space: UInt16 = 32
        // Headings: 1–6 #, then a space.
        var h = start
        while at(h) == hash { h += 1 }
        let level = h - start
        if level >= 1, level <= 6, at(h) == space {
            out.append(Span(start, h + 1 - start, .marker))
            out.append(Span(0, n, .heading(level)))
            out += inline(u, from: h + 1)
            return out
        }
        // Quote.
        if at(start) == gt {
            let body = at(start + 1) == space ? start + 2 : start + 1
            out.append(Span(start, body - start, .marker))
            out.append(Span(0, n, .quote))
            out += inline(u, from: body)
            return out
        }
        // Lists and checklists: "- ", "* ", "+ ", "1. ", then maybe "[ ] " / "[x] ".
        var body = start
        var isList = false
        if let c = at(start), c == dash || c == star || c == plus, at(start + 1) == space {
            body = start + 2
            isList = true
        } else {
            var d = start
            while let c = at(d), c >= 48, c <= 57 { d += 1 }
            if d > start, at(d) == 46, at(d + 1) == space { body = d + 2; isList = true }
        }
        if isList {
            out.append(Span(start, body - start, .bullet))
            if at(body) == 91, let mark = at(body + 1), at(body + 2) == 93, at(body + 3) == space || body + 3 == n {
                let checked = mark == 120 || mark == 88
                if mark == space || checked {
                    out.append(Span(body, 3, .checkbox(checked: checked)))
                    let textStart = min(n, body + 4)
                    if checked, textStart < n { out.append(Span(textStart, n - textStart, .done)) }
                    out += inline(u, from: textStart)
                    return out
                }
            }
            out += inline(u, from: body)
            return out
        }
        out += inline(u, from: 0)
        return out
    }

    /// Inline styles from `from` to the end of the line.
    static func inline(_ u: [UInt16], from: Int) -> [Span] {
        var out: [Span] = []
        let n = u.count
        var i = from
        func find(_ pattern: [UInt16], after j: Int) -> Int? {
            var k = j
            while k + pattern.count <= n {
                if Array(u[k..<(k + pattern.count)]) == pattern { return k }
                k += 1
            }
            return nil
        }
        func pair(_ open: [UInt16], _ style: Style) -> Bool {
            guard i + open.count <= n, Array(u[i..<(i + open.count)]) == open,
                  i + open.count < n, u[i + open.count] != 32,
                  let close = find(open, after: i + open.count + 1) else { return false }
            let end = close + open.count
            out.append(Span(i, open.count, .marker))
            out.append(Span(i + open.count, close - i - open.count, style))
            out.append(Span(close, open.count, .marker))
            i = end
            return true
        }
        while i < n {
            let c = u[i]
            // `code` first: nothing inside it is styled.
            if c == 96, let close = find([96], after: i + 1) {
                out.append(Span(i, 1, .marker)); out.append(Span(i + 1, close - i - 1, .code)); out.append(Span(close, 1, .marker))
                i = close + 1
                continue
            }
            if c == 91, i + 1 < n, u[i + 1] == 91, let close = find([93, 93], after: i + 2) {
                out.append(Span(i, 2, .marker)); out.append(Span(i + 2, close - i - 2, .wikilink)); out.append(Span(close, 2, .marker))
                i = close + 2
                continue
            }
            // [text](url)
            if c == 91, let mid = find([93, 40], after: i + 1), let close = find([41], after: mid + 2) {
                out.append(Span(i, 1, .marker)); out.append(Span(i + 1, mid - i - 1, .link)); out.append(Span(mid, close - mid + 1, .marker))
                i = close + 1
                continue
            }
            if pair([42, 42], .bold) || pair([95, 95], .bold) || pair([126, 126], .strike) || pair([61, 61], .highlight) { continue }
            if (c == 42 || c == 95), pair([c], .italic) { continue }
            // #tag (not a heading, not mid-word).
            if c == 35, i + 1 < n, isTagChar(u[i + 1]), u[i + 1] != 35, i == from || u[i - 1] == 32 {
                var j = i + 1
                while j < n, isTagChar(u[j]) || u[j] == 47 { j += 1 }
                out.append(Span(i, j - i, .tag))
                i = j
                continue
            }
            // Bare URLs.
            if c == 104, let range = bareURL(u, at: i) {
                out.append(Span(i, range, .link))
                i += range
                continue
            }
            i += 1
        }
        return out
    }

    static func isTagChar(_ c: UInt16) -> Bool {
        (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 45 || c == 95 || c > 127
    }

    static func bareURL(_ u: [UInt16], at i: Int) -> Int? {
        let prefixes: [[UInt16]] = [Array("https://".utf16), Array("http://".utf16)]
        for p in prefixes where i + p.count <= u.count && Array(u[i..<(i + p.count)]) == p {
            var j = i + p.count
            while j < u.count, u[j] != 32, u[j] != 41 { j += 1 }
            return j - i
        }
        return nil
    }

    // MARK: Editing help

    /// The wikilink being typed at `cursor` (after `[[`, before `]]`), for autocomplete: its text and
    /// where it starts (UTF-16 offset of the text after `[[`).
    public static func openWikilink(in text: String, cursor: Int) -> (query: String, start: Int)? {
        let u = Array(text.utf16)
        guard cursor <= u.count else { return nil }
        var i = cursor - 1
        while i >= 1 {
            if u[i] == 10 || (u[i] == 93 && u[i - 1] == 93) { return nil }
            if u[i] == 91 && u[i - 1] == 91 {
                let q = String(utf16CodeUnits: Array(u[(i + 1)..<cursor]), count: cursor - i - 1)
                return q.count <= 80 ? (q, i + 1) : nil
            }
            i -= 1
        }
        return nil
    }

    /// What Return should insert after a list line: the same marker (an unticked box for
    /// checklists, the next number), or nil to end the list (the line was an empty item).
    public static func continuation(of line: String) -> (insert: String, endList: Bool)? {
        let spans = spans(line: line)
        guard let bullet = spans.first(where: { $0.style == .bullet }) else { return nil }
        let u = Array(line.utf16)
        let marker = String(utf16CodeUnits: Array(u[0..<(bullet.location + bullet.length)]), count: bullet.location + bullet.length)
        let box = spans.contains { if case .checkbox = $0.style { true } else { false } }
        let contentStart = bullet.location + bullet.length + (box ? 4 : 0)
        let rest = contentStart < u.count ? String(utf16CodeUnits: Array(u[contentStart...]), count: u.count - contentStart) : ""
        if rest.trimmingCharacters(in: .whitespaces).isEmpty { return ("", true) }
        var next = marker
        let trimmed = marker.trimmingCharacters(in: .whitespaces)
        if let n = Int(trimmed.dropLast()) , trimmed.hasSuffix(".") {
            let indent = String(marker.prefix { $0 == " " })
            next = "\(indent)\(n + 1). "
        }
        return ("\n" + next + (box ? "[ ] " : ""), false)
    }
}

// MARK: - Slash menu (MASTER_PLAN N3)

extension MarkdownSyntax {
    public struct SlashCommand: Equatable, Sendable, Identifiable {
        public var id: String { title }
        public var title: String
        /// What replaces "/query"; `{date}` becomes today's date.
        public var snippet: String
    }

    public static let slashCommands: [SlashCommand] = [
        .init(title: "Heading", snippet: "## "),
        .init(title: "Subheading", snippet: "### "),
        .init(title: "Checklist", snippet: "- [ ] "),
        .init(title: "Bullet list", snippet: "- "),
        .init(title: "Numbered list", snippet: "1. "),
        .init(title: "Quote", snippet: "> "),
        .init(title: "Code block", snippet: "```\n\n```"),
        .init(title: "Table", snippet: "| Column | Column |\n| --- | --- |\n|  |  |"),
        .init(title: "Divider", snippet: "---\n"),
        .init(title: "Highlight", snippet: "==text=="),
        .init(title: "Date", snippet: "{date}"),
        .init(title: "Link to a note", snippet: "[["),
    ]

    /// The "/query" typed at the start of the cursor's line, with where the "/" is.
    public static func openSlash(in text: String, cursor: Int) -> (query: String, start: Int)? {
        let u = Array(text.utf16)
        guard cursor <= u.count else { return nil }
        var lineStart = cursor
        while lineStart > 0, u[lineStart - 1] != 10 { lineStart -= 1 }
        guard lineStart < cursor, u[lineStart] == 47 else { return nil }
        let q = String(utf16CodeUnits: Array(u[(lineStart + 1)..<cursor]), count: cursor - lineStart - 1)
        guard q.count <= 20, !q.contains(" ") || q.split(separator: " ").count <= 2 else { return nil }
        return (q, lineStart)
    }

    public static func slashMatches(_ query: String) -> [SlashCommand] {
        let q = query.lowercased()
        return q.isEmpty ? slashCommands : slashCommands.filter { $0.title.lowercased().contains(q) }
    }
}
