import Foundation
import Testing
@testable import TroveCore

/// What the drawing editor leans on while the lasso moves things and the pen writes: nothing may
/// trap on odd numbers (a crash on iPad), and reloading a page's ink stays cheap.
@Suite struct InkSafetyTests {
    func makeLibrary() -> Library { Library(engine: SyncEngine(device: "D", keys: .generate(), transports: [])) }

    /// A sketch with `count` strokes, written straight to the engine (no per-stroke lookups).
    func sketch(_ lib: Library, strokes count: Int) async -> String {
        let id = await lib.addSketch()
        for i in 0..<count {
            var pts: [InkPoint] = []
            for k in 0..<30 {
                let x = Double(i % 700) + Double(k), y = Double(i / 700) * 40 + Double(k % 7)
                pts.append(InkPoint(x: x, y: y, pressure: 0.6, t: Double(k) * 8))
            }
            let created = Double(1_700_000_000_000 + (i * 7919) % count)
            _ = await lib.engine.set([
                InkStroke.Field.on: .string(id), InkStroke.Field.layer: .string(""), InkStroke.Field.page: .string("0"),
                InkStroke.Field.tool: .string("pen"), InkStroke.Field.color: .string("#000000"), InkStroke.Field.width: .number(2),
                InkStroke.Field.points: .string(InkPoints.encode(pts)), InkStroke.Field.createdAt: .number(created),
            ], record: "s\(i)", kind: "stroke")
        }
        return id
    }

    @Test func numbersThatArentRealDontStopTheApp() async {
        let nan = Double.nan, inf = Double.infinity
        let bad = [InkPoint(x: 0, y: 0), InkPoint(x: nan, y: 5), InkPoint(x: 10, y: inf), InkPoint(x: 20, y: 0)]
        // The partial eraser cuts lines into short pieces: Int(NaN / spacing) used to trap.
        #expect(InkGeometry.resample(bad, spacing: 2).count >= bad.count)
        _ = InkGeometry.erase(bad, along: [InkPoint(x: 10, y: -5), InkPoint(x: 10, y: 5)], radius: 3)
        // A huge gap is cut into at most 100,000 steps, not billions.
        #expect(InkGeometry.resample([InkPoint(x: 0, y: 0), InkPoint(x: 1e12, y: 0)], spacing: 1).count <= 100_002)
        // Outlines skip what can't be drawn.
        let outline = InkOutline.outline(tool: .pen, width: 4, points: bad)
        #expect(outline?.isEmpty == false && outline!.allSatisfy { $0.x.isFinite && $0.y.isFinite })
        #expect(InkOutline.outline(tool: .brush, width: 4, points: [InkPoint(x: nan, y: nan)]) == [])
        // The page grid ignores boxes that aren't boxes.
        var grid = InkGrid()
        grid.add("neg", InkGeometry.Rect(x: 0, y: 0, width: -500, height: 10))
        grid.add("nan", InkGeometry.Rect(x: nan, y: 0, width: 5, height: 5))
        grid.add("ok", InkGeometry.Rect(x: 0, y: 0, width: 5, height: 5))
        #expect(grid.query(InkGeometry.Rect(x: -1000, y: -1000, width: 3000, height: 3000)) == ["ok"])
        #expect(grid.query(InkGeometry.Rect(x: nan, y: nan, width: nan, height: nan)).isEmpty)
        // Page numbers from another device that aren't whole numbers an Int can hold.
        #expect(InkPage.key(.number(nan)) == "0" && InkPage.key(.number(1e300)) == "0" && InkPage.key(.number(3)) == "3")
        let stroke = InkStroke(Record(id: "s", kind: "stroke", fields: ["page": .number(-inf)], createdHLC: "", updatedHLC: ""))
        #expect(stroke.page == 0 && stroke.pageKey == "0")
        let huge = Item(Record(id: "i", kind: "item", fields: ["kind": .string("sketch"), "pages": .number(1e12)], createdHLC: "", updatedHLC: ""))
        #expect(huge.sketchPageList.count == 1000)
        let nanPages = Item(Record(id: "j", kind: "item", fields: ["kind": .string("sketch"), "pages": .number(nan)], createdHLC: "", updatedHLC: ""))
        #expect(nanPages.sketchPageList.count == 1)
    }

    @Test func lassoMovesThatArentRealAreNotStored() async {
        let lib = makeLibrary()
        let sketch = await lib.addSketch()
        let pts = [InkPoint(x: 10, y: 10), InkPoint(x: 20, y: 30)]
        let id = await lib.addStroke(on: sketch, pageKey: "0", tool: .pen, color: "#000000", width: 2, points: pts)!
        let box = await lib.addElement(on: sketch, pageKey: "0", kind: .text, frame: InkGeometry.Rect(x: 5, y: 5, width: 100, height: 20), text: "hi")
        #expect(InkGeometry.Transform.move(5, 5).isUsable && InkGeometry.Transform(sx: 2, sy: 2, ox: 10, oy: 10).isUsable)
        for t in [InkGeometry.Transform(sx: .nan, sy: 1), .move(.infinity, 0), InkGeometry.Transform(sx: 0, sy: 0), InkGeometry.Transform(sx: 1e9, sy: 1e9)] {
            #expect(!t.isUsable)
            await lib.transformStrokes([id], by: t)
            await lib.transformElements([box], by: t)
            #expect(await lib.duplicateInk(strokes: [id], elements: [box], to: sketch, pageKey: "0", by: t).isEmpty)
        }
        #expect(await lib.strokes(on: sketch).first?.points == pts)
        #expect(await lib.elements(on: sketch).first?.frame == InkGeometry.Rect(x: 5, y: 5, width: 100, height: 20))
        // A real move still lands.
        await lib.transformStrokes([id], by: .move(5, 0))
        #expect(await lib.strokes(on: sketch).first?.points.first?.x == 15)
    }

    @Test func ballpointKeepsOneThickness() async {
        #expect(InkTool(rawValue: "ballpoint") == .ballpoint && !InkTool.ballpoint.usesPressure && InkTool.ballpoint.opacity == 1)
        for p in [0.0, 0.3, 1] { #expect(InkStroke.width(3, tool: .ballpoint, pressure: p) == 3) }
        let pts = [InkPoint(x: 0, y: 0, pressure: 0.1), InkPoint(x: 30, y: 4, pressure: 0.9, t: 16), InkPoint(x: 60, y: 0, pressure: 0.4, t: 32)]
        // Drawn as one even line, its width whatever the pressure.
        #expect(InkOutline.outline(tool: .ballpoint, width: 3, points: pts) == nil)
        #expect(InkOutline.lineWidth(tool: .ballpoint, width: 3, points: pts) == 3)
        let lib = makeLibrary()
        let sketch = await lib.addSketch()
        await lib.addStroke(on: sketch, pageKey: "0", tool: .ballpoint, color: "#1c1c1e", width: 3, points: pts)
        await lib.addStroke(on: sketch, page: 0, tool: .ballpoint, color: "#1c1c1e", width: 3, points: pts)
        await lib.setCompactPoints(true)
        await lib.addStroke(on: sketch, pageKey: "0", tool: .ballpoint, color: "#1c1c1e", width: 3, points: pts)
        await lib.addStroke(on: sketch, pageKey: "0", tool: .pen, color: "#1c1c1e", width: 3, points: pts)
        let stored = await lib.strokes(on: sketch)
        #expect(stored.map(\.tool) == [.ballpoint, .ballpoint, .ballpoint, .pen])
        // Stored at pressure 1: a Trove that doesn't know the ballpoint draws it as a pen, at full width all along.
        for s in stored.prefix(3) {
            #expect(s.points.allSatisfy { $0.pressure == 1 })
            #expect(s.points.allSatisfy { InkStroke.width(3, tool: .pen, pressure: $0.pressure) == 3 })
        }
        #expect(stored[3].points.map(\.pressure) != [1, 1, 1])
        // An unknown tool still reads as a pen.
        let future = InkStroke(Record(id: "f", kind: "stroke", fields: ["tool": .string("gelpen")], createdHLC: "", updatedHLC: ""))
        #expect(future.tool == .pen)
        // Favourites and pen settings know it.
        let settings = InkSettings(fields: ["favourites": .array([InkFavourite(tool: .ballpoint, color: "#000000", width: 2).json])])
        #expect(settings.favourites.first?.tool == .ballpoint && settings.pens[.ballpoint] != nil)
    }

    @Test func reloadingAPageOfInkStaysCheap() async {
        let lib = makeLibrary()
        let id = await sketch(lib, strokes: 3000)
        let clock = ContinuousClock()
        var strokes: [InkStroke] = []
        let list = await clock.measure { for _ in 0..<5 { strokes = await lib.strokes(on: id) } }
        let sig = await clock.measure { for _ in 0..<5 { _ = await lib.inkSignature(id) } }
        let layers = await clock.measure { for _ in 0..<5 { _ = await lib.inkedLayers() } }
        print("ink reload, 3,000 strokes: strokes(on:) \(list / 5), inkSignature \(sig / 5), inkedLayers \(layers / 5)")
        #expect(strokes.count == 3000)
        // Oldest first, ties by id: the order strokes are drawn in.
        #expect(zip(strokes, strokes.dropFirst()).allSatisfy { a, b in a.createdAt != b.createdAt ? a.createdAt < b.createdAt : a.id < b.id })
    }
}
