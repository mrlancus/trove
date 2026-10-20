import Foundation

/// Local full-text search (BM25 over weighted fields, prefix matching on the last word, filters).
/// Built on each device from synced content and never synced itself (RESEARCH.md §3). The app can
/// blend in semantic scores (NLEmbedding / embeddings) via `semantic:`.
public struct SearchIndex: Sendable {
    struct Doc: Sendable {
        var terms: [String: Double]   // weighted term frequency
        var length: Double
        var item: Item
    }

    private var docs: [String: Doc] = [:]
    private var postings: [String: Set<String>] = [:]
    private var totalLength: Double = 0
    /// Every term, sorted, so the words that start with what's typed are a binary search away.
    /// Rebuilt by `prepare()` after changes; until then prefixes fall back to a scan.
    private var vocabulary: [String] = []
    private var vocabularyStale = false

    public init() {}

    public var count: Int { docs.count }
    public func contains(_ id: String) -> Bool { docs[id] != nil }

    public mutating func update(_ item: Item) {
        remove(item.id)
        guard !item.record.isDeleted else { return }
        var terms: [String: Double] = [:]
        func add(_ text: String, weight: Double) {
            for t in Tokenizer.terms(text) { terms[t, default: 0] += weight }
        }
        add(item.title, weight: 3)
        add(item.tags.joined(separator: " "), weight: 2.5)
        add(item.summary ?? "", weight: 1.5)
        add(item.siteName ?? "", weight: 1.5)
        add(item.body, weight: 1)
        add(item.ocrText ?? "", weight: 1)
        add(item.sketchText ?? "", weight: 1)
        add(item.inkText ?? "", weight: 1)
        add(item.url?.host ?? "", weight: 1)
        let length = terms.values.reduce(0, +)
        docs[item.id] = Doc(terms: terms, length: length, item: item)
        totalLength += length
        for t in terms.keys {
            if postings[t] == nil { vocabularyStale = true }
            postings[t, default: []].insert(item.id)
        }
    }

    /// Sorts the vocabulary after updates. Cheap when nothing changed; call it before handing the
    /// index to the UI so every keystroke's search is a few lookups.
    public mutating func prepare() {
        guard vocabularyStale else { return }
        vocabulary = postings.keys.sorted()
        vocabularyStale = false
    }

    /// Terms starting with `prefix` (the term itself included).
    func terms(withPrefix prefix: String) -> [String] {
        if vocabularyStale { return postings.keys.filter { $0.hasPrefix(prefix) } }
        var lo = 0, hi = vocabulary.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if vocabulary[mid] < prefix { lo = mid + 1 } else { hi = mid }
        }
        var out: [String] = []
        while lo < vocabulary.count, vocabulary[lo].hasPrefix(prefix) {
            if postings[vocabulary[lo]] != nil { out.append(vocabulary[lo]) }
            lo += 1
        }
        return out
    }

    public mutating func remove(_ id: String) {
        guard let old = docs.removeValue(forKey: id) else { return }
        totalLength -= old.length
        for t in old.terms.keys {
            postings[t]?.remove(id)
            if postings[t]?.isEmpty == true { postings[t] = nil; vocabularyStale = true }
        }
    }

    public struct Hit: Sendable, Equatable {
        public var item: Item
        public var score: Double
    }

    public func search(_ query: SearchQuery, semantic: [String: Double] = [:], limit: Int = 100) -> [Hit] {
        let words = Tokenizer.terms(query.text)
        // The last word may be a prefix ("rec" → recipe): the words it could be, found once.
        let lastPrefix: [String] = words.last.map { w in w.count >= 2 ? terms(withPrefix: w) : [w] } ?? []
        let candidates: [(String, Doc)]
        if words.isEmpty {
            candidates = docs.map { ($0.key, $0.value) }
        } else {
            // A doc must match every word.
            var common: Set<String>?
            for (i, w) in words.enumerated() {
                var ids = postings[w] ?? []
                if i == words.count - 1 { for term in lastPrefix { ids.formUnion(postings[term] ?? []) } }
                common = common.map { $0.intersection(ids) } ?? ids
                if common?.isEmpty == true { break }
            }
            var ids = common ?? []
            for (id, score) in semantic where score > 0.35 { ids.insert(id) }
            candidates = ids.compactMap { id in docs[id].map { (id, $0) } }
        }

        let n = Double(max(docs.count, 1))
        let avg = totalLength / n
        var hits: [Hit] = []
        hits.reserveCapacity(candidates.count)
        for (id, doc) in candidates where query.matches(doc.item) {
            var score = 0.0
            for (i, w) in words.enumerated() {
                var matched: [(String, Double)] = doc.terms[w].map { [(w, $0)] } ?? []
                if matched.isEmpty, i == words.count - 1 {
                    matched = lastPrefix.compactMap { term in doc.terms[term].map { (term, $0 * 0.7) } }
                }
                for (term, tf) in matched {
                    let df = Double(postings[term]?.count ?? 1)
                    let idf = log(1 + (n - df + 0.5) / (df + 0.5))
                    score += idf * (tf * 2.2) / (tf + 1.2 * (0.25 + 0.75 * doc.length / max(avg, 1)))
                }
            }
            score += (semantic[id] ?? 0) * 4
            if doc.item.isPinned { score += 0.25 }
            // Gentle recency tie-breaker: up to +0.5 for items from the last month.
            let age = -doc.item.createdAt.timeIntervalSinceNow / 86_400
            score += max(0, 0.5 - age / 60)
            hits.append(Hit(item: doc.item, score: score))
        }
        if words.isEmpty {
            hits.sort { $0.item.createdAt > $1.item.createdAt }
        } else {
            hits.sort { $0.score != $1.score ? $0.score > $1.score : $0.item.createdAt > $1.item.createdAt }
        }
        return Array(hits.prefix(limit))
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

/// Parsed search box input. Supports `tag:x`, `type:pdf`, `is:pinned`, `is:unread`, `from:kindle`,
/// `in:<collection id>`, `before:2026-01-01`, `after:2025-12-01`; everything else is free text.
public struct SearchQuery: Sendable, Equatable {
    public var text: String = ""
    public var kinds: Set<ItemKind> = []
    public var categories: Set<ItemCategory> = []
    public var tags: Set<String> = []
    public var sources: Set<ItemSource> = []
    public var collection: String?
    public var space: String?
    public var pinnedOnly = false
    public var unreadOnly = false
    public var after: Date?
    public var before: Date?

    public init(text: String = "") { self.text = text }

    public static func parse(_ input: String) -> SearchQuery {
        var q = SearchQuery()
        var free: [String] = []
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.dateFormat = "yyyy-MM-dd"
        for token in input.split(separator: " ") {
            let parts = token.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, !parts[1].isEmpty else { free.append(String(token)); continue }
            let value = parts[1].lowercased()
            switch parts[0].lowercased() {
            case "tag": q.tags.insert(value.replacingOccurrences(of: "#", with: ""))
            case "type", "kind":
                if let k = ItemKind(rawValue: value) { q.kinds.insert(k) } else if let c = ItemCategory(rawValue: value) { q.categories.insert(c) }
            case "is":
                if value == "pinned" { q.pinnedOnly = true } else if value == "unread" { q.unreadOnly = true }
                else if let c = ItemCategory(rawValue: value) { q.categories.insert(c) }
            case "from", "source": if let s = ItemSource(rawValue: value) { q.sources.insert(s) } else { free.append(String(token)) }
            case "in": q.collection = parts[1]
            case "before": q.before = day.date(from: value)
            case "after": q.after = day.date(from: value)
            default: free.append(String(token))
            }
        }
        q.text = free.joined(separator: " ")
        return q
    }

    public func matches(_ item: Item) -> Bool {
        if !kinds.isEmpty, !kinds.contains(item.kind) { return false }
        if !categories.isEmpty, !categories.contains(item.category) { return false }
        if !tags.isEmpty, !tags.isSubset(of: Set(item.tags.map { $0.lowercased() })) { return false }
        if !sources.isEmpty, sources.isDisjoint(with: item.sources) { return false }
        if let collection, !item.collections.contains(collection) { return false }
        if let space, item.space != space { return false }
        if pinnedOnly, !item.isPinned { return false }
        if unreadOnly, item.readAt != nil { return false }
        if let after, item.createdAt < after { return false }
        if let before, item.createdAt >= before { return false }
        return true
    }
}
