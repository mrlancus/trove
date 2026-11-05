import Foundation

/// One statement of a course's specification (learn-pivot plan §C6): "3.4.1.6 Momentum" with what it says
/// ("momentum = mass × velocity; conservation of linear momentum…"). Read on the device from the downloaded
/// specification (decision 12: nothing is shipped), so every device that reads the same PDF gets the same
/// statements and ids.
public struct SpecStatement: Codable, Sendable, Equatable, Identifiable {
    /// The specification's own number: "3.4.1.6", "4.1.2", "B1.2".
    public var number: String
    public var title: String
    /// What the statement says, as printed (at most `SpecReader.maxText` characters).
    public var text: String
    /// The number of the statement it sits under, if any ("3.4.1" for "3.4.1.6").
    public var parent: String?
    /// The concept this statement stands for: `concept.<slug(course + number)>` (a skill, origin `spec`).
    public var concept: String

    public var id: String { number }
    public var depth: Int { number.split(separator: ".").count }
    public var label: String { "\(number) \(title)" }
}

/// Reads a specification PDF's text lines into numbered statements.
///
/// How: numbered headings ("3.4.1.6 Momentum") start a statement and every other line is added to the one before
/// it. The contents pages list the same numbers first, so a number seen again replaces an earlier one that had no
/// text of its own. Lines repeated on many pages (running headers, footers, "Visit aqa.org.uk/7408…") and page
/// numbers are dropped. Front matter and administration sections ("Introduction", "Scheme of assessment",
/// "General administration") are left out, so what's left is what can be asked.
public enum SpecReader {
    public static let maxText = 1500

    public static func statements(_ lines: [PaperSplitter.Line], course: String) -> [SpecStatement] {
        let repeated = runningLines(lines)
        let body = joinNumbers(lines.filter { !repeated.contains(normal($0.text)) && !isPageNumber($0.text) })
        let bodyHeight = median(body.map(\.height)) ?? 10

        var order: [String] = []
        var byNumber: [String: SpecStatement] = [:]
        var current: String?
        var section: String?
        var codeSection: [String: String] = [:]
        /// A board's code ("AA") used again under another section (History's thematic studies reuse AA–AC): it's
        /// kept apart as "<section>.<code>".
        func key(_ number: String) -> String {
            guard isCode(number), let section else { return number }
            if let first = codeSection[number], first != section { return "\(section).\(number)" }
            codeSection[number] = section
            return number
        }
        for line in body {
            let text = line.text.trimmingCharacters(in: .whitespaces)
            if let (raw, title) = heading(text), !isAssessmentObjective(raw), line.height >= bodyHeight * (isLetterCode(raw) ? 1.2 : 0.95),
               !looksLikeContentsEntry(title) {
                let number = key(raw)
                if !isCode(raw) { section = raw }
                if let old = byNumber[number], old.text.count >= 40 {
                    // Already read with its text: this is a running heading or a cross-reference.
                    current = number
                    continue
                }
                if byNumber[number] == nil { order.append(number) }
                byNumber[number] = SpecStatement(number: number, title: title, text: "", parent: nil,
                                                 concept: Develop.conceptId("\(course) \(number)"))
                current = number
                continue
            }
            // A code printed on a line of its own in a heading's size (AQA Maths' "N1"): its title is the next line.
            if text.range(of: numberOnly, options: .regularExpression) != nil, line.height >= bodyHeight * 1.2,
               text.contains(where: \.isLetter), !isAssessmentObjective(text) {
                let number = key(text.hasSuffix(".") ? String(text.dropLast()) : text)
                if byNumber[number] == nil {
                    order.append(number)
                    byNumber[number] = SpecStatement(number: number, title: "", text: "", parent: nil,
                                                     concept: Develop.conceptId("\(course) \(number)"))
                }
                current = number
                continue
            }
            guard let c = current, var s = byNumber[c], s.text.count < maxText else { continue }
            if s.title.isEmpty || (s.text.isEmpty && s.title.count < 40 && s.title.last?.isLetter == true && line.height < bodyHeight * 1.2
                                   && byNumber[c].map { isCode($0.number) } == true) {
                s.title = String((s.title.isEmpty ? text : s.title + " " + text).prefix(120))
                byNumber[c] = s
                continue
            }
            s.text = s.text.isEmpty ? text : s.text + "\n" + text
            if s.text.count > maxText { s.text = String(s.text.prefix(maxText)) }
            byNumber[c] = s
        }

        // Parents: the nearest number above it that was read ("3.4.1" for "3.4.1.6", else "3.4"). A code with no
        // dotted prefix of its own (AQA Maths' "N1", History's "AB") sits under the dotted section before it.
        var out = order.compactMap { byNumber[$0] }
        let known = Set(order)
        section = nil
        for i in out.indices {
            var parts = out[i].number.split(separator: ".").map(String.init)
            while parts.count > 1 {
                parts.removeLast()
                let p = parts.joined(separator: ".")
                if known.contains(p) { out[i].parent = p; break }
            }
            let dotted = out[i].number.first?.isNumber == true && out[i].number.contains(".") && !isCode(String(out[i].number.split(separator: ".").last ?? ""))
            if out[i].parent == nil, !dotted, let section { out[i].parent = section }
            if dotted { section = out[i].number }
        }
        return contentOnly(out)
    }

    /// Top-level statements: the topics ("3.4 Mechanics and materials").
    public static func topics(_ statements: [SpecStatement]) -> [SpecStatement] {
        let roots = statements.filter { $0.parent == nil }
        let dotted = roots.filter { $0.number.contains(".") }
        return dotted.isEmpty ? roots : dotted
    }

    /// The statements under `number`, at any depth.
    public static func under(_ number: String, in statements: [SpecStatement]) -> [SpecStatement] {
        statements.filter { $0.number.hasPrefix(number + ".") }
    }

    /// The statement a question is most likely about (learn-pivot plan §B4: topics from the spec, not the paper):
    /// the words they share, rarer words counting more, the deepest statement winning a tie. Nil when nothing
    /// shares at least two uncommon words with the question.
    public static func best(for question: String, in statements: [SpecStatement]) -> SpecStatement? {
        guard !statements.isEmpty else { return nil }
        let docs = statements.map { words($0.title + " " + $0.title + " " + $0.text) }
        var df: [String: Int] = [:]
        for d in docs { for w in d { df[w, default: 0] += 1 } }
        let q = words(question)
        guard !q.isEmpty else { return nil }
        let n = Double(statements.count)
        var best: (score: Double, shared: Int, depth: Int, index: Int)?
        for (i, d) in docs.enumerated() {
            let shared = q.intersection(d)
            guard shared.count >= 2 else { continue }
            let score = shared.reduce(0.0) { $0 + log(1 + n / Double(df[$1] ?? 1)) }
            let depth = statements[i].depth
            if best == nil || score > best!.score + 1e-9 || (abs(score - best!.score) < 1e-9 && depth > best!.depth) {
                best = (score, shared.count, depth, i)
            }
        }
        return best.map { statements[$0.index] }
    }

    /// The level a topic list groups by: the statement's ancestor one below the topic ("3.4.1 Force, energy and
    /// momentum" for "3.4.1.6 Momentum"), or the statement itself when it's that high already.
    public static func subtopic(of s: SpecStatement, in statements: [SpecStatement]) -> SpecStatement {
        let byNumber = Dictionary(statements.map { ($0.number, $0) }, uniquingKeysWith: { a, _ in a })
        var chain = [s]
        var x = s
        while let p = x.parent, let up = byNumber[p], chain.count < 10 { chain.append(up); x = up }
        // chain: s, parent, …, topic. One below the topic, if there is one.
        return chain.count >= 2 ? chain[chain.count - 2] : s
    }

    static let stopwords: Set<String> = ["this", "that", "with", "from", "they", "their", "there", "which", "what", "when", "where",
                                         "your", "have", "been", "will", "would", "should", "could", "about", "into", "than", "then",
                                         "these", "those", "each", "such", "also", "only", "other", "some", "more", "most", "must",
                                         "give", "show", "state", "explain", "describe", "calculate", "determine", "answer", "marks",
                                         "mark", "figure", "table", "question", "students", "should", "including", "between", "using",
                                         "used", "uses", "able", "know", "understand", "following", "write", "below", "above", "value"]

    /// Lowercased words of 4+ letters, without common ones, with a plural "s" dropped.
    static func words(_ text: String) -> Set<String> {
        var out = Set<String>()
        for raw in text.lowercased().split(whereSeparator: { !$0.isLetter }) where raw.count >= 4 {
            var w = String(raw)
            if w.count > 4, w.hasSuffix("s"), !w.hasSuffix("ss") { w.removeLast() }
            if !stopwords.contains(w) { out.insert(w) }
        }
        return out
    }

    // MARK: Pieces

    /// "3.4.1.6 Momentum", "3.4.1.6. Momentum", "B1.2 Cell biology", "N1 Order positive…", "AB Germany, 1890–1945"
    /// → (number, title).
    static func heading(_ text: String) -> (String, String)? {
        guard let m = text.range(of: #"^(\d{1,2}(?:\.\d{1,2}){1,4}|[A-Z]{1,2}\d{1,2}(?:\.\d{1,2}){0,3}[a-z]?|[A-Z]{2})\.?\s+(\S.{1,140})$"#, options: .regularExpression) else { return nil }
        let line = String(text[m])
        guard let space = line.firstIndex(where: { $0 == " " || $0 == "\t" }) else { return nil }
        var number = String(line[..<space])
        if number.hasSuffix(".") { number.removeLast() }
        let title = line[space...].trimmingCharacters(in: .whitespaces)
        // A title starts like a title: a capital letter, a digit or a bracket, not "mm" or "kg" from a table.
        guard let first = title.unicodeScalars.first, CharacterSet.uppercaseLetters.contains(first) || first == "(" else { return nil }
        // Numbers in tables and maths ("1.5 1.6 1.7", "3.2 × 10") aren't headings.
        if title.range(of: #"^[\d.,×x\s-]+$"#, options: .regularExpression) != nil { return nil }
        return (number, title)
    }

    static let numberOnly = #"^(\d{1,2}(?:\.\d{1,2}){0,4}|[A-Z]{1,2}\d{1,2}(?:\.\d{1,2}){0,3}[a-z]?|[A-Z]{2})\.?$"#

    /// "AB", "AA": a code of letters only, which needs a heading's size to count (it could be any word).
    static func isLetterCode(_ number: String) -> Bool { number.allSatisfy(\.isLetter) }

    static func isAssessmentObjective(_ number: String) -> Bool { number.range(of: #"^AO\d"#, options: .regularExpression) != nil }

    /// "N1", "AB", "B1.2": a board's code rather than a plain section number.
    static func isCode(_ number: String) -> Bool { number.first?.isLetter == true }

    /// A number printed apart from its title on the same row ("4.1" | "Cell biology", "N1" | "Order positive and
    /// negative integers…") is joined to the text right of it.
    static func joinNumbers(_ lines: [PaperSplitter.Line]) -> [PaperSplitter.Line] {
        var out: [PaperSplitter.Line] = []
        var used = Set<Int>()
        for (i, l) in lines.enumerated() where !used.contains(i) {
            var line = l
            if l.text.trimmingCharacters(in: .whitespaces).range(of: numberOnly, options: .regularExpression) != nil {
                let row = lines.indices.filter { j in
                    j != i && !used.contains(j) && lines[j].page == l.page && abs(lines[j].y - l.y) < max(3, l.height * 0.4) && lines[j].x > l.x
                }.min { lines[$0].x < lines[$1].x }
                if let j = row {
                    used.insert(j)
                    line.text = l.text.trimmingCharacters(in: .whitespaces) + " " + lines[j].text
                    line.height = max(l.height, lines[j].height)
                    line.width = lines[j].x + lines[j].width - l.x
                }
            }
            out.append(line)
        }
        return out
    }

    /// A contents line: the title ends in dot leaders or a page number.
    static func looksLikeContentsEntry(_ title: String) -> Bool {
        title.range(of: #"(\.{3,}|…)\s*\d*$"#, options: .regularExpression) != nil
            || title.range(of: #"\s{2,}\d{1,3}$"#, options: .regularExpression) != nil
    }

    static func isPageNumber(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespaces).range(of: #"^(page\s*)?\d{1,3}(\s*of\s*\d{1,3})?$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func normal(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: #"\d+"#, with: "#", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }

    /// Lines printed on at least a fifth of the pages (and on 4 or more): headers and footers.
    static func runningLines(_ lines: [PaperSplitter.Line]) -> Set<String> {
        let pages = Set(lines.map(\.page)).count
        guard pages >= 4 else { return [] }
        var onPages: [String: Set<Int>] = [:]
        for l in lines {
            let t = l.text.trimmingCharacters(in: .whitespaces)
            // Numbers and headings are never running lines, even though "4.1" and "N1" look alike once digits go.
            if t.range(of: numberOnly, options: .regularExpression) != nil || heading(t) != nil { continue }
            onPages[normal(t), default: []].insert(l.page)
        }
        return Set(onPages.filter { $0.value.count >= max(4, pages / 5) }.keys)
    }

    static func median(_ xs: [Double]) -> Double? {
        guard !xs.isEmpty else { return nil }
        let s = xs.sorted()
        return s[s.count / 2]
    }

    static let adminTitles = ["introduction", "why choose", "support and resources", "specification at a glance",
                              "scheme of assessment", "assessment objectives", "general administration", "entries",
                              "non-exam assessment", "assessment criteria", "aims", "rationale", "overview", "appendix",
                              "administration", "access arrangements", "results", "re-sits", "previous learning",
                              "qualification at a glance", "key features", "assessment information", "about this specification",
                              "contents", "glossary", "command words", "grade descriptors", "assessment", "access to",
                              "subject content overview", "working scientifically", "practical assessment", "overlaps",
                              "awarding", "classification", "prohibited", "the specification", "discount", "qualification title"]

    /// Drops front matter and administration: a top-level section whose title is one of `adminTitles`, with
    /// everything under it, and any top-level section with nothing under it and no text (a contents leftover).
    static func contentOnly(_ all: [SpecStatement]) -> [SpecStatement] {
        let isAdmin: (SpecStatement) -> Bool = { s in
            let t = s.title.lowercased()
            return adminTitles.contains { t.hasPrefix($0) }
        }
        let tops = all.filter { $0.parent == nil }
        var dropped = Set<String>()
        for top in tops where isAdmin(top) || (under(top.number, in: all).isEmpty && top.text.count < 40) {
            dropped.insert(top.number)
        }
        // Top-level chapters ("3 Subject content" isn't numbered with a dot, so chapters show as "3.1", "3.2"):
        // an admin statement at any depth takes its own subtree with it.
        for s in all where isAdmin(s) { dropped.insert(s.number) }
        let kept = all.filter { s in !dropped.contains { s.number == $0 || s.number.hasPrefix($0 + ".") } }
        // Chapters: the subject content is where most statements are ("3" in "3.4.1.6"); front matter and
        // administration chapters are small. A chapter is kept with at least a quarter of the biggest one's count.
        let byNumber = Dictionary(kept.map { ($0.number, $0) }, uniquingKeysWith: { a, _ in a })
        func chapter(_ s: SpecStatement) -> String {
            var x = s
            var seen = 0
            while isCode(x.number), let p = x.parent, let up = byNumber[p], seen < 8 { x = up; seen += 1 }
            return String(x.number.split(separator: ".").first ?? "")
        }
        var counts: [String: Int] = [:]
        for s in kept { counts[chapter(s), default: 0] += 1 }
        let biggest = counts.values.max() ?? 0
        return kept.filter { counts[chapter($0), default: 0] >= max(3, biggest / 4) }
    }
}
