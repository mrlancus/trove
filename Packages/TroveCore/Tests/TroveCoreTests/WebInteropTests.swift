import Foundation
import Testing
@testable import TroveCore

/// The web app (web/core) re-implements segments and materialisation in JavaScript. These fixtures
/// prove both directions agree: Swift-written journals materialise identically in JS
/// (`web/test/fixtures/swift-journal.json`, written with `TROVE_WEB_FIXTURE=path swift test`), and
/// JS-written journals materialise identically here (`Fixtures/web-journal.json`, from `npm run fixtures` in web/).
@Suite struct WebInteropTests {
    struct JournalFixture: Codable {
        struct Seg: Codable { var device: String; var first: Int; var last: Int; var data: String }
        struct Rec: Codable, Equatable {
            var kind: String
            var fields: [String: JSONValue]
            var texts: [String: String]
            var conflicts: [String: [String]]
        }
        var keys: VaultKeys.Exported
        var segments: [Seg]
        var expected: [String: Rec]
    }

    static func expected(_ store: RecordStore) -> [String: JournalFixture.Rec] {
        store.records.mapValues { .init(kind: $0.kind, fields: $0.fields, texts: $0.texts, conflicts: $0.conflicts) }
    }

    /// Two devices editing concurrently: LWW fields, a clean text merge, a text conflict, a delete.
    static func scenario() throws -> (segments: [Segment], store: RecordStore) {
        var a = Journal(state: .init(device: "AAAA-MAC"), now: { 1_760_000_000_000 })
        var b = Journal(state: .init(device: "BBBB-IPHONE"), now: { 1_760_000_000_000 })
        let list = "Shopping\n- milk\n- eggs\n- bread"
        var opsA: [Op] = [], opsB: [Op] = []
        opsA.append(a.set(["kind": "note", "title": "List", "createdAt": 1_760_000_000_000, "tags": ["home"], "pinned": true,
                           "price": 12.5, "readAt": .null], record: "n1", kind: "item"))
        opsA.append(a.text("body", value: list, previous: "", record: "n1", kind: "item"))
        opsA.append(a.set(["kind": "note", "title": "Greeting"], record: "n2", kind: "item"))
        opsA.append(a.text("body", value: "Hello\nsecond line", previous: "", record: "n2"))
        opsA.append(a.set(["kind": "link", "url": "https://example.com/café?q=☕️", "title": "Café ☕️"], record: "n3", kind: "item"))
        for op in opsA { b.observe(op.hlc) }
        // Concurrent edits from here on.
        opsA.append(a.text("body", value: "Shopping\n- oat milk\n- eggs\n- bread", previous: list, record: "n1"))
        opsB.append(b.text("body", value: "Shopping\n- milk\n- eggs\n- bread\n- coffee ☕️", previous: list, record: "n1"))
        opsA.append(a.text("body", value: "Hello world\nsecond line", previous: "Hello\nsecond line", record: "n2"))
        opsB.append(b.text("body", value: "Hello there\nsecond line", previous: "Hello\nsecond line", record: "n2"))
        opsA.append(a.set(["title": "Groceries"], record: "n1"))
        opsB.append(b.set(["title": "Shopping list", "tags": ["home", "food"]], record: "n1"))
        opsB.append(b.set(["_deleted": true], record: "n3"))
        opsB.append(b.set(["name": "Kitchen", "symbol": "fork.knife"], record: "c1", kind: "collection"))
        opsB.append(b.set([Clip.Field.text: "#ff8a3d", Clip.Field.hash: .string(Clip.hash(text: "#ff8a3d")), Clip.Field.createdAt: 1_760_000_000_500,
                           Clip.Field.sourceApp: "Figma", Clip.Field.device: "BBBB"], record: "k1", kind: "clip"))
        let segments = try a.takeSegments() + b.takeSegments()
        var store = RecordStore()
        store.apply(opsB)
        store.apply(opsA)
        return (segments, store)
    }

    @Test func scenarioMergesAsExpected() throws {
        let (_, store) = try Self.scenario()
        #expect(store.record("n1")?.texts["body"] == "Shopping\n- oat milk\n- eggs\n- bread\n- coffee ☕️")
        #expect(store.record("n2")?.conflicts["body"]?.count == 1)
        #expect(store.record("n3")?.isDeleted == true)
    }

    @Test func exportsJournalForWebWhenAsked() throws {
        guard let path = ProcessInfo.processInfo.environment["TROVE_WEB_FIXTURE"] else { return }
        let keys = VaultKeys.generate()
        let (segments, store) = try Self.scenario()
        let fixture = JournalFixture(
            keys: keys.exported(),
            segments: try segments.map { .init(device: $0.device, first: $0.first, last: $0.last, data: try $0.encrypted(with: keys).base64URL) },
            expected: Self.expected(store))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        try encoder.encode(fixture).write(to: URL(fileURLWithPath: path))
    }

    @Test func materialisesJournalsWrittenByTheWebApp() throws {
        let url = try #require(Bundle.module.url(forResource: "web-journal", withExtension: "json", subdirectory: "Fixtures"))
        let fixture = try JSONDecoder().decode(JournalFixture.self, from: Data(contentsOf: url))
        let keys = try VaultKeys(fixture.keys)
        var store = RecordStore()
        for seg in fixture.segments.reversed() {
            let segment = try Segment.decrypt(try #require(Data(base64URL: seg.data)), device: seg.device, keys: keys)
            #expect(segment.first == seg.first && segment.last == seg.last)
            store.apply(segment.ops)
        }
        let got = Self.expected(store)
        #expect(got.keys.sorted() == fixture.expected.keys.sorted())
        for (id, rec) in fixture.expected { #expect(got[id] == rec, "record \(id)") }
    }
}
