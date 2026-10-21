import Foundation
import Testing
@testable import TroveCore

/// The weekly digest, "on this day" and duplicates match the website (Fixtures/digest-cases.json,
/// written by web/test/make-digest-fixture.mjs).
struct DigestTests {
    func fixture() throws -> [String: JSONValue] {
        let url = try #require(Bundle.module.url(forResource: "digest-cases", withExtension: "json", subdirectory: "Fixtures"))
        return try #require(try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url)).object)
    }

    func items(_ f: [String: JSONValue]) -> [Item] {
        (f["items"]?.array ?? []).compactMap { v in
            guard let o = v.object, let id = o["id"]?.string else { return nil }
            var r = Record(id: id, kind: "item", createdHLC: "", updatedHLC: "")
            for (k, value) in o where k != "id" && k != "body" { r.fields[k] = value }
            r.texts = [Field.body: o["body"]?.string ?? ""]
            return Item(r)
        }
    }

    func date(_ v: JSONValue?) -> Date { Date(timeIntervalSince1970: (v?.number ?? 0) / 1000) }

    @Test func weeksAndIds() throws {
        for w in try fixture()["weeks"]?.array ?? [] {
            let o = try #require(w.object)
            let week = Digest.isoWeek(date(o["at"]))
            #expect(week.year == Int(o["year"]?.number ?? 0))
            #expect(week.week == Int(o["week"]?.number ?? 0))
            #expect(Digest.weekStart(week) == date(o["start"]))
            #expect(Digest.id(for: week) == o["id"]?.string)
        }
        #expect(Digest.previousWeek(date(.number(1_792_540_800_000))) == Digest.Week(year: 2026, week: 42)) // 21 Oct 2026
    }

    @Test func digestMatchesTheWebsite() throws {
        let f = try fixture()
        let all = items(f)
        for name in ["digest", "quietDigest"] {
            let c = try #require(f[name]?.object)
            let expect = try #require(c["expect"]?.object)
            let note = Digest.weekly(all, week: Digest.Week(year: Int(c["year"]?.number ?? 0), week: Int(c["week"]?.number ?? 0)))
            #expect(note.id == expect["id"]?.string)
            #expect(note.title == expect["title"]?.string)
            #expect(note.body == expect["body"]?.string)
            #expect(Double(note.saved) == expect["counts"]?.object?["saved"]?.number)
        }
        // Another device, other order: the same note.
        let w = Digest.Week(year: 2026, week: 43)
        #expect(Digest.weekly(all.reversed(), week: w) == Digest.weekly(all, week: w))
        #expect(Digest.weekly(all, week: w, summary: "Mostly bread.", model: "m").body.contains("## In short\nMostly bread.\n\n_Processed in the cloud (m)._"))
    }

    @Test func onThisDayAndDuplicatesMatchTheWebsite() throws {
        let f = try fixture()
        let all = items(f)
        let day = try #require(f["onThisDay"]?.object)
        #expect(Digest.onThisDay(all, now: date(day["at"])).map(\.id) == day["expect"]?.stringArray)
        let expected = (f["duplicates"]?.array ?? []).compactMap { g -> Digest.DuplicateGroup? in
            guard let o = g.object, let reason = o["reason"]?.string else { return nil }
            return Digest.DuplicateGroup(reason: reason, ids: o["ids"]?.stringArray ?? [])
        }
        #expect(Digest.possibleDuplicates(all) == expected)
        #expect(Digest.titleWords("Café menus of Paris") == ["cafe", "menus", "paris"])
    }
}
