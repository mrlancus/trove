import Foundation
import Testing
@testable import TroveCore

/// Sketching tools (PROTOCOL.md §10). Fixtures/ink-geometry.json comes from
/// web/test/make-ink-fixture.mjs (ink.js), so both sides lasso, erase and snap shapes alike.
@Suite struct InkGeometryTests {
    struct Fixture: Decodable {
        struct ShapeCase: Decodable {
            struct Expect: Decodable { var shape: String; var points: [[Double]] }
            var name: String; var points: [[Double]]; var expect: Expect?
        }
        struct EraseCase: Decodable { var name: String; var points: [[Double]]; var path: [[Double]]; var radius: Double; var expect: [[[Double]]]? }
        struct Lasso: Decodable {
            struct P: Decodable { var x: Double; var y: Double; var inside: Bool }
            struct S: Decodable { var points: [[Double]]; var selected: Bool }
            var polygon: [[Double]]; var points: [P]; var strokes: [S]
        }
        struct Width: Decodable { var tool: String; var width: Double; var pressure: Double; var expect: Double }
        struct Fountain: Decodable { var dx: Double; var dy: Double; var pressure: Double; var expect: Double }
        struct Taper: Decodable { var index: Int; var count: Int; var expect: Double }
        struct Resampled: Decodable { var points: [[Double]]; var spacing: Double; var expect: [[Double]] }
        var shapes: [ShapeCase]; var erasing: [EraseCase]; var lasso: Lasso
        var widths: [Width]; var fountain: [Fountain]; var taper: [Taper]; var resampled: Resampled
    }

    static func points(_ a: [[Double]]) -> [InkPoint] {
        a.map { InkPoint(x: $0[0], y: $0[1], pressure: $0.count > 2 ? $0[2] : 0.5, t: $0.count > 3 ? $0[3] : 0) }
    }

    static func same(_ a: [InkPoint], _ b: [[Double]]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { p, q in
            abs(p.x - q[0]) < 1e-6 && abs(p.y - q[1]) < 1e-6 && abs(p.pressure - q[2]) < 1e-6 && abs(p.t - q[3]) < 1e-6
        }
    }

    func fixture() throws -> Fixture {
        let url = try #require(Bundle.module.url(forResource: "ink-geometry", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    @Test func shapesMatchTheWebsite() throws {
        let f = try fixture()
        #expect(f.shapes.count >= 10)
        for c in f.shapes {
            let got = InkShapes.recognize(Self.points(c.points))
            #expect(got?.shape.rawValue == c.expect?.shape, "\(c.name)")
            if let got, let expect = c.expect { #expect(Self.same(got.points, expect.points), "\(c.name)") }
        }
    }

    @Test func erasingLassoAndWidthsMatchTheWebsite() throws {
        let f = try fixture()
        for c in f.erasing {
            let got = InkGeometry.erase(Self.points(c.points), along: Self.points(c.path), radius: c.radius)
            #expect((got == nil) == (c.expect == nil), "\(c.name)")
            if let got, let expect = c.expect {
                #expect(got.count == expect.count, "\(c.name)")
                for (a, b) in zip(got, expect) { #expect(Self.same(a, b), "\(c.name)") }
            }
        }
        let polygon = Self.points(f.lasso.polygon)
        for p in f.lasso.points { #expect(InkGeometry.inside(p.x, p.y, polygon: polygon) == p.inside, "\(p.x),\(p.y)") }
        for s in f.lasso.strokes { #expect(InkGeometry.lassoSelects(Self.points(s.points), lasso: polygon) == s.selected) }
        for w in f.widths { #expect(abs(InkStroke.width(w.width, tool: InkTool(rawValue: w.tool)!, pressure: w.pressure) - w.expect) < 1e-9, "\(w.tool)") }
        for c in f.fountain { #expect(abs(InkGeometry.fountainWidth(10, pressure: c.pressure, dx: c.dx, dy: c.dy) - c.expect) < 1e-9) }
        for c in f.taper { #expect(abs(InkGeometry.brushTaper(index: c.index, count: c.count) - c.expect) < 1e-9) }
        #expect(Self.same(InkGeometry.resample(Self.points(f.resampled.points), spacing: f.resampled.spacing), f.resampled.expect))
    }

    @Test func pagesElementsLassoAndPartialErase() async throws {
        let lib = Library(engine: SyncEngine(device: "D", keys: .generate(), transports: []))
        let sketch = await lib.addSketch(paper: .lined)
        #expect(await lib.item(sketch)?.sketchPageList.map(\.id) == ["0"])

        // Old strokes on page 0 (a number) are on the page "0".
        await lib.addStroke(on: sketch, page: 0, tool: .pen, color: "#000000", width: 4, points: [InkPoint(x: 0, y: 0), InkPoint(x: 200, y: 0)])
        let second = try #require(await lib.addPage(to: sketch))
        await lib.setPage(second, of: sketch, paper: .music, color: "#fbf6e9")
        let a = try #require(await lib.addStroke(on: sketch, pageKey: second, tool: .fountain, color: "#112233", width: 6,
                                                 points: [InkPoint(x: 10, y: 10), InkPoint(x: 50, y: 50)]))
        let box = await lib.addElement(on: sketch, pageKey: second, kind: .text, frame: .init(x: 20, y: 20, width: 200, height: 40), text: "Buy milk")
        var item = try #require(await lib.item(sketch))
        #expect(item.sketchPageList.map(\.id) == ["0", second] && item.sketchPages == 2)
        #expect(item.sketchPageList[1].paper == .music && item.sketchPageList[1].color == "#fbf6e9")
        #expect(item.sketchText == "Buy milk")
        #expect(await lib.search("milk").map(\.id) == [sketch])
        #expect(await lib.strokes(on: sketch, pageKey: "0").count == 1)

        // Lasso: move and resize, recolour, duplicate.
        await lib.transformStrokes([a], by: InkGeometry.Transform(sx: 2, sy: 2, ox: 10, oy: 10, dx: 5, dy: 0), color: "#ff0000")
        let moved = try #require(await lib.strokes(on: sketch, pageKey: second).first)
        #expect(moved.points.map(\.x) == [15, 95] && moved.width == 12 && moved.color == "#ff0000")
        await lib.transformElements([box], by: .move(10, 10))
        #expect(await lib.elements(on: sketch, pageKey: second).first?.frame.x == 30)
        let copies = await lib.duplicateInk(strokes: [a], elements: [box], to: sketch, pageKey: second)
        let text = await lib.item(sketch)?.sketchText
        #expect(copies.count == 2 && text == "Buy milk\nBuy milk")

        // Duplicate, move and delete pages.
        let third = try #require(await lib.duplicatePage(second, of: sketch))
        let onThird = await lib.strokes(on: sketch, pageKey: third)
        #expect(onThird.count == 2)
        await lib.movePage(third, of: sketch, to: 0)
        item = try #require(await lib.item(sketch))
        #expect(item.sketchPageList.map(\.id) == [third, "0", second])
        await lib.deletePage(third, of: sketch)
        #expect(await lib.strokes(on: sketch, pageKey: third).isEmpty)
        #expect(await lib.item(sketch)?.sketchPageList.map(\.id) == ["0", second])

        // Partial erase: the line on page "0" splits in two and keeps its place in the drawing order.
        let before = try #require(await lib.strokes(on: sketch, pageKey: "0").first)
        let pieces = await lib.eraseStrokes(on: sketch, pageKey: "0", along: [InkPoint(x: 100, y: -20), InkPoint(x: 100, y: 20)], radius: 5)
        let after = await lib.strokes(on: sketch, pageKey: "0")
        #expect(pieces.count == 2 && after.count == 2 && after.allSatisfy { $0.createdAt == before.createdAt })
        // Erasing highlighter only leaves pen ink alone.
        let highlighterOnly = await lib.eraseStrokes(on: sketch, pageKey: "0", along: [InkPoint(x: 50, y: 0)], radius: 5, only: [.highlighter])
        #expect(highlighterOnly.isEmpty)

        // Undo brings back the very same records and fields.
        let sig = await lib.inkSignature(sketch)
        let kept = try #require(after.first)
        let saved = await lib.inkFields(kept.id, ["points", "color"])
        await lib.transformStrokes([kept.id], by: .move(100, 0), color: "#00ff00")
        await lib.setInkFields(kept.id, kind: "stroke", saved)
        let restored = try #require(await lib.strokes(on: sketch, pageKey: "0").first { $0.id == kept.id })
        #expect(restored.color == kept.color && restored.points == kept.points)
        await lib.setInk([(kept.id, "stroke")], alive: false)
        let gone = await lib.strokes(on: sketch, pageKey: "0").count
        await lib.setInk([(kept.id, "stroke")], alive: true)
        let back = await lib.strokes(on: sketch, pageKey: "0").count
        #expect(gone == 1 && back == 2)
        #expect(await lib.inkSignature(sketch) != sig)
        let inked = try #require(await lib.inkBounds(on: sketch, pageKey: "0"))
        #expect(inked.x < 0 && inked.maxX > 200)

        await lib.setSketchCanvas(sketch, infinite: true)
        #expect(await lib.item(sketch)?.isInfiniteCanvas == true)
        await lib.deleteElements([box])
        #expect(await lib.item(sketch)?.sketchText == "Buy milk")
    }
}

@Suite struct InkPaperTests {
    struct Case: Decodable {
        struct Area: Decodable { var x, y, w, h: Double }
        var paper: String
        var w, h: Double
        var area: Area?
        var shapes: [[String: JSONValue]]
    }

    @Test func papersMatchTheWebsite() throws {
        let url = Bundle.module.url(forResource: "ink-papers", withExtension: "json", subdirectory: "Fixtures")!
        struct File: Decodable { var cases: [Case] }
        let file = try JSONDecoder().decode(File.self, from: Data(contentsOf: url))
        #expect(file.cases.count == InkPaper.allCases.count * 2)
        func close(_ a: Double, _ b: JSONValue?) -> Bool { abs(a - (b?.number ?? .nan)) < 1e-6 }
        for c in file.cases {
            let paper = try #require(InkPaper(rawValue: c.paper))
            let area = c.area.map { InkGeometry.Rect(x: $0.x, y: $0.y, width: $0.w, height: $0.h) }
            let got = InkPaperShapes.shapes(paper, width: c.w, height: c.h, area: area)
            #expect(got.count == c.shapes.count, "\(c.paper) \(c.area == nil ? "page" : "endless")")
            for (g, e) in zip(got, c.shapes) {
                let ok: Bool = switch g {
                case .hline(let y, let x0, let x1, let r): e["k"]?.string == "h" && close(y, e["y"]) && close(x0, e["x0"]) && close(x1, e["x1"]) && e["r"]?.string == r.rawValue
                case .vline(let x, let y0, let y1, let r): e["k"]?.string == "v" && close(x, e["x"]) && close(y0, e["y0"]) && close(y1, e["y1"]) && e["r"]?.string == r.rawValue
                case .dot(let x, let y, let d): e["k"]?.string == "dot" && close(x, e["x"]) && close(y, e["y"]) && close(d, e["d"])
                case .box(let x, let y, let w, let h, let r): e["k"]?.string == "box" && close(x, e["x"]) && close(y, e["y"]) && close(w, e["w"]) && close(h, e["h"]) && e["r"]?.string == r.rawValue
                }
                #expect(ok, "\(c.paper): \(g) vs \(e)")
                if !ok { break }
            }
        }
    }
}
