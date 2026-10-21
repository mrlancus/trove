import Foundation

/// A folder as `in:` sees it.
public struct SearchFolder: Sendable, Equatable, Codable {
    public var name: String
    public var parent: String?
    public init(name: String, parent: String?) { self.name = name; self.parent = parent }
}

/// Local full-text search: BM25 over weighted fields, the last word as a prefix, typo tolerance for
/// longer words, "phrases", operators (SearchQuery) and snippets. Built on each device from synced
/// content and never synced itself (RESEARCH.md §3); it can be saved next to the vault snapshot and
/// loaded again, re-indexing only what changed (`snapshot()` / `restore`). "Search by meaning" ranks
/// are fused in with reciprocal rank fusion (`semantic:`). Mirrors web/public/core/search.js.
public struct SearchIndex: Sendable {
    var engine = TermIndex()
    private var items: [String: Item] = [:]
    /// Folders by id, for `in:<folder name>` (and the folders inside it).
    public var folders: [String: SearchFolder] = [:]
    /// Items with ink drawn on them (strokes are separate records), for `has:ink`.
    public var inked: Set<String> = []

    public init() {}

    public var count: Int { engine.count }
    public func contains(_ id: String) -> Bool { engine.docs[id] != nil }

    /// The searchable fields of an item and their weights, in scoring order (core/search.js ITEM_FIELDS).
    static func fields(_ item: Item) -> [(String, Double)] {
        [(item.title, 3), (item.tags.joined(separator: " "), 2.5), (item.summary ?? "", 1.5), (item.siteName ?? "", 1.5), (item.body, 1),
         (item.ocrText ?? "", 1), (item.sketchText ?? "", 1), (item.inkText ?? "", 1), (item.url?.host ?? "", 1)]
    }

    public mutating func update(_ item: Item) {
        remove(item.id)
        guard !item.record.isDeleted else { return }
        insert(item, terms: TermIndex.weigh(Self.fields(item)))
    }

    private mutating func insert(_ item: Item, terms: [String: Double]) {
        let doc = TermIndex.Doc(v: item.record.updatedHLC, terms: terms, length: TermIndex.length(terms),
                                createdAt: item.record[Field.createdAt]?.number ?? 0, pinned: item.isPinned,
                                title: Array(Set(Tokenizer.terms(item.title))).sorted())
        engine.insert(item.id, doc)
        items[item.id] = item
    }

    /// Sorts the vocabulary after updates. Cheap when nothing changed; call it before handing the
    /// index to the UI so every keystroke's search is a few lookups.
    public mutating func prepare() { engine.prepare() }

    public mutating func remove(_ id: String) {
        engine.remove(id)
        items[id] = nil
    }

    public struct Hit: Sendable, Equatable {
        public var item: Item
        public var score: Double
    }

    /// Items matching `query`, best first. `semantic`: item id → similarity (already thresholded) from
    /// "search by meaning"; its ranking is fused with the keyword ranking (reciprocal rank fusion).
    public func search(_ query: SearchQuery, semantic: [String: Double] = [:], limit: Int = 100, now: Date = Date()) -> [Hit] {
        searchWithTotal(query, semantic: semantic, limit: limit, now: now).hits
    }

    /// Like `search`, with how many items matched in all.
    public func searchWithTotal(_ query: SearchQuery, semantic: [String: Double] = [:], limit: Int = 100, now: Date = Date()) -> (hits: [Hit], total: Int) {
        let plan = self.plan(query)
        let folders = self.folders, inked = self.inked, items = self.items
        let passes: (String, TermIndex.Doc) -> Bool = { id, doc in
            for t in plan.exclude where doc.terms[t] != nil { return false }
            guard let item = items[id], query.matches(item, folders: folders, inked: inked) else { return false }
            for p in plan.excludePhrases where Self.hasPhrase(item, p) { return false }
            return true
        }
        let hasPhrase: (String, [String]) -> Bool = { id, phrase in items[id].map { Self.hasPhrase($0, phrase) } ?? false }
        let nowMs = now.timeIntervalSince1970 * 1000
        guard !semantic.isEmpty else {
            let (ranked, total) = engine.search(plan, now: nowMs, limit: limit, passes: passes, hasPhrase: hasPhrase)
            return (ranked.compactMap { r in items[r.id].map { Hit(item: $0, score: r.score) } }, total)
        }
        let keywords = engine.search(plan, now: nowMs, limit: Int.max, passes: passes, hasPhrase: hasPhrase)
        let byMeaning = semantic.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
        var meaning: [String] = []
        for (id, _) in byMeaning where meaning.count < 200 {
            if let doc = engine.docs[id], passes(id, doc) { meaning.append(id) }
        }
        let fused = RankFusion.reciprocal([keywords.ranked.prefix(max(limit, 200)).map(\.id), meaning])
        let total = Set(keywords.ranked.map(\.id)).union(meaning).count
        return (fused.prefix(limit).compactMap { id in items[id].map { Hit(item: $0, score: 0) } }, total)
    }

    func plan(_ query: SearchQuery) -> TermIndex.Plan {
        engine.plan(text: query.text, phrases: query.phrases, title: query.title, exclude: query.exclude, excludePhrases: query.excludePhrases)
    }

    static func hasPhrase(_ item: Item, _ phrase: [String]) -> Bool {
        TermIndex.contains(phrase, in: fields(item).map(\.0))
    }

    /// Where a snippet may come from, in order of preference (core/search.js SNIPPET_FIELDS).
    static func snippetFields(_ item: Item) -> [(String, String)] {
        [("body", item.body), ("ocr", item.ocrText ?? ""), ("ink", item.inkText ?? ""), ("sketch", item.sketchText ?? ""), ("summary", item.summary ?? "")]
    }

    /// The passage of a result around its first matching word, with every matching word marked.
    public func snippet(for id: String, query: SearchQuery, width: Int = 160) -> SearchSnippet? {
        guard let doc = engine.docs[id], let item = items[id] else { return nil }
        var words = Set<String>()
        for x in plan(query).matchers { for (t, _) in engine.matched(doc, x.matcher) { words.insert(t) } }
        guard !words.isEmpty else { return nil }
        for (field, text) in Self.snippetFields(item) {
            if let s = SearchSnippet.make(text, words: words, width: width) { return SearchSnippet(field: field, text: s.text, ranges: s.ranges) }
        }
        return nil
    }

    // MARK: Saving

    /// What's worth saving: each item's version and weighted terms (items themselves come from the vault).
    public struct Snapshot: Codable, Sendable, Equatable {
        public var format: Int
        var docs: [String: TermIndex.Doc]
    }

    public func snapshot() -> Snapshot { Snapshot(format: Self.snapshotFormat, docs: engine.docs) }

    static let snapshotFormat = 1

    /// Loads a saved index for `items`: items whose version is unchanged reuse their saved terms, the
    /// rest are indexed again. Returns how many were (re)indexed.
    @discardableResult
    public mutating func restore(_ snapshot: Snapshot, items: [Item]) -> Int {
        engine = TermIndex()
        self.items = [:]
        var fresh = 0
        for item in items where !item.record.isDeleted {
            if snapshot.format == Self.snapshotFormat, let doc = snapshot.docs[item.id], doc.v == item.record.updatedHLC {
                engine.insert(item.id, doc)
                self.items[item.id] = item
            } else {
                update(item)
                fresh += 1
            }
        }
        engine.prepare()
        return fresh
    }
}

/// A result's matching passage: `ranges` are offsets in Unicode scalars into `text`.
public struct SearchSnippet: Sendable, Equatable {
    /// body, ocr (file or picture text), ink (handwriting), sketch (text on a sketch) or summary.
    public var field: String
    public var text: String
    public var ranges: [Range<Int>]

    public init(field: String, text: String, ranges: [Range<Int>]) { self.field = field; self.text = text; self.ranges = ranges }

    /// The marked words, in order.
    public var highlights: [String] {
        let scalars = Array(text.unicodeScalars)
        return ranges.map { r in
            var s = String.UnicodeScalarView()
            s.append(contentsOf: scalars[r])
            return String(s)
        }
    }

    static func isWord(_ s: Unicode.Scalar) -> Bool {
        switch s.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter, .decimalNumber, .letterNumber, .otherNumber: return true
        default: return false
        }
    }

    /// A short passage of `text` around the first word whose term is in `words`, every such word marked.
    /// Whitespace runs become one space; "…" marks cut ends (core/search.js `snippet`).
    public static func make(_ text: String, words: Set<String>, width: Int = 160) -> (text: String, ranges: [Range<Int>])? {
        let s = Array(text.unicodeScalars)
        func spans(_ from: Int, _ to: Int, stopAtFirst: Bool) -> [Range<Int>] {
            var out: [Range<Int>] = []
            var i = from
            while i < to {
                guard isWord(s[i]) else { i += 1; continue }
                var j = i
                while j < to, isWord(s[j]) { j += 1 }
                var w = String.UnicodeScalarView()
                w.append(contentsOf: s[i..<j])
                if let t = Tokenizer.terms(String(w)).first, words.contains(t) {
                    out.append(i..<j)
                    if stopAtFirst { return out }
                }
                i = j
            }
            return out
        }
        guard let first = spans(0, s.count, stopAtFirst: true).first else { return nil }
        var start = max(0, first.lowerBound - 40)
        if start > 0 {
            if isWord(s[start - 1]) { while start < first.lowerBound, isWord(s[start]) { start += 1 } }
            while start < first.lowerBound, !isWord(s[start]) { start += 1 }
        }
        var end = min(s.count, start + width)
        if end < s.count { while end > first.upperBound, isWord(s[end]), isWord(s[end - 1]) { end -= 1 } }
        // Collapse whitespace, mapping offsets in the slice to offsets in the output.
        var out: [Unicode.Scalar] = []
        var map = [Int](repeating: 0, count: end - start + 1)
        var lastSpace = false
        for k in start..<end {
            map[k - start] = out.count
            if s[k].properties.isWhitespace {
                if !lastSpace { out.append(" ") }
                lastSpace = true
            } else {
                out.append(s[k])
                lastSpace = false
            }
        }
        map[end - start] = out.count
        let lead = out.first == " " ? 1 : 0
        if lead == 1 { out.removeFirst() }
        if out.last == " " { out.removeLast() }
        let before = start > 0 ? 1 : 0
        let ranges = spans(start, end, stopAtFirst: false).map { r in
            (map[r.lowerBound - start] - lead + before)..<(map[r.upperBound - start] - lead + before)
        }
        var view = String.UnicodeScalarView()
        if before == 1 { view.append("…") }
        view.append(contentsOf: out)
        if end < s.count { view.append("…") }
        return (String(view), ranges)
    }
}

public enum Tokenizer {
    static let stopwords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "but", "by", "for", "from", "has", "have", "i", "in", "is", "it", "its",
        "of", "on", "or", "that", "the", "this", "to", "was", "were", "will", "with", "you", "your", "my", "me", "we",
    ]

    public static func terms(_ text: String) -> [String] {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        var out: [String] = []
        var current = ""
        func flush() {
            if !current.isEmpty, !stopwords.contains(current), current.count > 1 || current.allSatisfy(\.isNumber) { out.append(stem(current)) }
            current = ""
        }
        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) { current.unicodeScalars.append(scalar) } else { flush() }
        }
        flush()
        return out
    }

    /// Very light English stemming so "recipes" finds "recipe" and "boxes" finds "box".
    static func stem(_ w: String) -> String {
        guard w.count > 3, w.allSatisfy(\.isLetter) else { return w }
        if w.hasSuffix("ies"), w.count > 4 { return String(w.dropLast(3)) + "y" }
        for suffix in ["sses", "ches", "shes", "xes", "zes"] where w.hasSuffix(suffix) { return String(w.dropLast(2)) }
        if w.hasSuffix("s"), !w.hasSuffix("ss"), !w.hasSuffix("us"), !w.hasSuffix("is") { return String(w.dropLast()) }
        return w
    }
}

/// Parsed search box input: free words, `"phrases"`, `-word` / `-"phrase"` to exclude, `#tag` or `tag:x`,
/// `title:x`, `in:<collection id, folder id or folder name>`, `type:pdf`, `from:kindle`, `has:ink|audio|file|link`,
/// `is:pinned|unread|<category>`, `before:` / `after:` with `2026`, `2026-01` or `2026-01-31` (UTC).
/// `key:"quoted value"` keeps spaces. Same rules as core/search.js `parseQuery`.
public struct SearchQuery: Sendable, Equatable {
    public var text: String = ""
    public var phrases: [[String]] = []
    public var title: [String] = []
    public var exclude: [String] = []
    public var excludePhrases: [[String]] = []
    public var kinds: Set<ItemKind> = []
    public var categories: Set<ItemCategory> = []
    public var tags: Set<String> = []
    public var sources: Set<ItemSource> = []
    public var collection: String?
    public var space: String?
    public var has: Set<String> = []
    public var pinnedOnly = false
    public var unreadOnly = false
    public var after: Date?
    public var before: Date?

    public init(text: String = "") { self.text = text }

    static let sourceNames: [ItemSource] = [.app, .share, .web, .email, .goodnotes, .kindle, .readwise, .obsidian, .appleNotes, .notion,
                                           .screenshot, .voice, .scan, .import, .clipboard]
    static let hasNames: Set<String> = ["ink", "audio", "file", "link"]

    /// Whether it asks for words (as opposed to only filters).
    public var hasWords: Bool { !Tokenizer.terms(text).isEmpty || !phrases.isEmpty || !title.isEmpty }

    struct Token { var neg: Bool; var phrase: String?; var raw: String }

    /// Words, `"phrases"`, `key:"quoted values"`, and `-` for excluding.
    static func tokens(_ input: String) -> [Token] {
        let c = Array(input)
        let n = c.count
        func space(_ ch: Character) -> Bool { ch == " " || ch == "\t" || ch == "\n" }
        func closing(_ from: Int) -> Int? {
            var k = from
            while k < n { if c[k] == "\"" { return k }; k += 1 }
            return nil
        }
        var out: [Token] = []
        var i = 0
        while i < n {
            if space(c[i]) { i += 1; continue }
            var neg = false
            if c[i] == "-", i + 1 < n, !space(c[i + 1]) { neg = true; i += 1 }
            if c[i] == "\"" {
                let j = closing(i + 1) ?? n
                out.append(Token(neg: neg, phrase: String(c[(i + 1)..<j]), raw: ""))
                i = j + 1
                continue
            }
            var j = i
            while j < n, !space(c[j]) {
                if c[j] == "\"" { j = (closing(j + 1) ?? (n - 1)) + 1 } else { j += 1 }
            }
            out.append(Token(neg: neg, phrase: nil, raw: String(c[i..<j])))
            i = j
        }
        return out
    }

    /// `2026`, `2026-01` or `2026-01-31` → the start of that year, month or day (UTC).
    public static func day(_ value: String) -> Date? {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard (1...3).contains(parts.count), parts[0].count == 4, let y = Int(parts[0]), parts[0].allSatisfy(\.isASCII) else { return nil }
        var month = 1, day = 1
        if parts.count > 1 {
            guard (1...2).contains(parts[1].count), parts[1].allSatisfy({ $0.isASCII && $0.isNumber }), let m = Int(parts[1]) else { return nil }
            month = m
        }
        if parts.count > 2 {
            guard (1...2).contains(parts[2].count), parts[2].allSatisfy({ $0.isASCII && $0.isNumber }), let d = Int(parts[2]) else { return nil }
            day = d
        }
        guard (1...12).contains(month), (1...31).contains(day) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        // Like Date.UTC, a day past the month's end rolls over into the next month.
        guard let first = calendar.date(from: DateComponents(year: y, month: month, day: 1)) else { return nil }
        return first.addingTimeInterval(Double(day - 1) * 86_400)
    }

    public static func parse(_ input: String) -> SearchQuery {
        var q = SearchQuery()
        var free: [String] = []
        for t in tokens(input) {
            if let phrase = t.phrase {
                let words = Tokenizer.terms(phrase)
                if t.neg { if words.count > 1 { q.excludePhrases.append(words) } else { q.exclude += words } } else if !words.isEmpty { q.phrases.append(words) }
                continue
            }
            let token = t.raw
            if t.neg { q.exclude += Tokenizer.terms(token); continue }
            if token.hasPrefix("#"), token.count > 1 { q.tags.insert(token.dropFirst().lowercased()); continue }
            guard let colon = token.firstIndex(of: ":"), colon > token.startIndex else { free.append(token); continue }
            let key = token[..<colon].lowercased()
            let rawValue = token[token.index(after: colon)...].replacingOccurrences(of: "\"", with: "")
            let value = rawValue.lowercased()
            guard !value.isEmpty else { free.append(token); continue }
            switch key {
            case "tag": q.tags.insert(value.replacingOccurrences(of: "#", with: ""))
            case "type", "kind":
                if let k = ItemKind(rawValue: value) { q.kinds.insert(k) } else if let c = ItemCategory(rawValue: value) { q.categories.insert(c) }
            case "is":
                if value == "pinned" { q.pinnedOnly = true } else if value == "unread" { q.unreadOnly = true }
                else if let c = ItemCategory(rawValue: value) { q.categories.insert(c) }
            case "from", "source":
                if let s = sourceNames.first(where: { $0.rawValue.lowercased() == value }) { q.sources.insert(s) } else { free.append(token) }
            case "in": q.collection = rawValue
            case "title": q.title += Tokenizer.terms(rawValue)
            case "has" where hasNames.contains(value): q.has.insert(value)
            case "before": q.before = day(value)
            case "after": q.after = day(value)
            default: free.append(token)
            }
        }
        q.text = free.joined(separator: " ")
        return q
    }

    /// What `has:` sees in an item.
    public static func has(_ item: Item, inked: Bool = false) -> Set<String> {
        var out: Set<String> = []
        if inked || item.kind == .sketch || !(item.inkText ?? "").isEmpty || item.sources.contains(.goodnotes) || !item.goodnotesInk.isEmpty { out.insert("ink") }
        if item.kind == .audio || item.attachments.contains(where: { $0.mime.hasPrefix("audio/") }) { out.insert("audio") }
        if !item.attachments.isEmpty { out.insert("file") }
        if item.url != nil { out.insert("link") }
        return out
    }

    /// `in:` a folder: the item's folder, or one it's inside, has that id or name.
    static func inFolder(_ value: String, folder: String?, folders: [String: SearchFolder]) -> Bool {
        guard var id = folder else { return false }
        let want = Tokenizer.terms(value).joined(separator: " ")
        for _ in 0..<32 {
            if id == value { return true }
            guard let f = folders[id] else { return false }
            if !want.isEmpty, Tokenizer.terms(f.name).joined(separator: " ") == want { return true }
            guard let parent = f.parent else { return false }
            id = parent
        }
        return false
    }

    public func matches(_ item: Item) -> Bool { matches(item, folders: [:], inked: []) }

    public func matches(_ item: Item, folders: [String: SearchFolder], inked: Set<String>) -> Bool {
        if !kinds.isEmpty, !kinds.contains(item.kind) { return false }
        if !categories.isEmpty, !categories.contains(item.category) { return false }
        if !tags.isEmpty, !tags.isSubset(of: Set(item.tags.map { $0.lowercased() })) { return false }
        if !sources.isEmpty, sources.isDisjoint(with: item.sources) { return false }
        if let collection, !item.collections.contains(collection), !Self.inFolder(collection, folder: item.folder, folders: folders) { return false }
        if let space, item.space != space { return false }
        if pinnedOnly, !item.isPinned { return false }
        if unreadOnly, item.readAt != nil { return false }
        let created = item.record[Field.createdAt]?.number ?? 0
        if let after, created < after.timeIntervalSince1970 * 1000 { return false }
        if let before, created >= before.timeIntervalSince1970 * 1000 { return false }
        if !has.isEmpty, !has.isSubset(of: Self.has(item, inked: inked.contains(item.id))) { return false }
        return true
    }
}
