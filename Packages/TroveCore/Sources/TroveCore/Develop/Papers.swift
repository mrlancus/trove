import Foundation

/// The paper catalogue (docs/DEVELOP_PLAN.md Appendix D): facts and links only, never documents.
/// The repo's `catalogue/papers.json` is served by the relay and bundled as a fallback; papers are
/// downloaded from the board's own site onto the device and stay in a local cache (decision 3).
public struct Catalogue: Codable, Sendable, Equatable {
    public struct Layout: Codable, Sendable, Equatable {
        /// A question number at the start of a line; its capture groups are the number's parts.
        public var question: String
        /// Marks for a part ("[3 marks]"); group 1 is the number.
        public var marks: String
        /// A mark scheme's entry key at the start of a line; groups are the key's parts.
        public var scheme: String
    }
    public struct Board: Codable, Sendable, Equatable {
        public var id: String
        public var name: String
        public var terms: String
        public var layout: Layout
    }
    public enum DocType: String, Codable, Sendable { case spec, qp, ms, er, data }
    public struct Doc: Codable, Sendable, Equatable, Identifiable {
        public var id: String
        public var type: DocType
        public var paper: String?
        public var series: String?
        public var year: Int?
        public var url: String
    }
    public struct Spec: Codable, Sendable, Equatable, Identifiable {
        public var id: String
        public var board: String
        public var qualification: String
        public var subject: String
        public var code: String
        public var version: String
        public var level: ProblemLevel
        public var url: String
        public var docs: [Doc]
    }

    public var v: Int
    public var updated: String
    public var boards: [Board]
    public var specs: [Spec]

    public static func decode(_ data: Data) throws -> Catalogue { try JSONDecoder().decode(Catalogue.self, from: data) }

    public func board(_ id: String) -> Board? { boards.first { $0.id == id } }
    public func spec(_ id: String) -> Spec? { specs.first { $0.id == id } }

    /// A paper's mark scheme and examiner report (same paper, series and year).
    public func companions(of qp: Doc, in spec: Spec) -> (ms: Doc?, er: Doc?) {
        func match(_ t: DocType) -> Doc? { spec.docs.first { $0.type == t && $0.paper == qp.paper && $0.series == qp.series && $0.year == qp.year } }
        return (match(.ms), match(.er))
    }

    /// What to download for a spec, given what's cached already (doc id → present).
    public func downloadPlan(spec id: String, cached: Set<String>) -> [Doc] {
        (spec(id)?.docs ?? []).filter { !cached.contains($0.id) }
    }

    /// "AQA 7408/2 June 2023 Q4.2": the source line shown on request.
    public func label(_ doc: Doc, in spec: Spec, question key: String) -> String {
        let board = board(spec.board)?.name ?? spec.board.uppercased()
        let paper = doc.paper.map { "\(spec.code)/\($0)" } ?? spec.code
        let when = [doc.series, doc.year.map(String.init)].compactMap { $0 }.joined(separator: " ")
        return "\(board) \(paper)\(when.isEmpty ? "" : " " + when) Q\(key)"
    }
}

/// Splits a paper into questions from positioned text lines (PDF text on Apple, pdf.js on the website,
/// Vision for scans), and matches a mark scheme's entries by the same keys (§B3 point 4).
public enum PaperSplitter {
    public struct Line: Sendable, Equatable {
        public var page: Int
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double
        public var text: String
        public init(page: Int, x: Double, y: Double, width: Double, height: Double, text: String) {
            self.page = page; self.x = x; self.y = y; self.width = width; self.height = height; self.text = text
        }
    }

    public struct Question: Sendable, Equatable {
        public var key: String
        public var parent: String?
        public var regions: [PageRegion]
        public var marks: Int?
        public var text: String
    }

    /// A question number counts only this close to the page's left margin (points).
    public static let marginSlack = 24.0

    /// The key from a match's groups: group 1 is the question number (spaces dropped, so AQA's
    /// "0 1" is 1), later groups are its parts ("0 1 . 2" → "1.2").
    static func key(_ groups: [String]) -> String? {
        guard let first = groups.first, let n = Int(first.filter { !$0.isWhitespace }) else { return nil }
        let parts = groups.dropFirst().map { $0.filter { !$0.isWhitespace } }.filter { !$0.isEmpty }.map { String(Int($0) ?? 0) }
        return ([String(n)] + parts).joined(separator: ".")
    }

    static func groups(_ regex: NSRegularExpression, _ text: String) -> [String]? {
        let ns = text as NSString
        guard let m = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (1..<m.numberOfRanges).map { i in
            let r = m.range(at: i)
            return r.location == NSNotFound ? "" : ns.substring(with: r)
        }
    }

    public static func split(_ lines: [Line], layout: Catalogue.Layout, pageHeight: Double = 842, pageWidth: Double = 595) -> [Question] {
        guard let q = try? NSRegularExpression(pattern: layout.question), let mk = try? NSRegularExpression(pattern: layout.marks) else { return [] }
        let ordered = lines.sorted { ($0.page, $0.y, $0.x) < ($1.page, $1.y, $1.x) }
        let margin = (ordered.map(\.x).min() ?? 0) + marginSlack
        var starts: [(index: Int, key: String)] = []
        for (i, line) in ordered.enumerated() where line.x <= margin {
            if let g = groups(q, line.text), let k = key(g), starts.last?.key != k { starts.append((i, k)) }
        }
        var out: [Question] = []
        for (n, start) in starts.enumerated() {
            let end = n + 1 < starts.count ? starts[n + 1].index : ordered.count
            let body = Array(ordered[start.index..<end])
            var byPage: [Int: (top: Double, bottom: Double)] = [:]
            for l in body {
                let r = byPage[l.page] ?? (l.y, l.y + l.height)
                byPage[l.page] = (min(r.top, l.y), max(r.bottom, l.y + l.height))
            }
            // A region runs from the question's first line to the next question's start (or the page's end),
            // so diagrams between the lines come with it.
            let regions = byPage.keys.sorted().map { page -> PageRegion in
                let top = byPage[page]!.top
                let nextOnPage = n + 1 < starts.count && ordered[starts[n + 1].index].page == page ? ordered[starts[n + 1].index].y : pageHeight
                return PageRegion(page: page, rect: [0, top, pageWidth, max(0, nextOnPage - top)])
            }
            let marks = body.compactMap { groups(mk, $0.text).flatMap { $0.first }.flatMap { Int($0) } }.reduce(0, +)
            let parent = start.key.contains(".") ? String(start.key[..<start.key.lastIndex(of: ".")!]) : nil
            out.append(Question(key: start.key, parent: parent, regions: regions, marks: marks > 0 ? marks : nil,
                                text: body.map(\.text).joined(separator: "\n")))
        }
        return out
    }

    /// Mark-scheme entries by key: the text from each key to the next.
    public static func scheme(_ lines: [Line], layout: Catalogue.Layout) -> [String: String] {
        guard let s = try? NSRegularExpression(pattern: layout.scheme) else { return [:] }
        let ordered = lines.sorted { ($0.page, $0.y, $0.x) < ($1.page, $1.y, $1.x) }
        var out: [String: [String]] = [:]
        var current: String?
        for line in ordered {
            if let g = groups(s, line.text), let k = key(g) { current = k }
            if let current { out[current, default: []].append(line.text) }
        }
        return out.mapValues { $0.joined(separator: "\n") }
    }
}

/// Anki export (docs/DEVELOP_PLAN.md §B3 point 8): a tab-separated file with a GUID column, so
/// importing it again updates the same notes instead of duplicating them (Anki manual, "Text files").
public enum AnkiExport {
    /// A stable GUID for a Trove card: the same card always gets the same one.
    public static func guid(_ cardId: String) -> String { "trove-" + Develop.sha12(cardId) }

    static func field(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\t", with: "    ").replacingOccurrences(of: "\r\n", with: "<br>").replacingOccurrences(of: "\n", with: "<br>")
    }

    /// `#separator:tab`, `#html:true`, `#guid column:1`, `#tags column:4`, then guid, front, back, tags.
    /// The deck is "Trove" unless named; the source note's title goes in as a tag.
    public static func tsv(_ cards: [StudyCard], deck: String = "Trove") -> String {
        var out = "#separator:tab\n#html:true\n#guid column:1\n#tags column:4\n#deck:\(deck)\n"
        for c in cards.sorted(by: { $0.id < $1.id }) {
            let tag = "trove::" + Develop.slug(c.noteTitle.isEmpty ? "note" : c.noteTitle)
            out += [guid(c.id), field(c.front), field(c.back), tag].joined(separator: "\t") + "\n"
        }
        return out
    }
}
