import Foundation
import Testing
@testable import TroveCore

/// Drawing (PROTOCOL.md §10). Fixtures/ink-cases.json is shared with web/test/core.test.mjs.
@Suite struct InkTests {
    struct Cases: Decodable {
        struct Width: Decodable { var tool: String; var width: Double; var pressure: Double; var expect: Double }
        struct Colour: Decodable { var hex: String; var rgb: [Double] }
        var points: [[Double]]
        var encoded: String
        var widths: [Width]
        var colors: [Colour]
    }

    func makeLibrary() -> Library { Library(engine: SyncEngine(device: "D", keys: .generate(), transports: [])) }

    @Test func packedPointsWidthsAndColoursMatchTheWebsite() throws {
        let url = try #require(Bundle.module.url(forResource: "ink-cases", withExtension: "json", subdirectory: "Fixtures"))
        let cases = try JSONDecoder().decode(Cases.self, from: Data(contentsOf: url))
        let points = cases.points.map { InkPoint(x: $0[0], y: $0[1], pressure: $0[2], t: $0[3]) }
        #expect(InkPoints.encode(points) == cases.encoded)
        #expect(InkPoints.decode(cases.encoded) == points)
        for w in cases.widths {
            #expect(abs(InkStroke.width(w.width, tool: InkTool(rawValue: w.tool)!, pressure: w.pressure) - w.expect) < 1e-9)
        }
        for c in cases.colors {
            let (r, g, b) = InkStroke.rgb(c.hex)
            #expect(abs(r - c.rgb[0]) < 1e-4 && abs(g - c.rgb[1]) < 1e-4 && abs(b - c.rgb[2]) < 1e-4)
        }
    }

    @Test func sketchesAndStrokes() async {
        let lib = makeLibrary()
        let sketch = await lib.addSketch(paper: .grid)
        let item = await lib.item(sketch)
        #expect(item?.kind == .sketch && item?.paper == .grid && item?.sketchPages == 1 && item?.displayTitle == "Sketch")
        let folders = await lib.folders()
        #expect(folders.first { $0.id == item?.folder }?.name == "Sketches")
        let pts = [InkPoint(x: 1, y: 2, pressure: 0.5), InkPoint(x: 3, y: 4, pressure: 0.75, t: 10)]
        let a = await lib.addStroke(on: sketch, page: 0, tool: .pen, color: "#123456", width: 3, points: pts)
        let b = await lib.addStroke(on: sketch, page: 1, tool: .highlighter, color: "#ffee00", width: 20, points: pts)
        let c = await lib.addStroke(on: "pdf", layer: "blob", page: 2, tool: .marker, color: "#ff0000", width: 6, points: pts)
        #expect(await lib.addStroke(on: sketch, page: 0, tool: .pen, color: "#000000", width: 2, points: []) == nil)
        #expect(await lib.strokes(on: sketch).map(\.id) == [a, b].compactMap { $0 })
        #expect(await lib.strokes(on: sketch, page: 1).map(\.id) == [b].compactMap { $0 })
        let onPDF = await lib.strokes(on: "pdf", layer: "blob")
        #expect(onPDF.map(\.id) == [c].compactMap { $0 } && onPDF.first?.page == 2 && onPDF.first?.tool == .marker && onPDF.first?.points == pts)
        await lib.deleteStrokes([a].compactMap { $0 })
        #expect(await lib.strokes(on: sketch).map(\.id) == [b].compactMap { $0 })
        await lib.setSketch(sketch, paper: .dotted, pages: 4)
        let updated = await lib.item(sketch)
        #expect(updated?.sketchPages == 4 && updated?.paper == .dotted)
        #expect(await lib.inkedLayers()["pdf"] == ["blob"])
    }
}
