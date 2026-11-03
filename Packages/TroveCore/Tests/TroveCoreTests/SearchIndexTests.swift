import Foundation
import Testing
@testable import TroveCore

/// Fixtures/search-cases.json comes from web/test/make-search-fixture.mjs (core/search.js): the same
/// items, folders and clips must give the same results in the same order, the same snippets and the
/// same rank fusion on both sides.
@Suite struct SearchIndexTests {
    struct Doc: Decodable { var id: String; var fields: [String: JSONValue]; var body: String? }
    struct Folder: Decodable { var id: String; var name: String; var parent: String? }
    struct Case: Decodable { var query: String; var ids: [String] }
    struct Snip: Decodable { var id: String; var query: String; var field: String?; var text: String?; var highlights: [String] }
    struct Fusion: Decodable { var lists: [[String]]; var ids: [String] }
    struct Fixture: Decodable {
        var now: Double
        var folders: [Folder]
        var items: [Doc]
        var cases: [Case]
        var snippets: [Snip]
        var clips: [Doc]
        var clipCases: [Case]
        var rrf: [Fusion]
    }

    func fixture() throws -> Fixture {
        let url = try #require(Bundle.module.url(forResource: "search-cases", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    func record(_ d: Doc, kind: String) -> Record {
        var r = Record(id: d.id, kind: kind, createdHLC: "x", updatedHLC: "x")
        r.fields = d.fields
        if let body = d.body { r.texts = [Field.body: body] }
        return r
    }

    func index(_ f: Fixture) -> SearchIndex {
        var index = SearchIndex()
        for d in f.items { index.update(Item(record(d, kind: "item"))) }
        index.folders = Dictionary(uniqueKeysWithValues: f.folders.map { ($0.id, SearchFolder(name: $0.name, parent: $0.parent)) })
        index.prepare()
        return index
    }

    @Test func matchesTheWebsite() throws {
        let f = try fixture()
        let index = index(f)
        let now = Date(timeIntervalSince1970: f.now / 1000)
        #expect(f.cases.count >= 40)
        for c in f.cases {
            #expect(index.search(.parse(c.query), now: now).map(\.item.id) == c.ids, "\(c.query)")
        }
        for c in f.snippets {
            let s = index.snippet(for: c.id, query: .parse(c.query))
            #expect(s?.field == c.field, "\(c.query)")
            #expect(s?.text == c.text, "\(c.query)")
            #expect((s?.highlights ?? []) == c.highlights, "\(c.query)")
        }
        var clips = ClipIndex()
        for d in f.clips { clips.update(Clip(record(d, kind: "clip"))) }
        clips.prepare()
        for c in f.clipCases {
            #expect(clips.search(ClipQuery(c.query), now: now).ids == c.ids, "\(c.query)")
        }
        for c in f.rrf { #expect(RankFusion.reciprocal(c.lists) == c.ids) }
    }

    @Test func parsesOperators() {
        let q = SearchQuery.parse("\"exact words\" title:\"Recipe ideas\" in:\"Work notes\" -tokyo -\"bad phrase\" has:ink has:nope before:2026-01 after:2025 type:sketch #Food plain")
        #expect(q.phrases == [["exact", "word"]])
        #expect(q.title == ["recipe", "idea"])
        #expect(q.collection == "Work notes")
        #expect(q.exclude == ["tokyo"])
        #expect(q.excludePhrases == [["bad", "phrase"]])
        #expect(q.has == ["ink"])
        #expect(q.before == Date(timeIntervalSince1970: 1_767_225_600))
        #expect(q.after == Date(timeIntervalSince1970: 1_735_689_600))
        #expect(q.kinds == [.sketch])
        #expect(q.tags == ["food"])
        #expect(q.text == "has:nope plain")
        #expect(SearchQuery.parse("before:2026-13").before == nil)
        #expect(TermIndex.withinOneEdit("recipie", "recipe"))
        #expect(TermIndex.withinOneEdit("recpie", "recipe"))
        #expect(!TermIndex.withinOneEdit("recpies", "recipe"))
    }

    @Test func snapshotReindexesOnlyWhatChanged() throws {
        let f = try fixture()
        let saved = index(f).snapshot()
        let data = try JSONEncoder().encode(saved)
        let loaded = try JSONDecoder().decode(SearchIndex.Snapshot.self, from: data)
        #expect(loaded == saved)

        var items = f.items.map { Item(record($0, kind: "item")) }
        var changed = items[0].record
        changed.updatedHLC = "y"
        changed.fields[Field.title] = "Shoyu ramen recipe"
        items[0] = Item(changed)
        var restored = SearchIndex()
        #expect(restored.restore(loaded, items: items) == 1)
        let now = Date(timeIntervalSince1970: f.now / 1000)
        #expect(restored.search(.parse("shoyu"), now: now).map(\.item.id) == ["r1"])
        #expect(restored.search(.parse("tomatoes"), now: now).map(\.item.id) == ["s1"])
        #expect(restored.count == items.count)
    }

    @Test func libraryRestoresItsIndex() async throws {
        let engine = SyncEngine(device: "D", keys: .generate())
        let lib = Library(engine: engine)
        let a = await lib.addNote(title: "Garden plan", body: "compost and beans")
        let snap = await lib.searchSnapshot()
        let other = Library(engine: engine)
        #expect(await other.restoreSearch(snap) == 0)
        #expect(await other.search("compost").map(\.id) == [a])
        let folder = await lib.createFolder("Allotment")
        await lib.move(a, to: folder)
        #expect(await lib.search("in:allotment").map(\.id) == [a])
    }
}

/// The postings-walking engine (PERF_AUDIT B3/L1) gives exactly what scoring every doc the old way gives.
@Suite struct SearchEngineEquivalenceTests {
    /// The previous algorithm, kept as a reference: every doc checked and scored, then sorted.
    static func reference(_ e: TermIndex, _ plan: TermIndex.Plan, now: Double) -> [TermIndex.Ranked] {
        let n = Double(max(e.docs.count, 1))
        let avg = max(e.totalLength / n, 1)
        var out: [TermIndex.Ranked] = []
        func idf(_ t: String) -> Double {
            let df = Double(e.postings[t]?.count ?? 1)
            return log(1 + (n - df + 0.5) / (df + 0.5))
        }
        guard !plan.matchers.isEmpty, plan.matchers.allSatisfy({ $0.matcher.exact || !$0.matcher.prefix.isEmpty || !$0.matcher.near.isEmpty }) else { return [] }
        docs: for (id, doc) in e.docs {
            for x in plan.matchers {
                if !e.has(doc, x.matcher) { continue docs }
                if x.title, !e.inTitle(doc, x.matcher) { continue docs }
            }
            var score = 0.0
            for x in plan.matchers {
                for (t, mult) in e.matched(doc, x.matcher) {
                    let tf = (doc.terms[t] ?? 0) * mult
                    score += idf(t) * (tf * 2.2) / (tf + 1.2 * (0.25 + 0.75 * doc.length / avg))
                }
            }
            if doc.pinned { score += 0.25 }
            score += max(0, 0.5 - (now - doc.createdAt) / 86_400_000 / 60)
            out.append(.init(id: id, score: score, createdAt: doc.createdAt))
        }
        return out.sorted(by: TermIndex.before)
    }

    @Test func sameResultsAndScoresAsScoringEveryDoc() {
        var store = RecordStore()
        store.apply(TroveGen.ops(TroveGen.Size.small.scaled(0.5)))
        var index = SearchIndex()
        for r in store.visible(kind: "item") { index.update(Item(r)) }
        index.prepare()
        var random = TroveGen.Seeded(5)
        let now = 1_700_000_000_000.0
        var checked = 0
        for _ in 0..<300 {
            let words = (0..<(1 + random.int(3))).map { _ in TroveGen.vocabulary[min(TroveGen.vocabulary.count - 1, random.int(400))] }
            var text = words.joined(separator: " ")
            if random.int(2) == 0, let last = words.last { text = String(text.dropLast(max(0, last.count - 1 - random.int(last.count)))) }
            if random.int(5) == 0 { text += "x" } // a typo
            let plan = index.engine.plan(text: text)
            guard !plan.matchers.isEmpty else { continue } // no words: newest first, not scored
            let fast = index.engine.search(plan, now: now, limit: 50, passes: nil, hasPhrase: { _, _ in true })
            let slow = Self.reference(index.engine, plan, now: now)
            #expect(fast.total == slow.count, "\(text)")
            #expect(fast.ranked.map(\.id) == Array(slow.prefix(50)).map(\.id), "\(text)")
            #expect(fast.ranked.map(\.score) == Array(slow.prefix(50)).map(\.score), "\(text)")
            checked += slow.isEmpty ? 0 : 1
        }
        #expect(checked > 100)
    }

    @Test func removingAndReinsertingKeepsResults() {
        var e = TermIndex()
        func doc(_ terms: [String: Double]) -> TermIndex.Doc { .init(v: "1", terms: terms, length: TermIndex.length(terms), createdAt: 0, pinned: false, title: []) }
        e.insert("a", doc(["plum": 2]))
        e.insert("b", doc(["plum": 1, "jam": 1]))
        e.insert("c", doc(["jam": 3]))
        e.remove("b")
        e.insert("d", doc(["plum": 1])) // reuses b's number
        e.insert("a", doc(["jam": 1]))  // replaced
        e.prepare()
        let r = e.search(e.plan(text: "plum"), now: 0, limit: 10, passes: nil, hasPhrase: { _, _ in true })
        #expect(r.ranked.map(\.id) == ["d"])
        #expect(Set(e.search(e.plan(text: "jam"), now: 0, limit: 10, passes: nil, hasPhrase: { _, _ in true }).ranked.map(\.id)) == ["a", "c"])
    }
}
