import Foundation
import Testing
@testable import TroveCore

/// Placeholders, templates, the daily note and checklists match the website (Fixtures/notes-cases.json,
/// written by web/test/make-notes-fixture.mjs).
struct NotesTests {
    func fixture() throws -> [String: JSONValue] {
        let url = try #require(Bundle.module.url(forResource: "notes-cases", withExtension: "json", subdirectory: "Fixtures"))
        return try #require(try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url)).object)
    }

    func parts(_ v: JSONValue?) -> Notes.DateParts {
        let o = v?.object ?? [:]
        func n(_ k: String) -> Int { Int(o[k]?.number ?? 0) }
        return Notes.DateParts(year: n("year"), month: n("month"), day: n("day"), hour: n("hour"), minute: n("minute"), second: n("second"), weekday: n("weekday"))
    }

    func items(_ f: [String: JSONValue]) -> [Item] {
        (f["items"]?.array ?? []).compactMap { v in
            guard let o = v.object, let id = o["id"]?.string else { return nil }
            var r = Record(id: id, kind: "item", createdHLC: "", updatedHLC: "")
            r.fields[Field.kind] = o["kind"] ?? .string("note")
            r.fields[Field.category] = o["category"] ?? .string("note")
            for k in ["title", "url", "tags"] { if let value = o[k] { r.fields[k] = value } }
            r.texts = [Field.body: o["body"]?.string ?? ""]
            return Item(r)
        }
    }

    func json(_ t: Notes.Template, made: Notes.NewNote) -> [String: JSONValue] {
        [
            "id": .string(t.id), "name": .string(t.name), "title": .string(t.title), "body": .string(t.body), "tags": JSONValue(t.tags),
            "category": t.category.map(JSONValue.string) ?? .null, "user": .bool(t.user), "clipboard": .bool(Notes.usesClipboard(t)),
            "made": .object(json(made)),
        ]
    }

    func json(_ n: Notes.NewNote) -> [String: JSONValue] {
        ["title": .string(n.title), "body": .string(n.body), "tags": JSONValue(n.tags), "category": n.category.map(JSONValue.string) ?? .null]
    }

    @Test func placeholdersAndNames() throws {
        let f = try fixture()
        let all = f["parts"]?.array ?? []
        for c in f["placeholders"]?.array ?? [] {
            let o = try #require(c.object)
            let text = o["text"]?.string ?? ""
            let p = parts(all[Int(o["part"]?.number ?? 0)])
            #expect(Notes.expand(text, p, clipboard: o["clipboard"]?.string ?? "", title: o["title"]?.string ?? "") == o["expect"]?.string)
            #expect(Notes.hasPlaceholders(text) == o["has"]?.bool)
        }
        for c in f["templateNames"]?.array ?? [] {
            #expect(Notes.templateName(c.object?["title"]?.string ?? "") == c.object?["expect"]?.string)
        }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        #expect(Notes.DateParts(Date(timeIntervalSince1970: 1_792_591_502), calendar: utc)
            == Notes.DateParts(year: 2026, month: 10, day: 21, hour: 14, minute: 5, second: 2, weekday: 3))
    }

    @Test func templatesAndTheDailyNote() throws {
        let f = try fixture()
        let all = items(f)
        let p = parts(f["parts"]?.array?[0])
        let made = Notes.allTemplates(all).map { JSONValue.object(json($0, made: Notes.make(from: $0, p, clipboard: "clip"))) }
        #expect(made == f["templates"]?.array)
        let builtIn = Notes.allTemplates([]).map { JSONValue.object(json($0, made: Notes.make(from: $0, p))) }
        #expect(builtIn == f["builtInTemplates"]?.array)
        for (name, list, at) in [("daily", all, 0), ("dailyBuiltIn", [], 1)] {
            let d = Notes.daily(list, parts(f["parts"]?.array?[at]))
            let expect = try #require(f[name]?.object)
            #expect(d.id == expect["id"]?.string)
            #expect(d.date == expect["date"]?.string)
            #expect(JSONValue.object(json(d.note)) == expect["note"])
        }
        #expect(Notes.daily(all.reversed(), p).note == Notes.daily(all, p).note)
    }

    @Test func checklists() throws {
        for c in try fixture()["checklists"]?.array ?? [] {
            let o = try #require(c.object)
            let body = o["body"]?.string ?? ""
            let boxes = Notes.checkboxes(in: body).map { b in
                JSONValue.object(["line": .number(Double(b.line)), "done": .bool(b.done), "text": .string(b.text)])
            }
            #expect(boxes == o["boxes"]?.array)
            let counts = Notes.counts(body)
            #expect(Double(counts.done) == o["counts"]?.object?["done"]?.number)
            #expect(Double(counts.total) == o["counts"]?.object?["total"]?.number)
            #expect(boxes.indices.map { JSONValue.string(Notes.toggle(body, at: $0)) } == o["toggled"]?.array)
            #expect(Notes.toggle(body, at: boxes.count) == o["outOfRange"]?.string)
        }
    }

    @Test func libraryDailyNoteTemplatesAndTicks() async throws {
        let lib = Library(engine: SyncEngine(device: "D", keys: .generate(), transports: []))
        let p = Notes.DateParts(year: 2026, month: 10, day: 21, hour: 9, weekday: 3)
        let id = await lib.openDaily(p)
        #expect(id == "daily-2026-10-21")
        var daily = try #require(await lib.item(id))
        #expect(daily.title == "Wednesday 21 October 2026")
        #expect(daily.tags == ["daily"])
        #expect(daily.record["daily"]?.string == "2026-10-21")
        await lib.setBody(id, daily.body + "\nA thought")
        #expect(await lib.openDaily(p) == id) // opening again keeps what's written
        #expect(try #require(await lib.item(id)).body.hasSuffix("A thought"))
        await lib.toggleCheckbox(id, at: 0)
        daily = try #require(await lib.item(id))
        #expect(Notes.counts(daily.body) == (1, 1))
        await lib.delete(id)
        #expect(await lib.openDaily(p) == id) // deleted: made again, fresh
        #expect(try #require(await lib.item(id)).body == Notes.builtIns[0].body)

        let recipe = try #require(Notes.builtIns.first { $0.id == "recipe" })
        let r = try #require(await lib.item(await lib.addNote(from: recipe, p)))
        #expect(r.category == .recipe)
        #expect(r.tags == ["recipe"])
        await lib.setTemplate(r.id, true)
        #expect(await lib.templates().first?.user == true)
        #expect(await lib.templates().count == 5) // "New recipe" is a new name, so "Recipe" stays
        await lib.update(r.id, [Field.title: .string("Recipe")])
        #expect(await lib.templates().count == 4) // yours replaces the built-in one
        await lib.setTemplate(r.id, false)
        #expect(await lib.templates() == Notes.builtIns)
    }
}
