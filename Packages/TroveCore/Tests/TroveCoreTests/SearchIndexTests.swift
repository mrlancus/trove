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
