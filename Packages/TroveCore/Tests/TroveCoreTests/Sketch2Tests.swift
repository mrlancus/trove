import Foundation
import Testing
@testable import TroveCore

/// Sketch 2 (docs/plans/sketch-2-plan.md): the stress notebook, handwriting freshness, consent.
struct InkStressTests {
    @Test func sameSeedSameStrokes() {
        let a = InkStress.strokes(page: 3, count: 200)
        let b = InkStress.strokes(page: 3, count: 200)
        #expect(a == b)
        #expect(a.count == 200)
        #expect(InkStress.strokes(page: 4, count: 200) != a)
        for s in a {
            #expect(!s.points.isEmpty)
            #expect(s.points.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.x >= 0 && $0.x <= 612 && $0.y >= 0 && $0.y <= 792 })
        }
    }

    @Test func notebookHasEveryPageAndStroke() async {
        let lib = Library(engine: SyncEngine(device: "D", keys: nil, encrypted: false))
        let id = await lib.addStressNotebook(pages: 3, strokesPerPage: 40)
        let pages = await lib.item(id)!.sketchPageList
        #expect(pages.count == 3)
        for p in pages {
            let n = await lib.strokes(on: id, pageKey: p.id).count
            #expect(n == 40)
        }
    }
}

struct HandwritingFreshnessTests {
    let pages: [(key: String, sig: String)] = [("a", "1"), ("b", "2"), ("c", "3")]

    @Test func clearedCacheReadsEverything() {
        // The synced signature matches, but this device holds nothing: every page is read.
        #expect(HandwritingFreshness.pagesToRead(pages, local: [:]) == ["a", "b", "c"])
        #expect(!HandwritingFreshness.upToDate(pages, local: [:]))
    }

    @Test func onlyChangedPagesAreRead() {
        #expect(HandwritingFreshness.pagesToRead(pages, local: ["a": "1", "b": "old", "c": "3"]) == ["b"])
        #expect(HandwritingFreshness.upToDate(pages, local: ["a": "1", "b": "2", "c": "3"]))
    }
}

struct PictureConsentTests {
    @Test func asksOncePerSessionByDefault() {
        #expect(PictureConsent.decide(.askEachSession, session: nil) == .ask)
        let r = PictureConsent.apply(.allowSession, setting: .askEachSession)
        #expect(r.send && r.session == true && r.setting == .askEachSession)
        #expect(PictureConsent.decide(r.setting, session: r.session) == .send)
    }

    @Test func alwaysAndNever() {
        let r = PictureConsent.apply(.allowAlways, setting: .askEachSession)
        #expect(r.setting == .always)
        #expect(PictureConsent.decide(.always, session: nil) == .send)
        #expect(PictureConsent.decide(.never, session: true) == .skip)
    }

    @Test func onceAndNotNowAskAgain() {
        let once = PictureConsent.apply(.allowOnce, setting: .askEachSession)
        #expect(once.send && once.session == nil)
        let no = PictureConsent.apply(.notNow, setting: .askEachSession)
        #expect(!no.send && PictureConsent.decide(no.setting, session: no.session) == .ask)
    }
}

struct InkTessellatorTests {
    func area(_ p: InkTessellator.Part) -> Double {
        var a = 0.0
        for t in stride(from: 0, to: p.indices.count, by: 3) {
            let i = Int(p.indices[t]) * 2, j = Int(p.indices[t + 1]) * 2, k = Int(p.indices[t + 2]) * 2
            let x0 = Double(p.positions[i]), y0 = Double(p.positions[i + 1]), x1 = Double(p.positions[j]), y1 = Double(p.positions[j + 1])
            let x2 = Double(p.positions[k]), y2 = Double(p.positions[k + 1])
            a += abs((x1 - x0) * (y2 - y0) - (y1 - y0) * (x2 - x0)) / 2
        }
        return a
    }

    func valid(_ p: InkTessellator.Part) -> Bool {
        p.positions.allSatisfy(\.isFinite) && p.indices.count % 3 == 0 && p.indices.allSatisfy { Int($0) < p.vertexCount }
    }

    @Test func markerLineCoversItsArea() {
        // A straight marker line 100 long, 6 wide: a rectangle and two half circles.
        let pts = (0...10).map { InkPoint(x: Double($0) * 10, y: 50, pressure: 0.5) }
        let parts = InkTessellator.parts(tool: .marker, color: "#000000", width: 6, points: pts)
        #expect(parts.count == 1)
        let p = parts[0]
        #expect(valid(p))
        let r = InkOutline.lineWidth(tool: .marker, width: 6, points: pts) / 2
        let expected = 100 * 2 * r + Double.pi * r * r
        #expect(abs(area(p) - expected) / expected < 0.05)
    }

    @Test func penOutlineMatchesItsPolygon() {
        let pts = (0...40).map { i -> InkPoint in
            let t = Double(i) / 40
            return InkPoint(x: 20 + t * 200, y: 100 + sin(t * 3) * 10, pressure: 0.3 + 0.5 * t)
        }
        let parts = InkTessellator.parts(tool: .pen, color: "#000000", width: 3, points: pts)
        #expect(parts.count == 1)
        #expect(valid(parts[0]))
        // The outline polygon's area (shoelace) vs the triangles': the same shape (gentle curve, no overlap).
        let o = InkOutline.outline(tool: .pen, width: 3, points: pts)!
        var a = 0.0
        for i in 0..<o.count { let p = o[i], q = o[(i + 1) % o.count]; a += p.x * q.y - q.x * p.y }
        a = abs(a) / 2
        #expect(abs(area(parts[0]) - a) / a < 0.03)
    }

    @Test func dotsDashesFillsAndArrows() {
        let line = [InkPoint(x: 0, y: 0), InkPoint(x: 100, y: 0)]
        let dashed = InkTessellator.parts(tool: .pen, color: "#000", width: 2, points: line, shape: "line", style: InkStrokeStyle(dash: "dash"))
        #expect(valid(dashed[0]))
        // 100 long with 6-on, 4-off dashes: 10 pieces, so less area than a solid line but more than half.
        let solid = InkTessellator.parts(tool: .pen, color: "#000", width: 2, points: line, shape: "line")
        #expect(area(dashed[0]) < area(solid[0]) && area(dashed[0]) > area(solid[0]) * 0.5)
        let square = [InkPoint(x: 0, y: 0), InkPoint(x: 10, y: 0), InkPoint(x: 10, y: 10), InkPoint(x: 0, y: 10), InkPoint(x: 0, y: 0)]
        let filled = InkTessellator.parts(tool: .pen, color: "#000", width: 1, points: square, shape: "rectangle", style: InkStrokeStyle(fill: "#ff0000"))
        #expect(filled.count == 2 && filled[0].color == "#ff0000")
        #expect(abs(area(filled[0]) - 100) < 1e-6)
        let arrow = InkTessellator.parts(tool: .pen, color: "#000", width: 2, points: line, shape: "line", style: InkStrokeStyle(arrow: "end"))
        #expect(valid(arrow[0]) && arrow[0].triangleCount > solid[0].triangleCount)
        let star = (0..<10).map { i -> InkPoint in
            let a = Double(i) * Double.pi / 5, r = i % 2 == 0 ? 10.0 : 4.0
            return InkPoint(x: r * cos(a), y: r * sin(a))
        }
        let starFill = InkTessellator.parts(tool: .pen, color: "#000", width: 1, points: star, shape: "star", style: InkStrokeStyle(fill: "#00ff00"))
        var shoelace = 0.0
        for i in 0..<star.count { let p = star[i], q = star[(i + 1) % star.count]; shoelace += p.x * q.y - q.x * p.y }
        #expect(abs(area(starFill[0]) - abs(shoelace) / 2) < 1e-6)
    }

    @Test func everyStressStrokeIsValid() {
        for s in InkStress.strokes(page: 0, count: 300) {
            for p in InkTessellator.parts(tool: s.tool, color: s.color, width: s.width, points: s.points) { #expect(valid(p)) }
        }
        #expect(InkTessellator.parts(tool: .pen, color: "#000", width: 2, points: [InkPoint(x: 1, y: 1)])[0].triangleCount > 8)
        #expect(InkTessellator.parts(tool: .pen, color: "#000", width: 2, points: []).isEmpty)
    }
}

struct EditorLayoutTests {
    @Test func customHundredPercent() {
        var b = ZoomBase()
        #expect(b.isOriginal && b.label(1.5) == "150%")
        b = ZoomBase(base: 1.25)
        #expect(b.label(1.25) == "100%" && b.label(2.5) == "200%")
        #expect(abs(b.zoom(forPercent: 200) - 2.5) < 1e-9)
        #expect(b.toggle(from: 2.5, previous: nil) == 1.25)
        #expect(b.toggle(from: 1.25, previous: 3) == 3)
        #expect(ZoomBase(base: 50).base == 10 && ZoomBase(base: .nan).base == 1)
    }

    @Test func toolbarFoldsInOrder() {
        let widths: [ToolbarFold.Group: Double] = [.core: 400, .sizes: 80, .colours: 120, .insert: 40, .title: 120, .shapesAndText: 80]
        #expect(ToolbarFold.folded(width: 900, widths: widths).isEmpty)
        #expect(ToolbarFold.folded(width: 780, widths: widths) == [.sizes])
        #expect(ToolbarFold.folded(width: 600, widths: widths) == [.sizes, .colours, .insert])
        #expect(ToolbarFold.folded(width: 390, widths: widths) == Set(ToolbarFold.order))
    }

    @Test func hudNeverOverlaps() {
        let area = InkGeometry.Rect(x: 0, y: 0, width: 800, height: 600)
        let items = [
            HUDPlacement.Item(id: "zoom", size: .init(140, 36), anchor: .bottomLeading, priority: 10),
            HUDPlacement.Item(id: "selection", size: .init(700, 80), anchor: .bottomCentre, priority: 5),
            HUDPlacement.Item(id: "ask", size: .init(300, 400), anchor: .fixed(InkGeometry.Rect(x: 480, y: 40, width: 300, height: 400)), priority: 20),
        ]
        let placed = HUDPlacement.place(items, in: area)
        #expect(placed.count == 3)
        let rects = Array(placed.values)
        for i in rects.indices {
            for j in rects.indices where j > i {
                let a = rects[i], b = rects[j]
                #expect(!(a.x < b.maxX && b.x < a.maxX && a.y < b.maxY && b.y < a.maxY))
            }
        }
        // The zoom pill keeps its corner; the selection bar goes above it.
        #expect(placed["zoom"]!.x == 8 && placed["zoom"]!.maxY == 592)
        #expect(placed["selection"]!.maxY <= placed["zoom"]!.y)
    }
}

struct InkHandwritingTests {
    func strokeBoxes(_ r: InkHandwriting.Result) -> [InkGeometry.Rect] { r.strokes.compactMap { InkGeometry.bounds($0) } }

    @Test func deterministicAndFinite() {
        var o = InkHandwriting.Options()
        o.seed = 42
        let a = InkHandwriting.write("x = 3/4, hello world", at: InkPoint(x: 10, y: 50), options: o)
        let b = InkHandwriting.write("x = 3/4, hello world", at: InkPoint(x: 10, y: 50), options: o)
        #expect(a.strokes == b.strokes)
        #expect(!a.strokes.isEmpty && a.lines == 1)
        #expect(a.strokes.allSatisfy { $0.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.pressure > 0 && $0.pressure <= 1 } })
        // Times only go forward.
        let times = a.strokes.flatMap { $0.map(\.t) }
        #expect(zip(times, times.dropFirst()).allSatisfy { $0 <= $1 })
        let script = InkHandwriting.write("hello", at: InkPoint(x: 0, y: 0), options: { var s = o; s.style = .script; return s }())
        #expect(!script.strokes.isEmpty)
    }

    @Test func sitsOnItsBaselineAtItsSize() {
        var o = InkHandwriting.Options()
        o.xHeight = 10
        o.variation = 0
        let r = InkHandwriting.write("xxxx", at: InkPoint(x: 0, y: 100), options: o)
        let b = r.bounds!
        // An x: from the baseline up about one x-height.
        #expect(abs(b.maxY - 100) < 1.5)
        #expect(abs(b.height - 10) < 2.5)
    }

    @Test func wrapsAndFits() {
        var o = InkHandwriting.Options()
        o.xHeight = 6
        let box = InkGeometry.Rect(x: 0, y: 0, width: 120, height: 200)
        let r = InkHandwriting.fit("the mitochondria is the powerhouse of the cell", in: box, options: o)!
        #expect(r.lines > 1)
        #expect(r.bounds!.maxX <= box.maxX + 4)
        #expect(InkHandwriting.fit("a very long answer that cannot fit", in: InkGeometry.Rect(x: 0, y: 0, width: 30, height: 10), options: o) == nil)
    }

    @Test func matchesTheWritingAround() {
        // "Someone's" writing at x-height 9 on a line, then a gap on that line to fill.
        for size in [5.0, 9.0, 14.0] {
            var o = InkHandwriting.Options()
            o.xHeight = size
            o.seed = 7
            let theirs = InkHandwriting.write("the answer is", at: InkPoint(x: 20, y: 200), options: o)
            let gap = InkGeometry.Rect(x: 20 + theirs.bounds!.width + 20, y: 200 - size * 1.5, width: 80, height: size * 2)
            let got = InkHandwriting.sizeNear(gap, strokes: strokeBoxes(theirs))
            #expect(abs(got - size) / size < 0.25, "size \(size) got \(got)")
        }
        // Nothing near: the ruling, then the box, then 7.
        #expect(abs(InkHandwriting.sizeNear(InkGeometry.Rect(x: 0, y: 0, width: 50, height: 0), strokes: [], ruling: 32) - 13.44) < 0.01)
        #expect(InkHandwriting.sizeNear(InkGeometry.Rect(x: 0, y: 0, width: 50, height: 0), strokes: []) == 7)
        // Vision's line box on the same line wins.
        let line = InkGeometry.Rect(x: 0, y: 90, width: 200, height: 24)
        #expect(abs(InkHandwriting.sizeNear(InkGeometry.Rect(x: 210, y: 95, width: 40, height: 14), strokes: [], lines: [line]) - 10) < 0.01)
    }

    @Test func fastEnough() {
        let text = String(repeating: "the quick brown fox jumps over the lazy dog ", count: 23)
        var o = InkHandwriting.Options()
        o.maxWidth = 400
        let start = Date()
        let r = InkHandwriting.write(text, at: InkPoint(x: 0, y: 0), options: o)
        #expect(r.lines > 5)
        #expect(Date().timeIntervalSince(start) < 0.5)
    }
}

struct StrokeByTests {
    @Test func byRoundTrips() async {
        let lib = Library(engine: SyncEngine(device: "D", keys: nil, encrypted: false))
        let id = await lib.addSketch(title: "Maths")
        let page = await lib.item(id)!.sketchPageList[0].id
        let mine = await lib.addStroke(on: id, pageKey: page, tool: .pen, color: "#000", width: 2, points: [InkPoint(x: 1, y: 1), InkPoint(x: 2, y: 2)])!
        let answer = await lib.addStroke(on: id, pageKey: page, tool: .pen, color: "#5aa9e6", width: 2, points: [InkPoint(x: 1, y: 1), InkPoint(x: 2, y: 2)], by: "assist")!
        let strokes = await lib.strokes(on: id, pageKey: page)
        #expect(strokes.first { $0.id == mine }?.by == "")
        #expect(strokes.first { $0.id == answer }?.by == "assist")
    }
}
