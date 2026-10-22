import Foundation
import Testing
@testable import TroveCore

/// PDF text for search, highlights, quotes, page boxes and form values (PROTOCOL.md §10 "PDF text,
/// highlights and forms"). Fixtures/pdf-cases.json comes from web/test/make-pdf-fixture.mjs
/// (core/pdfmarks.js), so the website and the apps agree.
@Suite struct PDFMarksTests {
    struct Box: Decodable { var x: Double?; var y: Double?; var w: Double?; var h: Double? }
    struct Abs: Decodable { var x: Double; var y: Double; var w: Double; var h: Double }
    struct Fixture: Decodable {
        struct Text: Decodable {
            var name: String; var pages: [String]?; var repeated: [[RepeatPart]]?
            var expected: String?; var expectedLength: Int?; var expectedTail: String?
            enum CodingKeys: String, CodingKey { case name, pages, repeated = "repeat", expected, expectedLength, expectedTail }
        }
        enum RepeatPart: Decodable {
            case text(String), times(Int)
            init(from decoder: Decoder) throws {
                let c = try decoder.singleValueContainer()
                if let n = try? c.decode(Int.self) { self = .times(n) } else { self = .text(try c.decode(String.self)) }
            }
        }
        struct Quote: Decodable { var input: String; var expected: String }
        struct Highlight: Decodable {
            struct Expect: Decodable { var x: Double; var y: Double; var w: Double; var h: Double; var rects: [[Double]] }
            var name: String; var boxes: [Box]; var expected: Expect?; var absolute: [Abs]?
        }
        struct PageBox: Decodable { var view: [Double]; var rotate: Int; var points: [[Double]]; var size: [Double]; var page: [[Double]]; var back: [[Double]] }
        struct FieldId: Decodable { var item: String; var layer: String; var name: String; var id: String }
        struct Elements: Decodable { var records: [RecordJSON]; var sketchText: String; var absolute: [String: [Abs]] }
        struct RecordJSON: Decodable { var id: String; var fields: [String: JSONValue] }
        var text: [Text]; var quotes: [Quote]; var highlights: [Highlight]; var boxes: [PageBox]; var fieldIds: [FieldId]; var elements: Elements
    }

    func fixture() throws -> Fixture {
        let url = try #require(Bundle.module.url(forResource: "pdf-cases", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    static func pages(_ c: Fixture.Text) -> [String] {
        if let pages = c.pages { return pages }
        return (c.repeated ?? []).map { parts -> String in
            guard parts.count == 2, case .text(let s) = parts[0], case .times(let n) = parts[1] else { return "" }
            return String(repeating: s, count: n)
        }
    }

    @Test func textMatchesTheWebsite() throws {
        let f = try fixture()
        for c in f.text {
            let out = PDFText.join(Self.pages(c))
            if let expected = c.expected {
                #expect(out == expected, "\(c.name)")
            } else {
                #expect(out.unicodeScalars.count == c.expectedLength, "\(c.name)")
                var tail = String.UnicodeScalarView()
                tail.append(contentsOf: out.unicodeScalars.suffix(5))
                #expect(String(tail) == c.expectedTail, "\(c.name)")
            }
        }
        for q in f.quotes { #expect(PDFText.cleanQuote(q.input) == q.expected) }
    }

    @Test func highlightGeometryMatchesTheWebsite() throws {
        let f = try fixture()
        for c in f.highlights {
            let boxes = c.boxes.map { InkGeometry.Rect(x: $0.x ?? .nan, y: $0.y ?? .nan, width: $0.w ?? .nan, height: $0.h ?? .nan) }
            let g = HighlightGeometry.make(boxes)
            guard let e = c.expected else { #expect(g == nil, "\(c.name)"); continue }
            let made = try #require(g, "\(c.name)")
            #expect(made.frame == InkGeometry.Rect(x: e.x, y: e.y, width: e.w, height: e.h), "\(c.name)")
            #expect(made.rects == e.rects, "\(c.name)")
            let pieces = HighlightGeometry.pieces(frame: made.frame, rects: made.rects)
            let abs = c.absolute ?? []
            #expect(pieces.count == abs.count, "\(c.name)")
            for (p, a) in zip(pieces, abs) {
                #expect(p.x == a.x && p.y == a.y && p.width == a.w && p.height == a.h, "\(c.name)")
            }
        }
    }

    @Test func pageBoxesAndFieldIdsMatchTheWebsite() throws {
        let f = try fixture()
        for c in f.boxes {
            let b = PDFPageBox(view: c.view, rotate: c.rotate)
            #expect([b.width, b.height] == c.size)
            for (i, p) in c.points.enumerated() {
                let page = b.toPage(p[0], p[1])
                #expect([page.x, page.y] == c.page[i], "rotate \(c.rotate)")
                let back = b.toPDF(page.x, page.y)
                #expect([back.x, back.y] == c.back[i], "rotate \(c.rotate)")
            }
        }
        for id in f.fieldIds { #expect(PDFForm.elementId(item: id.item, layer: id.layer, name: id.name) == id.id) }
    }

    @Test func elementsReadAsTheWebsiteReadsThem() throws {
        let f = try fixture()
        let elements = f.elements.records.map { InkElement(Record(id: $0.id, kind: "element", fields: $0.fields, createdHLC: "", updatedHLC: "")) }
        #expect(elements.map(\.kind) == [.text, .highlight, .field, .highlight])
        #expect(elements.dropFirst().allSatisfy { $0.text.isEmpty }, "old readers draw nothing")
        #expect(elements[2].fieldName == "agree" && elements[2].fieldValue == .bool(true))
        for (id, rects) in f.elements.absolute {
            let e = try #require(elements.first { $0.id == id })
            let pieces = e.highlightPieces
            #expect(pieces.count == rects.count)
            for (p, a) in zip(pieces, rects) {
                #expect(abs(p.x - a.x) < 1e-9 && abs(p.y - a.y) < 1e-9 && abs(p.width - a.w) < 1e-9 && abs(p.height - a.h) < 1e-9, "\(id)")
            }
        }
    }

    func makeLibrary() -> Library { Library(engine: SyncEngine(device: "D", keys: .generate(), transports: [])) }

    @Test func highlightsQuotesFormValuesAndText() async throws {
        let lib = makeLibrary()
        let id = try await lib.addFile(Data("%PDF-1.7".utf8), name: "Form.pdf", mime: "application/pdf")
        let att = try #require(await lib.item(id)?.attachments.first?.id)
        let boxes = [InkGeometry.Rect(x: 72, y: 90, width: 200, height: 12), InkGeometry.Rect(x: 72, y: 104, width: 150, height: 12)]
        let hl = try #require(await lib.addHighlight(on: id, layer: att, pageKey: "0", boxes: boxes, quote: "The quick brown\nfox"))
        let e = try #require(await lib.elements(on: id, layer: att).first { $0.id == hl })
        #expect(e.kind == .highlight && e.quote == "The quick brown fox" && e.rects?.count == 2)
        #expect(await lib.item(id)?.sketchText == "The quick brown fox")
        #expect(await lib.addHighlight(on: id, layer: att, pageKey: "0", boxes: [], quote: "x") == nil)
        let copies = await lib.duplicateInk(strokes: [], elements: [hl], to: id, layer: att, pageKey: "0")
        let copy = try #require(await lib.elements(on: id, layer: att).first { $0.id == copies.first })
        #expect(copy.quote == e.quote && copy.rects == e.rects)

        let q = try #require(await lib.addQuote(e.quote, from: id, page: 0))
        let quote = try #require(await lib.item(q))
        #expect(quote.kind == .highlight && quote.links == [id])
        #expect(quote.body == "> The quick brown fox\n\n— Form (p. 1)")

        let frame = InkGeometry.Rect(x: 120, y: 178, width: 200, height: 20)
        let f = await lib.setPDFField(on: id, layer: att, pageKey: "0", name: "name", value: "Ada", frame: frame)
        #expect(f == PDFForm.elementId(item: id, layer: att, name: "name"))
        await lib.setPDFField(on: id, layer: att, pageKey: "0", name: "agree", value: .bool(true), frame: frame)
        #expect(await lib.setPDFField(on: id, layer: att, pageKey: "0", name: "bad", value: .number(1), frame: frame) == nil)
        let fields = await lib.pdfFields(on: id, layer: att)
        #expect(fields["name"]?.fieldValue == .string("Ada") && fields["agree"]?.fieldValue == .bool(true) && fields.count == 2)
        #expect(await lib.item(id)?.fileVersions.isEmpty == true, "the file never changes")

        await lib.setPDFText(id, "Some text from the PDF that is long enough to keep.")
        #expect(await lib.item(id)?.ocrText == "Some text from the PDF that is long enough to keep.")
    }
}
