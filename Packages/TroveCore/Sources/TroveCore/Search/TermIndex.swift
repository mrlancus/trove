import Foundation

/// The engine under `SearchIndex` (items) and `ClipIndex` (clips): postings (term → doc ids), a sorted
/// vocabulary for prefixes, typo matching, BM25 over weighted terms. Mirrors web/public/core/search.js
/// `TermIndex`; Fixtures/search-cases.json keeps the two in step (same matches, same order).
struct TermIndex: Sendable {
    struct Doc: Sendable, Codable, Equatable {
        var v: String
        var terms: [String: Double]
        var length: Double
        /// Epoch milliseconds, as stored in the record.
        var createdAt: Double
        var pinned: Bool
        var title: [String]
    }

    /// What one query word can match: itself, longer words starting with it, or words one typo away.
    struct Matcher: Sendable {
        var word: String
        var exact: Bool
        var prefix: [String]
        var near: [String]
        var prefixSet: Set<String>
        var nearSet: Set<String>
        var estimate: Int
    }

    struct Planned: Sendable {
        var matcher: Matcher
        var title: Bool
    }

    struct Plan: Sendable {
        var matchers: [Planned]
        var exclude: [String]
        var excludePhrases: [[String]]
        var phrases: [[String]]
    }

    /// At most this many longer words stand in for a prefix (the most common ones), as on the website.
    static let maxPrefixTerms = 64

    private(set) var docs: [String: Doc] = [:]
    private(set) var postings: [String: Set<String>] = [:]
    private(set) var totalLength: Double = 0
    private var vocabulary: [String] = []
    private var byLength: [Int: [String]] = [:]
    private var stale = false

    var count: Int { docs.count }

    /// Weighted term frequencies of `(text, weight)` fields.
    static func weigh(_ fields: [(String, Double)]) -> [String: Double] {
        var terms: [String: Double] = [:]
        for (text, weight) in fields where !text.isEmpty {
            for t in Tokenizer.terms(text) { terms[t, default: 0] += weight }
        }
        return terms
    }

    static func length(_ terms: [String: Double]) -> Double {
        // Weights are multiples of 0.5, so the sum is exact in any order.
        terms.values.reduce(0, +)
    }

    mutating func insert(_ id: String, _ doc: Doc) {
        remove(id)
        docs[id] = doc
        totalLength += doc.length
        for t in doc.terms.keys {
            if postings[t] == nil { stale = true }
            postings[t, default: []].insert(id)
        }
    }

    mutating func remove(_ id: String) {
        guard let old = docs.removeValue(forKey: id) else { return }
        totalLength -= old.length
        for t in old.terms.keys {
            postings[t]?.remove(id)
            if postings[t]?.isEmpty == true { postings[t] = nil; stale = true }
        }
    }

    /// Sorts the vocabulary after changes. Cheap when nothing changed; until then prefixes and typos fall back to a scan.
    mutating func prepare() {
        guard stale else { return }
        vocabulary = postings.keys.sorted()
        byLength = Dictionary(grouping: vocabulary) { $0.unicodeScalars.count }
        stale = false
    }

    /// Vocabulary terms starting with `prefix`, without `prefix` itself, sorted.
    func terms(withPrefix prefix: String) -> [String] {
        if stale { return postings.keys.filter { $0 != prefix && $0.hasPrefix(prefix) }.sorted() }
        var lo = 0, hi = vocabulary.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if vocabulary[mid] < prefix { lo = mid + 1 } else { hi = mid }
        }
        var out: [String] = []
        while lo < vocabulary.count, vocabulary[lo].hasPrefix(prefix) {
            if vocabulary[lo] != prefix { out.append(vocabulary[lo]) }
            lo += 1
        }
        return out
    }

    /// Vocabulary terms one edit away from `word`, sorted.
    func nearby(_ word: String) -> [String] {
        let n = word.unicodeScalars.count
        var out: [String] = []
        for len in [n - 1, n, n + 1] {
            let bucket = stale ? postings.keys.filter { $0.unicodeScalars.count == len } : (byLength[len] ?? [])
            for t in bucket where Self.withinOneEdit(word, t) { out.append(t) }
        }
        return out.sorted()
    }

    /// Whether two words are at most one edit apart (insert, delete, substitute or swap two neighbours).
    static func withinOneEdit(_ a: String, _ b: String) -> Bool {
        let x = Array(a.unicodeScalars), y = Array(b.unicodeScalars)
        if abs(x.count - y.count) > 1 { return false }
        var i = 0
        while i < x.count, i < y.count, x[i] == y[i] { i += 1 }
        func rest(_ p: Int, _ q: Int) -> Bool {
            guard x.count - p == y.count - q else { return false }
            var k = 0
            while p + k < x.count { if x[p + k] != y[q + k] { return false }; k += 1 }
            return true
        }
        if x.count == y.count {
            if i == x.count { return true }
            if rest(i + 1, i + 1) { return true }
            return i + 1 < x.count && x[i] == y[i + 1] && x[i + 1] == y[i] && rest(i + 2, i + 2)
        }
        return x.count < y.count ? rest(i, i + 1) : rest(i + 1, i)
    }

    func matcher(_ word: String, prefix: Bool = false, fuzzy: Bool = true) -> Matcher {
        let exact = postings[word] != nil
        var pre = prefix && word.unicodeScalars.count >= 2 ? terms(withPrefix: word) : []
        if pre.count > Self.maxPrefixTerms {
            // A short start of a word ("re") could be thousands of words: the most common ones stand in for them.
            let counted = pre.map { ($0, postings[$0]?.count ?? 0) }
            let common = counted.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
            pre = common.prefix(Self.maxPrefixTerms).map(\.0).sorted()
        }
        let near = fuzzy && !exact && pre.isEmpty && word.unicodeScalars.count >= 5 ? nearby(word) : []
        var estimate = exact ? (postings[word]?.count ?? 0) : 0
        for t in pre { estimate += postings[t]?.count ?? 0 }
        for t in near { estimate += postings[t]?.count ?? 0 }
        return Matcher(word: word, exact: exact, prefix: pre, near: near, prefixSet: Set(pre), nearSet: Set(near), estimate: estimate)
    }

    /// The terms of `doc` a matcher matched, with their weight (1 exact, 0.7 prefix, 0.5 typo), in order.
    func matched(_ doc: Doc, _ m: Matcher) -> [(String, Double)] {
        if m.exact, doc.terms[m.word] != nil { return [(m.word, 1)] }
        var out: [(String, Double)] = []
        for t in m.prefix where doc.terms[t] != nil { out.append((t, 0.7)) }
        if !out.isEmpty { return out }
        for t in m.near where doc.terms[t] != nil { out.append((t, 0.5)) }
        return out
    }

    func has(_ doc: Doc, _ m: Matcher) -> Bool {
        if m.exact, doc.terms[m.word] != nil { return true }
        for t in m.prefix where doc.terms[t] != nil { return true }
        for t in m.near where doc.terms[t] != nil { return true }
        return false
    }

    func inTitle(_ doc: Doc, _ m: Matcher) -> Bool {
        doc.title.contains { $0 == m.word || m.prefixSet.contains($0) || m.nearSet.contains($0) }
    }

    /// Free words (the last one, or all with `prefixAll`, may be the start of a word), phrase words and title words; 30 at most.
    func plan(text: String, phrases: [[String]] = [], title: [String] = [], exclude: [String] = [], excludePhrases: [[String]] = [],
              prefixAll: Bool = false) -> Plan {
        let words = Tokenizer.terms(text)
        var ms: [Planned] = []
        for (i, w) in words.enumerated() { ms.append(Planned(matcher: matcher(w, prefix: prefixAll || i == words.count - 1), title: false)) }
        for phrase in phrases { for w in phrase { ms.append(Planned(matcher: matcher(w, fuzzy: false), title: false)) } }
        for w in title { ms.append(Planned(matcher: matcher(w, prefix: true), title: true)) }
        return Plan(matchers: Array(ms.prefix(30)), exclude: exclude, excludePhrases: excludePhrases, phrases: phrases)
    }

    struct Ranked: Sendable {
        var id: String
        var score: Double
        var createdAt: Double
    }

    /// Scores only the docs that hold every word. `passes` applies filters and exclusions; `hasPhrase`
    /// checks a phrase word for word. Returns the best `limit` in order and how many matched.
    func search(_ plan: Plan, now: Double, limit: Int, passes: (String, Doc) -> Bool, hasPhrase: (String, [String]) -> Bool) -> (ranked: [Ranked], total: Int) {
        let n = Double(max(docs.count, 1))
        let avg = max(totalLength / n, 1)
        var found: [Ranked] = []
        let ms = plan.matchers
        if ms.isEmpty {
            for (id, doc) in docs where passes(id, doc) { found.append(Ranked(id: id, score: 0, createdAt: doc.createdAt)) }
            found.sort { $0.createdAt != $1.createdAt ? $0.createdAt > $1.createdAt : $0.id < $1.id }
            return (Array(found.prefix(limit)), found.count)
        }
        guard ms.allSatisfy({ $0.matcher.exact || !$0.matcher.prefix.isEmpty || !$0.matcher.near.isEmpty }) else { return ([], 0) }
        // The rarest word picks the candidates.
        var lead = ms[0].matcher
        for x in ms where x.matcher.estimate < lead.estimate { lead = x.matcher }
        var ids = Set<String>()
        if lead.exact { ids.formUnion(postings[lead.word] ?? []) }
        for t in lead.prefix { ids.formUnion(postings[t] ?? []) }
        for t in lead.near { ids.formUnion(postings[t] ?? []) }
        var idf: [String: Double] = [:]
        func idfOf(_ t: String) -> Double {
            if let v = idf[t] { return v }
            let df = Double(postings[t]?.count ?? 1)
            let v = log(1 + (n - df + 0.5) / (df + 0.5))
            idf[t] = v
            return v
        }
        candidates: for id in ids {
            guard let doc = docs[id] else { continue }
            for x in ms {
                if !has(doc, x.matcher) { continue candidates }
                if x.title, !inTitle(doc, x.matcher) { continue candidates }
            }
            guard passes(id, doc) else { continue }
            for p in plan.phrases where p.count >= 2 && !hasPhrase(id, p) { continue candidates }
            var score = 0.0
            for x in ms {
                for (t, mult) in matched(doc, x.matcher) {
                    let tf = (doc.terms[t] ?? 0) * mult
                    score += idfOf(t) * (tf * 2.2) / (tf + 1.2 * (0.25 + 0.75 * doc.length / avg))
                }
            }
            if doc.pinned { score += 0.25 }
            score += max(0, 0.5 - (now - doc.createdAt) / 86_400_000 / 60)
            found.append(Ranked(id: id, score: score, createdAt: doc.createdAt))
        }
        found.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.id < $1.id
        }
        return (Array(found.prefix(limit)), found.count)
    }

    /// Whether `phrase` (terms) appears word for word in one of `texts`.
    static func contains(_ phrase: [String], in texts: [String]) -> Bool {
        for text in texts where !text.isEmpty {
            let seq = Tokenizer.terms(text)
            guard seq.count >= phrase.count else { continue }
            for i in 0...(seq.count - phrase.count) where Array(seq[i..<(i + phrase.count)]) == phrase { return true }
        }
        return false
    }
}

/// Reciprocal rank fusion: each list adds 1/(k + rank) to an id; ties keep the order first seen.
/// Used to combine keyword and meaning ranks (web: core/search.js `rrf`).
public enum RankFusion {
    public static func reciprocal(_ lists: [[String]], k: Double = 60) -> [String] {
        var score: [String: Double] = [:]
        var order: [String] = []
        for list in lists {
            for (i, id) in list.enumerated() {
                if score[id] == nil { score[id] = 0; order.append(id) }
                score[id]! += 1 / (k + Double(i + 1))
            }
        }
        let firstSeen = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        return order.sorted {
            let a = score[$0]!, b = score[$1]!
            return a != b ? a > b : firstSeen[$0]! < firstSeen[$1]!
        }
    }
}
