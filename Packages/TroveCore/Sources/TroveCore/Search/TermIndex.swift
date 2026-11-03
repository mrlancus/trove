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
    /// term → (document number → weighted term frequency). Numbers instead of ids, and the frequency
    /// kept with them, so scoring a word walks its postings without hashing ids or re-reading docs
    /// (docs/PERF_AUDIT.md B3, L1).
    private(set) var postings: [String: [Int32: Double]] = [:]
    private var numberOf: [String: Int32] = [:]
    private var idOf: [String] = []
    private var docAt: [Doc?] = []
    private var freeNumbers: [Int32] = []
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
        let n: Int32
        if let reused = freeNumbers.popLast() {
            n = reused
            idOf[Int(n)] = id
            docAt[Int(n)] = doc
        } else {
            n = Int32(idOf.count)
            idOf.append(id)
            docAt.append(doc)
        }
        numberOf[id] = n
        for (t, tf) in doc.terms {
            if postings[t] == nil { stale = true }
            postings[t, default: [:]][n] = tf
        }
    }

    mutating func remove(_ id: String) {
        guard let old = docs.removeValue(forKey: id), let n = numberOf.removeValue(forKey: id) else { return }
        totalLength -= old.length
        docAt[Int(n)] = nil
        freeNumbers.append(n)
        for t in old.terms.keys {
            postings[t]?[n] = nil
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
        var out = Self.common(m.prefix, m.prefixSet, doc, weight: 0.7)
        if !out.isEmpty { return out }
        out = Self.common(m.near, m.nearSet, doc, weight: 0.5)
        return out
    }

    /// The doc's terms that are in `list` (sorted), in `list`'s order. Looks up from whichever side
    /// is smaller: a two-letter prefix stands for 64 words, a short note has a few dozen
    /// (docs/PERF_AUDIT.md B3). Same terms, same order, so scores are summed identically.
    static func common(_ list: [String], _ set: Set<String>, _ doc: Doc, weight: Double) -> [(String, Double)] {
        if list.count <= doc.terms.count {
            var out: [(String, Double)] = []
            for t in list where doc.terms[t] != nil { out.append((t, weight)) }
            return out
        }
        var found: [String] = []
        for t in doc.terms.keys where set.contains(t) { found.append(t) }
        return found.sorted().map { ($0, weight) }
    }

    func has(_ doc: Doc, _ m: Matcher) -> Bool {
        if m.exact, doc.terms[m.word] != nil { return true }
        return Self.any(m.prefix, m.prefixSet, doc) || Self.any(m.near, m.nearSet, doc)
    }

    static func any(_ list: [String], _ set: Set<String>, _ doc: Doc) -> Bool {
        if list.isEmpty { return false }
        if list.count <= doc.terms.count { return list.contains { doc.terms[$0] != nil } }
        return doc.terms.keys.contains { set.contains($0) }
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

    /// Scores only the docs that hold every word. `passes` applies filters and exclusions (nil: none);
    /// `hasPhrase` checks a phrase word for word. Returns the best `limit` in order and how many matched.
    ///
    /// The rarest word ("lead") picks the candidates by walking its postings, which also gives each
    /// candidate's matched lead terms and frequencies; the other words are checked per candidate. The
    /// score is summed word by word in the plan's order and term by term in sorted order, exactly as
    /// before and as the website does, so results and ties are unchanged (`search-cases.json`).
    func search(_ plan: Plan, now: Double, limit: Int, passes: ((String, Doc) -> Bool)?, hasPhrase: (String, [String]) -> Bool) -> (ranked: [Ranked], total: Int) {
        let n = Double(max(docs.count, 1))
        let avg = max(totalLength / n, 1)
        var found: [Ranked] = []
        let ms = plan.matchers
        if ms.isEmpty {
            for (id, doc) in docs where passes?(id, doc) ?? true { found.append(Ranked(id: id, score: 0, createdAt: doc.createdAt)) }
            found.sort { $0.createdAt != $1.createdAt ? $0.createdAt > $1.createdAt : $0.id < $1.id }
            return (Array(found.prefix(limit)), found.count)
        }
        guard ms.allSatisfy({ $0.matcher.exact || !$0.matcher.prefix.isEmpty || !$0.matcher.near.isEmpty }) else { return ([], 0) }
        var leadAt = 0
        for (i, x) in ms.enumerated() where x.matcher.estimate < ms[leadAt].matcher.estimate { leadAt = i }
        let lead = ms[leadAt].matcher
        func idfOf(_ t: String) -> Double {
            let df = Double(postings[t]?.count ?? 1)
            return log(1 + (n - df + 0.5) / (df + 0.5))
        }
        // The lead's terms in the order `matched` reports them, with their weight and idf.
        struct LeadTerm { var term: String; var mult: Double; var idf: Double; var post: [Int32: Double] }
        var exactTerm: LeadTerm?
        if lead.exact, let post = postings[lead.word] { exactTerm = LeadTerm(term: lead.word, mult: 1, idf: idfOf(lead.word), post: post) }
        let prefixTerms = lead.prefix.compactMap { t in postings[t].map { LeadTerm(term: t, mult: 0.7, idf: idfOf(t), post: $0) } }
        let nearTerms = lead.near.compactMap { t in postings[t].map { LeadTerm(term: t, mult: 0.5, idf: idfOf(t), post: $0) } }
        // Per candidate: which lead terms matched (indexes into the chosen list) and their frequencies.
        var hits: [Int32: [(Int, Double)]] = [:]
        var kind: [Int32: Int] = [:] // 0 exact, 1 prefix, 2 near
        if let e = exactTerm { for (doc, tf) in e.post { hits[doc] = [(0, tf)]; kind[doc] = 0 } }
        for (i, t) in prefixTerms.enumerated() {
            for (doc, tf) in t.post where kind[doc] != 0 {
                hits[doc, default: []].append((i, tf))
                kind[doc] = 1
            }
        }
        for (i, t) in nearTerms.enumerated() {
            for (doc, tf) in t.post where kind[doc] == nil || kind[doc] == 2 {
                hits[doc, default: []].append((i, tf))
                kind[doc] = 2
            }
        }
        var idf: [String: Double] = [:]
        func cachedIdf(_ t: String) -> Double {
            if let v = idf[t] { return v }
            let v = idfOf(t)
            idf[t] = v
            return v
        }
        let others = ms.enumerated().filter { $0.offset != leadAt }.map(\.element)
        candidates: for (num, matchedLead) in hits {
            guard let doc = docAt[Int(num)] else { continue }
            let id = idOf[Int(num)]
            for x in others where !has(doc, x.matcher) { continue candidates }
            for x in ms where x.title && !inTitle(doc, x.matcher) { continue candidates }
            if let passes, !passes(id, doc) { continue }
            for p in plan.phrases where p.count >= 2 && !hasPhrase(id, p) { continue candidates }
            let list = kind[num] == 0 ? [exactTerm!] : kind[num] == 1 ? prefixTerms : nearTerms
            let norm = 1.2 * (0.25 + 0.75 * doc.length / avg)
            var score = 0.0
            for (i, x) in ms.enumerated() {
                if i == leadAt {
                    for (k, raw) in matchedLead {
                        let t = list[k]
                        let tf = raw * t.mult
                        score += t.idf * (tf * 2.2) / (tf + norm)
                    }
                } else {
                    for (t, mult) in matched(doc, x.matcher) {
                        let tf = (doc.terms[t] ?? 0) * mult
                        score += cachedIdf(t) * (tf * 2.2) / (tf + norm)
                    }
                }
            }
            if doc.pinned { score += 0.25 }
            score += max(0, 0.5 - (now - doc.createdAt) / 86_400_000 / 60)
            found.append(Ranked(id: id, score: score, createdAt: doc.createdAt))
        }
        return (Self.best(found, limit), found.count)
    }

    static func before(_ a: Ranked, _ b: Ranked) -> Bool {
        if a.score != b.score { return a.score > b.score }
        if a.createdAt != b.createdAt { return a.createdAt > b.createdAt }
        return a.id < b.id
    }

    /// The best `limit`, in order, without sorting everything when there are many more.
    static func best(_ found: [Ranked], _ limit: Int) -> [Ranked] {
        guard limit < found.count / 4, limit > 0 else { return Array(found.sorted(by: before).prefix(limit)) }
        // A min-heap of the best `limit` seen so far (the worst of them on top).
        var heap: [Ranked] = []
        heap.reserveCapacity(limit + 1)
        func up(_ i: Int) {
            var c = i
            while c > 0 { let p = (c - 1) / 2; if before(heap[p], heap[c]) { heap.swapAt(p, c); c = p } else { break } }
        }
        func down(_ i: Int) {
            var p = i
            while true {
                let l = 2 * p + 1, r = l + 1
                var worst = p
                if l < heap.count, before(heap[worst], heap[l]) { worst = l }
                if r < heap.count, before(heap[worst], heap[r]) { worst = r }
                if worst == p { return }
                heap.swapAt(p, worst)
                p = worst
            }
        }
        for r in found {
            if heap.count < limit { heap.append(r); up(heap.count - 1) }
            else if before(r, heap[0]) { heap[0] = r; down(0) }
        }
        return heap.sorted(by: before)
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
