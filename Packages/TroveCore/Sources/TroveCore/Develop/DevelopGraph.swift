import Foundation

/// Typed edges in both directions (docs/DEVELOP_PLAN.md §C2). Built once from the records, then
/// updated from the change feed for kinds `edge` and `concept`, so it stays O(changed). Concepts
/// merged into another (`mergedInto`) are followed when reading, so links to the loser show on the
/// winner and undoing a merge restores everything.
public struct EdgeIndex: Sendable {
    private var edges: [String: Edge] = [:]
    private var outgoing: [String: Set<String>] = [:]
    private var incoming: [String: Set<String>] = [:]
    private var mergedInto: [String: String] = [:]

    public init() {}

    public init(edges: [Edge], concepts: [Concept]) {
        for c in concepts { update(c) }
        for e in edges { update(e) }
    }

    public mutating func update(_ e: Edge) {
        remove(edge: e.id)
        edges[e.id] = e
        outgoing[e.from, default: []].insert(e.id)
        incoming[e.to, default: []].insert(e.id)
    }

    public mutating func remove(edge id: String) {
        guard let old = edges.removeValue(forKey: id) else { return }
        outgoing[old.from]?.remove(id)
        incoming[old.to]?.remove(id)
    }

    public mutating func update(_ c: Concept) {
        if let to = c.mergedInto, to != c.id { mergedInto[c.id] = to } else { mergedInto[c.id] = nil }
    }

    /// Applies what changed in the store since the last look.
    public mutating func apply(_ changes: RecordStore.ChangeSet, read: (String) -> Record?) {
        for id in changes.ids(Develop.conceptKind) {
            if let r = read(id), !r.isDeleted { update(Concept(r)) } else { mergedInto[id] = nil }
        }
        for id in changes.ids(Develop.edgeKind) {
            if let r = read(id), !r.isDeleted, let e = Edge(r) { update(e) } else { remove(edge: id) }
        }
    }

    /// Follows `mergedInto` to the concept that stands for this one (stops on a loop).
    public func resolve(_ id: String) -> String {
        var current = id
        var seen: Set<String> = [id]
        while let next = mergedInto[current], seen.insert(next).inserted { current = next }
        return current
    }

    /// Every id that resolves to `id` (itself and what was merged into it).
    func members(_ id: String) -> [String] {
        let target = resolve(id)
        return [target] + mergedInto.keys.filter { $0 != target && resolve($0) == target }.sorted()
    }

    /// Edges leaving `id` (or anything merged into it), not rejected unless asked, sorted by id.
    public func from(_ id: String, type: EdgeType? = nil, includeRejected: Bool = false) -> [Edge] {
        collect(members(id).flatMap { outgoing[$0] ?? [] }, type: type, includeRejected: includeRejected)
    }

    /// Edges arriving at `id` (or anything merged into it).
    public func to(_ id: String, type: EdgeType? = nil, includeRejected: Bool = false) -> [Edge] {
        collect(members(id).flatMap { incoming[$0] ?? [] }, type: type, includeRejected: includeRejected)
    }

    /// Both directions; symmetric types are stored once, so this is how to read them.
    public func around(_ id: String, type: EdgeType? = nil) -> [Edge] {
        Array(Set(from(id, type: type).map(\.id) + to(id, type: type).map(\.id))).sorted().compactMap { edges[$0] }
    }

    /// Whether the user said no to this edge: it's never suggested again.
    public func isRejected(from: String, type: EdgeType, to: String) -> Bool {
        edges[Develop.edgeId(from: from, type: type, to: to)]?.state == .rejected
    }

    private func collect(_ ids: [String], type: EdgeType?, includeRejected: Bool) -> [Edge] {
        Set(ids).sorted().compactMap { edges[$0] }.filter { (type == nil || $0.type == type) && (includeRejected || $0.state != .rejected) }
    }
}

/// Duplicate concepts (docs/DEVELOP_PLAN.md §B3 point 2): the same stemmed content words in any order
/// are the same concept ("conservation of momentum" = "momentum conservation"); close word sets are
/// suggested, never merged by themselves.
public enum ConceptMatch {
    /// Jaccard similarity of word sets at or above this is suggested as a merge.
    public static let suggestThreshold = 0.8

    public static func words(_ name: String) -> Set<String> { Set(Tokenizer.terms(name)) }

    public static func similarity(_ a: String, _ b: String) -> Double {
        let x = words(a), y = words(b)
        guard !x.isEmpty || !y.isEmpty else { return 0 }
        return Double(x.intersection(y).count) / Double(x.union(y).count)
    }

    public enum Verdict: Equatable, Sendable { case same, suggest, different }

    public static func compare(_ a: String, _ b: String) -> Verdict {
        let x = words(a), y = words(b)
        if !x.isEmpty, x == y { return .same }
        return similarity(a, b) >= suggestThreshold ? .suggest : .different
    }

    /// For concepts that are the same by `compare`, the merges every device makes alike: the
    /// lexicographically smallest id wins. Returns (loser, winner) pairs.
    public static func automaticMerges(_ concepts: [Concept]) -> [(String, String)] {
        let live = concepts.filter { $0.mergedInto == nil }
        var groups: [[String]: [String]] = [:]
        for c in live {
            let key = words(c.name).sorted()
            guard !key.isEmpty else { continue }
            groups[key, default: []].append(c.id)
        }
        var out: [(String, String)] = []
        for ids in groups.values where ids.count > 1 {
            let sorted = ids.sorted()
            for loser in sorted.dropFirst() { out.append((loser, sorted[0])) }
        }
        return out.sorted { $0.0 < $1.0 }
    }

    /// Concepts whose names appear in `text` (word for word, stemmed), best first: a free, on-device
    /// way to suggest `about` edges for a photo's or note's text before any AI.
    public static func mentioned(in text: String, concepts: [Concept]) -> [String] {
        let terms = Tokenizer.terms(text)
        var hits: [(String, Int)] = []
        for c in concepts where c.mergedInto == nil {
            let name = Tokenizer.terms(c.name)
            guard !name.isEmpty, terms.count >= name.count else { continue }
            var count = 0
            for i in 0...(terms.count - name.count) where Array(terms[i..<(i + name.count)]) == name { count += 1 }
            if count > 0 { hits.append((c.id, count * name.count)) }
        }
        return hits.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }.map(\.0)
    }
}

/// Picking practice problems (docs/DEVELOP_PLAN.md §C8, §E): pseudo-random, weighted towards skills
/// that are due or weak, never one done recently, seeded so a session can be replayed.
public enum Practice {
    public struct Filter: Sendable, Equatable {
        public var skills: Set<String> = []
        public var sources: Set<String> = []
        /// Source keys starting with any of these ("cat:aqa-7408-": a course's papers).
        public var sourcePrefixes: Set<String> = []
        public var levels: Set<ProblemLevel> = []
        /// A problem testing any of these passes the source filters too (your own courses' topics, which have no
        /// source prefix; learn-pivot plan §C1). With no source filters set, these alone choose.
        public var orSkills: Set<String> = []
        public var minMarks: Int?
        public var maxMarks: Int?
        public init() {}
    }

    /// Not shown again within this many days.
    public static let recentDays = 3.0
    static func sourceOK(_ p: Problem, _ f: Filter) -> Bool {
        let bySource = (f.sources.isEmpty || f.sources.contains(p.sourceKey))
            && (f.sourcePrefixes.isEmpty || f.sourcePrefixes.contains { p.sourceKey.hasPrefix($0) })
        if f.orSkills.isEmpty { return bySource }
        let byTopic = !f.orSkills.isDisjoint(with: p.skills)
        let noSource = f.sources.isEmpty && f.sourcePrefixes.isEmpty
        return byTopic || (!noSource && bySource)
    }

    /// Up next is always a small session (learn-pivot plan §1.1, step 3b): about 3 questions, ~10 minutes.
    public static let smallSession = 3
    /// While some problems have a topic the set doesn't have yet, the next pick comes from those, so a set mixes
    /// similar topics (interleaving, plan §1.1) instead of repeating one.
    public static let mixTopics = true

    /// Minutes a set takes, roughly: a minute a mark (the boards' own pace), at least 2 a question.
    public static func minutes(_ problems: [Problem]) -> Int {
        problems.reduce(0) { $0 + max(2, $1.marks ?? 3) }
    }

    /// Orders a set so no two problems in a row share their first topic, when that's possible: each time, the
    /// topic with the most left that isn't the one just used (ties: the first picked). Within a topic, as picked.
    public static func interleave(_ problems: [Problem]) -> [Problem] {
        var queues: [(topic: String, items: [Problem])] = []
        for p in problems {
            let t = p.skills.first ?? ""
            if let i = queues.firstIndex(where: { $0.topic == t }) { queues[i].items.append(p) } else { queues.append((t, [p])) }
        }
        var out: [Problem] = []
        var last: String?
        while queues.contains(where: { !$0.items.isEmpty }) {
            let order = queues.indices.filter { !queues[$0].items.isEmpty }
            let best = order.filter { queues[$0].topic != last || queues[$0].topic.isEmpty }.max { queues[$0].items.count < queues[$1].items.count }
                ?? order.max { queues[$0].items.count < queues[$1].items.count }!
            out.append(queues[best].items.removeFirst())
            last = queues[best].topic
        }
        return out
    }
    /// A due or weak skill's problems are up to this many times likelier than a well-known one's.
    public static let maxWeight = 5.0

    public static func pick(_ count: Int, from problems: [Problem], attempts: [Attempt], skills: [String: SkillState],
                            filter: Filter = Filter(), now: Double, seed: UInt64) -> [Problem] {
        let recent = Set(attempts.filter { now - $0.at < recentDays * Mastery.day }.map(\.problem))
        let pool = problems.filter { p in
            !recent.contains(p.id)
                && (filter.skills.isEmpty || !filter.skills.isDisjoint(with: p.skills))
                && sourceOK(p, filter)
                && (filter.levels.isEmpty || filter.levels.contains(p.level))
                && (filter.minMarks.map { (p.marks ?? 0) >= $0 } ?? true)
                && (filter.maxMarks.map { (p.marks ?? 0) <= $0 } ?? true)
        }.sorted { $0.id < $1.id }
        var weights = pool.map { p -> Double in
            // How much I need it: 1 − the chance I can do it now (unknown skills count as needed).
            let need = p.skills.map { s -> Double in
                guard let st = skills[s], let m = st.memory, st.mastery != nil else { return 1 }
                let due = (st.due ?? 0) <= now ? 1.0 : 0.0
                return max(due, 1 - (st.pApply(daysAfterLast: (now - m.last) / Mastery.day) ?? 0))
            }.max() ?? 1
            return 1 + (maxWeight - 1) * need
        }
        var random = TroveGen.Seeded(seed)
        var picked: [Problem] = []
        var candidates = pool
        var have = Set<String>()
        while picked.count < count, !candidates.isEmpty {
            // Mix topics: while some candidates bring a topic the set doesn't have, draw only from those.
            let fresh = mixTopics ? candidates.indices.filter { !candidates[$0].skills.isEmpty && Set(candidates[$0].skills).isDisjoint(with: have) } : []
            let allowed = fresh.isEmpty ? Array(candidates.indices) : fresh
            let total = allowed.reduce(0) { $0 + weights[$1] }
            var r = random.unit() * total
            var k = 0
            while k < allowed.count - 1, r >= weights[allowed[k]] { r -= weights[allowed[k]]; k += 1 }
            let i = allowed[k]
            let chosen = candidates.remove(at: i)
            picked.append(chosen)
            weights.remove(at: i)
            have.formUnion(chosen.skills)
        }
        return interleave(picked)
    }
}
