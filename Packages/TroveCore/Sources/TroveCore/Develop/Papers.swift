import Foundation

/// The paper catalogue (docs/CATALOGUE.md): facts and links only, never documents. Built from the
/// boards' own public listings by `scripts/catalogue/build.py`: `catalogue/index.json` lists boards and
/// specs (no documents) and `catalogue/specs/<spec id>.json` holds one spec's documents, so the apps only
/// read the specs you choose. Papers are downloaded from the board's own site onto the device and stay in
/// a local cache (decision 3); your own uploads are vault items and sync.
public struct Catalogue: Codable, Sendable, Equatable {
    public struct Layout: Codable, Sendable, Equatable {
        /// A question number at the start of a line; its capture groups are the number's parts.
        public var question: String
        /// Marks for a part ("[3 marks]"); group 1 is the number.
        public var marks: String
        /// A mark scheme's entry key at the start of a line; groups are the key's parts.
        public var scheme: String
        /// Run `PaperSplitter.numberParts` first ("1 (a)" → "1.1"): every board but AQA.
        public var parts: Bool?
        public init(question: String, marks: String, scheme: String, parts: Bool? = nil) {
            self.question = question; self.marks = marks; self.scheme = scheme; self.parts = parts
        }
    }
    public struct Board: Codable, Sendable, Equatable {
        public var id: String
        public var name: String
        public var site: String?
        /// Only where a board numbers questions its own way (AQA's "0 1 . 1"); others use `PaperSplitter.genericLayout`.
        public var layout: Layout?
    }
    /// A board that isn't read automatically, and why (the app says so and offers uploads).
    public struct Unlisted: Codable, Sendable, Equatable {
        public var id: String
        public var why: String
    }
    public enum DocType: String, Codable, Sendable { case spec, qp, ms, er, data }
    public struct Doc: Codable, Sendable, Equatable, Identifiable {
        public var id: String
        public var type: DocType
        public var paper: String?
        /// "Higher" or "Foundation" for tiered GCSEs.
        public var tier: String?
        /// "Paper 1 Section A Option C Russia, 1894-1945"; tells option papers apart.
        public var title: String?
        public var series: String?
        public var year: Int?
        public var url: String
        public init(id: String, type: DocType, paper: String? = nil, tier: String? = nil, title: String? = nil, series: String? = nil, year: Int? = nil, url: String) {
            self.id = id; self.type = type; self.paper = paper; self.tier = tier; self.title = title; self.series = series; self.year = year; self.url = url
        }
    }
    public struct Spec: Codable, Sendable, Equatable, Identifiable {
        public var id: String
        public var board: String
        /// "GCSE", "AS", "A-level", "IGCSE", "International AS & A Level".
        public var qualification: String
        public var subject: String
        public var code: String
        public var level: ProblemLevel
        public var url: String
        /// In the index: how many question papers, and the first and last year.
        public var papers: Int?
        public var years: [Int]?
        /// Empty in the index; filled from the spec's own file.
        public var docs: [Doc]

        enum CodingKeys: String, CodingKey { case id, board, qualification, subject, code, level, url, papers, years, docs }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            board = try c.decode(String.self, forKey: .board)
            qualification = try c.decode(String.self, forKey: .qualification)
            subject = try c.decode(String.self, forKey: .subject)
            code = try c.decode(String.self, forKey: .code)
            level = (try? c.decode(ProblemLevel.self, forKey: .level)) ?? .other
            url = try c.decode(String.self, forKey: .url)
            papers = try c.decodeIfPresent(Int.self, forKey: .papers)
            years = try c.decodeIfPresent([Int].self, forKey: .years)
            docs = try c.decodeIfPresent([Doc].self, forKey: .docs) ?? []
        }
        public init(id: String, board: String, qualification: String, subject: String, code: String, level: ProblemLevel, url: String, docs: [Doc]) {
            self.id = id; self.board = board; self.qualification = qualification; self.subject = subject; self.code = code
            self.level = level; self.url = url; self.docs = docs
        }
        /// "AQA A-level Physics (7408)".
        public var name: String { "\(qualification) \(subject) (\(code))" }
        /// The question papers, newest first, each with its mark scheme and report alongside.
        public var questionPapers: [Doc] { docs.filter { $0.type == .qp } }
    }

    public var v: Int
    public var updated: String
    public var boards: [Board]
    public var unlisted: [Unlisted]?
    public var specs: [Spec]

    public static func decode(_ data: Data) throws -> Catalogue { try JSONDecoder().decode(Catalogue.self, from: data) }
    public static func decodeSpec(_ data: Data) throws -> Spec { try JSONDecoder().decode(Spec.self, from: data) }

    public func board(_ id: String) -> Board? { boards.first { $0.id == id } }
    public func spec(_ id: String) -> Spec? { specs.first { $0.id == id } }

    /// How a board's papers split: its own layout, else the generic one.
    public func layout(for board: String) -> Layout { self.board(board)?.layout ?? PaperSplitter.genericLayout }

    /// Levels in the order the picker shows them.
    public static let levelOrder: [ProblemLevel] = [.gcse, .igcse, .alevel]

    /// Specs at a level, optionally one board's, by subject then qualification.
    public func specs(level: ProblemLevel, board: String? = nil) -> [Spec] {
        specs.filter { $0.level == level && (board == nil || $0.board == board) }
            .sorted { ($0.subject, $0.qualification, $0.board) < ($1.subject, $1.qualification, $1.board) }
    }

    /// Specs whose subject, code or board matches a search ("phys", "7408", "ocr chem").
    public func search(_ query: String, level: ProblemLevel? = nil) -> [Spec] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        return specs.filter { s in
            (level == nil || s.level == level) && words.allSatisfy { w in
                let hay = "\(s.subject) \(s.code) \(s.qualification) \(board(s.board)?.name ?? s.board) \(s.board)".lowercased()
                return hay.contains(w)
            }
        }.sorted { ($0.subject, $0.qualification, $0.board) < ($1.subject, $1.qualification, $1.board) }
    }

    /// A paper's mark scheme and examiner report: same paper, tier, series and year; among several
    /// (option papers), the one with the same title.
    public func companions(of qp: Doc, in spec: Spec) -> (ms: Doc?, er: Doc?) {
        func match(_ t: DocType) -> Doc? {
            let same = spec.docs.filter { $0.type == t && $0.paper == qp.paper && $0.series == qp.series && $0.year == qp.year && $0.tier == qp.tier }
            return same.count > 1 ? (same.first { $0.title == qp.title } ?? same.first) : same.first
        }
        return (match(.ms), match(.er))
    }

    /// What to download for a spec, given what's cached already (doc id → present).
    public func downloadPlan(spec: Spec, cached: Set<String>, papers: Set<String>? = nil) -> [Doc] {
        let wanted = papers.map { ids in
            Set(spec.docs.filter { ids.contains($0.id) }.flatMap { qp -> [String] in
                let c = companions(of: qp, in: spec)
                return [qp.id, c.ms?.id, c.er?.id].compactMap { $0 }
            })
        }
        return spec.docs.filter { $0.type != .spec && !cached.contains($0.id) && (wanted?.contains($0.id) ?? true) }
    }

    /// "AQA 7408/2 June 2023 Q4.2", "OCR J249/1H June 2023 Q3": the source line shown on request.
    public func label(_ doc: Doc, in spec: Spec, question key: String) -> String {
        let board = board(spec.board)?.name ?? spec.board.uppercased()
        let tier = doc.tier.map { String($0.prefix(1)) } ?? ""
        let paper = doc.paper.map { "\(spec.code)/\($0)\(tier)" } ?? spec.code
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
    /// How far in from the margin a part ("(b)") may start.
    public static let partIndent = 72.0

    /// The page's left text margin: near the left of almost every line, ignoring a few stray bits further
    /// left (a barcode's digits, a vertical label on the cover).
    static func leftMargin(_ lines: [Line]) -> Double {
        let xs = lines.map(\.x).sorted()
        return xs.isEmpty ? 0 : xs[xs.count / 50]
    }

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
        let margin = leftMargin(ordered) + marginSlack
        var starts: [(index: Int, key: String)] = []
        // Parts ("1.2" after numberParts) may sit a little in from the margin, as OCR, WJEC and Cambridge print them.
        for (i, line) in ordered.enumerated() where line.x <= margin + partIndent {
            guard let g = groups(q, line.text), let k = key(g), starts.last?.key != k else { continue }
            if line.x <= margin || k.contains(".") { starts.append((i, k)) }
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
        return withStems(out)
    }

    /// A part carries the stems above it ("3 A drum floats…", then "(a) …" before "(i)"), so practising 3.1.2
    /// shows what it's about. A stem is an ancestor without marks of its own; touching regions join up.
    static func withStems(_ qs: [Question]) -> [Question] {
        var byKey: [String: Question] = [:]
        for q in qs where byKey[q.key] == nil { byKey[q.key] = q }
        return qs.map { q in
            var stems: [Question] = []
            var p = q.parent
            while let key = p {
                if let a = byKey[key], a.marks == nil { stems.insert(a, at: 0) }
                p = key.contains(".") ? String(key[..<key.lastIndex(of: ".")!]) : nil
            }
            guard !stems.isEmpty else { return q }
            var regions: [PageRegion] = []
            for r in stems.flatMap(\.regions) + q.regions {
                if let last = regions.last, last.page == r.page, last.rect.count == 4, r.rect.count == 4,
                   abs(last.rect[1] + last.rect[3] - r.rect[1]) < 2 {
                    regions[regions.count - 1].rect[3] = r.rect[1] + r.rect[3] - last.rect[1]
                } else if !regions.contains(r) {
                    regions.append(r)
                }
            }
            var out = q
            out.regions = regions
            out.text = (stems.map(\.text) + [q.text]).joined(separator: "\n")
            return out
        }
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

extension PaperSplitter {
    /// For your own PDFs (worksheets, textbook pages, competition papers), after `numberParts`:
    /// "1", "1.", "1)", "1.2"; marks as "[3]", "(3)", "[3 marks]", "(3 marks)" at a line's end.
    public static let uploadLayout = Catalogue.Layout(question: #"^(\d{1,2})(?:\.(\d{1,2}))?(?:\.(\d{1,2}))?[.)]?(?:\s|$)"#,
                                                      marks: #"[\[(](\d{1,2})(?: marks?)?[\])]\s*$"#,
                                                      scheme: #"^(\d{1,2})(?:\.(\d{1,2}))?(?:\.(\d{1,2}))?[.)]?(?:\s|$)"#, parts: true)

    /// Every board without its own layout (OCR, WJEC, Eduqas, Cambridge): numbered questions with lettered
    /// parts, "1 (a)", "1(a)(i)", "1. (a)", marks as "[2]" or "[2 marks]" at a line's end.
    public static let genericLayout = Catalogue.Layout(question: uploadLayout.question, marks: uploadLayout.marks,
                                                       scheme: uploadLayout.scheme, parts: true)

    /// Splits with the layout, running `numberParts` first when the layout asks for it.
    public static func splitPaper(_ lines: [Line], layout: Catalogue.Layout, pageHeight: Double = 842, pageWidth: Double = 595) -> [Question] {
        split(layout.parts == true ? numberParts(lines) : lines, layout: layout, pageHeight: pageHeight, pageWidth: pageWidth)
    }

    /// Splits with each layout and keeps the one that finds the most marks (then the most questions): a
    /// board can number its subjects differently (AQA's sciences "0 1 . 1", its maths "1 (a)").
    public static func splitBest(_ lines: [Line], layouts: [Catalogue.Layout], pageHeight: Double = 842, pageWidth: Double = 595)
        -> (questions: [Question], layout: Catalogue.Layout) {
        var best: (questions: [Question], layout: Catalogue.Layout, score: (Int, Int))?
        for layout in layouts {
            let qs = splitPaper(lines, layout: layout, pageHeight: pageHeight, pageWidth: pageWidth).filter { $0.marks != nil }
            let score = (qs.compactMap(\.marks).reduce(0, +), qs.count)
            if best == nil || score > best!.score { best = (qs, layout, score) }
        }
        if let best, best.score.0 > 0 { return (best.questions, best.layout) }
        // No marks printed anywhere: a multiple-choice paper (Cambridge's Paper 1, OCR's section A). Each
        // numbered question is worth 1 mark; its answer is the scheme's letter.
        let numbered = splitPaper(lines, layout: genericLayout, pageHeight: pageHeight, pageWidth: pageWidth).filter { $0.parent == nil }
        if numbered.count >= 10 {
            return (numbered.map { var q = $0; q.marks = 1; return q }, genericLayout)
        }
        return ([], genericLayout)
    }

    /// Mark-scheme entries, with the same numbering step as `splitPaper`.
    public static func schemePaper(_ lines: [Line], layout: Catalogue.Layout) -> [String: String] {
        scheme(layout.parts == true ? numberParts(lines, schemes: true) : lines, layout: layout)
    }

    /// Question numbers for the generic layout: "2(b)", "2 (b) (ii)", "2. (b)" and "2 b " become "2.2" and
    /// "2.2.2"; a part on its own line ("(b) Explain…", "(ii) …") belongs to the question above it. A bare
    /// number starts a question only at the left margin, when it comes next (or skips one, if a question
    /// wasn't read), and isn't followed by a lowercase word, so "3 kg of water" and page numbers stay text.
    /// In a mark scheme (`schemes`) "1ai" and "1(a)(i)" are keys too.
    public static func numberParts(_ lines: [PaperSplitter.Line], schemes: Bool = false) -> [PaperSplitter.Line] {
        let ordered = lines.sorted { ($0.page, $0.y, $0.x) < ($1.page, $1.y, $1.x) }
        let margin = leftMargin(ordered) + marginSlack
        let roman = #"(viii|vii|vi|iv|ix|v|x|iii|ii|i)"#
        let full = try! NSRegularExpression(pattern: #"^(?:Q\.?\s?)?(\d{1,2})\.?\s?\(([a-h])\)\s?(?:\("# + roman + #"\))?"#)
        let spaced = try! NSRegularExpression(pattern: #"^(?:Q\.?\s?)?(\d{1,2}) ([a-h])(?: \(?"# + roman + #"\)?)?(?=\s|$)"#)
        let compact = try! NSRegularExpression(pattern: #"^(\d{1,2})([a-h])"# + roman + #"?(?=\s|\(|$)"#)
        let partAlone = try! NSRegularExpression(pattern: #"^\(([a-h])\)\s?(?:\("# + roman + #"\))?(?=\s|$)"#)
        let romanAlone = try! NSRegularExpression(pattern: #"^\("# + roman + #"\)(?=\s|$)"#)
        let bare = try! NSRegularExpression(pattern: #"^(?:Q\.?\s?)?(\d{1,2})[.)*]?(?=\s|$)"#)
        let romans = ["i": 1, "ii": 2, "iii": 3, "iv": 4, "v": 5, "vi": 6, "vii": 7, "viii": 8, "ix": 9, "x": 10]
        var q = 0, part = 0
        func match(_ r: NSRegularExpression, _ t: String) -> (end: String.Index, groups: [String])? {
            let ns = t as NSString
            guard let m = r.firstMatch(in: t, range: NSRange(location: 0, length: ns.length)) else { return nil }
            let groups = (1..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? "" : ns.substring(with: m.range(at: $0)) }
            return (Range(m.range, in: t)!.upperBound, groups)
        }
        func letter(_ s: String) -> Int { Int((s.first?.asciiValue ?? 96) - 96) }
        func key(_ n: Int, _ p: Int, _ r: String) -> String { [n, p, romans[r] ?? 0].filter { $0 > 0 }.map(String.init).joined(separator: ".") }
        return ordered.map { line in
            var l = line
            let t = line.text
            if let m = match(full, t) ?? match(spaced, t) ?? (schemes ? match(compact, t) : nil), let n = Int(m.groups[0]),
               n == q || (n > q && n <= q + 2) || schemes {
                q = n; part = letter(m.groups[1])
                l.text = key(n, part, m.groups[2]) + " " + t[m.end...]
            } else if q > 0, let m = match(partAlone, t) {
                part = letter(m.groups[0])
                l.text = key(q, part, m.groups[1]) + " " + t[m.end...]
            } else if q > 0, part > 0, let m = match(romanAlone, t) {
                l.text = key(q, part, m.groups[0]) + " " + t[m.end...]
            } else if let m = match(bare, t), let n = Int(m.groups[0]) {
                let rest = t[m.end...].drop { $0 == " " }
                if line.x <= margin, n > q, n <= q + 2, !(rest.first?.isLowercase ?? false) {
                    q = n; part = 0
                    l.text = "\(n) " + rest
                } else {
                    l.text = "\u{200B}" + t
                }
            } else if t.first?.isNumber == true {
                l.text = "\u{200B}" + t // "5.6 × 10⁻³" at the margin is text, not question 5.6
            }
            return l
        }
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

/// The courses you've chosen (GCSE Physics with AQA, A-level Chemistry with OCR…). A record per course,
/// so the choice syncs to every device in the trove; the papers themselves are downloaded on each device.
public struct Course: Sendable, Equatable, Identifiable {
    public static let kind = "course"
    public var id: String
    public var spec: String
    /// "A-level Physics (7408)" with the board's name, for when the catalogue isn't loaded.
    public var name: String
    public var active: Bool
    public init(spec: String, name: String, active: Bool = true) {
        self.id = Self.id(spec); self.spec = spec; self.name = name; self.active = active
    }
    public init?(_ r: Record) {
        guard let spec = r.fields["spec"]?.string else { return nil }
        self.init(spec: spec, name: r.fields["name"]?.string ?? spec, active: r.fields["active"]?.bool ?? true)
    }
    public static func id(_ spec: String) -> String { "course.\(Develop.slug(spec))" }
    public var fields: [String: JSONValue] { ["spec": .string(spec), "name": .string(name), "active": .bool(active)] }
}

extension Library {
    /// Adds or removes a course; removing keeps the record (inactive) so the choice syncs.
    public func setCourse(_ course: Course) async {
        await engine.set(course.fields, record: course.id, kind: Course.kind)
    }

    /// Chosen courses, by name.
    public func courses() async -> [Course] {
        await engine.records(kind: Course.kind).compactMap(Course.init).filter(\.active).sorted { $0.name < $1.name }
    }
}
