import Foundation
import Testing
@testable import TroveCore

/// Outlines, arrowheads, compact points, pen settings, the page grid and pencil grain (PROTOCOL.md
/// §10). Fixtures/ink-outline.json comes from web/test/make-outline-fixture.mjs (ink.js).
@Suite struct InkOutlineTests {
    func fixture() throws -> [String: JSONValue] {
        let url = try #require(Bundle.module.url(forResource: "ink-outline", withExtension: "json", subdirectory: "Fixtures"))
        return try #require(try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url)).object)
    }

    static func points(_ v: JSONValue?) -> [InkPoint] {
        (v?.array ?? []).map { p in
            let a = p.array?.compactMap(\.number) ?? []
            return InkPoint(x: a[0], y: a[1], pressure: a.count > 2 ? a[2] : 0.5, t: a.count > 3 ? a[3] : 0, angle: a.count > 4 ? a[4] : nil)
        }
    }

    static func numbers(_ v: JSONValue?) -> [[Double]] { (v?.array ?? []).map { $0.array?.compactMap(\.number) ?? [] } }

    static func close(_ got: [InkPoint], _ want: [[Double]], tolerance: Double = 1e-5) -> Bool {
        guard got.count == want.count else { return false }
        for (p, w) in zip(got, want) where abs(p.x - w[0]) >= tolerance || abs(p.y - w[1]) >= tolerance { return false }
        return true
    }

    static func flat(_ p: InkPoint) -> [Double] { p.angle.map { [p.x, p.y, p.pressure, p.t, $0] } ?? [p.x, p.y, p.pressure, p.t] }

    static func same(_ got: [InkPoint], _ want: [[Double]]) -> Bool {
        guard got.count == want.count else { return false }
        for (p, b) in zip(got, want) {
            let a: [Double] = flat(p)
            guard a.count == b.count else { return false }
            for (x, y) in zip(a, b) where abs(x - y) >= 1e-6 { return false }
        }
        return true
    }

    @Test func outlinesAndArrowheadsMatchTheWebsite() throws {
        let f = try fixture()
        let cases = f["outlines"]?.array ?? []
        #expect(cases.count >= 10)
        for c in cases {
            let o = c.object ?? [:], s = o["stroke"]?.object ?? [:], name = o["name"]?.string ?? ""
            let style = InkStrokeStyle(dash: s["dash"]?.string, nib: s["nib"]?.number)
            let got = InkOutline.outline(tool: InkTool(rawValue: s["tool"]?.string ?? "") ?? .pen, width: s["width"]?.number ?? 2,
                                         points: Self.points(s["points"]), shape: s["shape"]?.string, style: style)
            if o["expect"] == .null {
                #expect(got == nil, "\(name)")
            } else {
                let want = Self.numbers(o["expect"])
                #expect(got.map { Self.close($0, want) } == true, "\(name): \(got?.count ?? -1) vs \(want.count)")
            }
        }
        for c in f["arrows"]?.array ?? [] {
            let o = c.object ?? [:], s = o["stroke"]?.object ?? [:]
            let got = InkOutline.arrowHeads(tool: InkTool(rawValue: s["tool"]?.string ?? "") ?? .pen, width: s["width"]?.number ?? 2,
                                            points: Self.points(s["points"]), shape: s["shape"]?.string, arrow: s["arrow"]?.string)
            let want = (o["expect"]?.array ?? []).map { Self.numbers($0) }
            #expect(got.count == want.count, "\(o["name"]?.string ?? "")")
            for (a, b) in zip(got, want) { #expect(Self.close(a, b)) }
        }
    }

    @Test func compactPointsMatchTheWebsite() throws {
        let f = try fixture()
        let p2 = f["points2"]?.object ?? [:]
        for c in p2["cases"]?.array ?? [] {
            let o = c.object ?? [:]
            let encoded = o["encoded"]?.string ?? ""
            #expect(InkPoints.encode2(Self.points(o["points"])) == encoded, "\(o["name"]?.string ?? "")")
            #expect(Self.same(InkPoints.decode2(encoded), Self.numbers(o["decoded"])), "\(o["name"]?.string ?? "")")
        }
        for c in p2["v1"]?.array ?? [] {
            let o = c.object ?? [:]
            #expect(Self.same(InkPoints.decode2(o["encoded"]?.string ?? ""), Self.numbers(o["decoded"])), "\(o["name"]?.string ?? "")")
        }
        #expect(InkPoints.encode2([InkPoint(x: 1e300, y: -.infinity, pressure: 2, t: 0)]) == InkPoints.encode2([InkPoint(x: 1e9, y: 0, pressure: 1, t: 0)]))
        let legacy = p2["legacy"]?.object ?? [:]
        #expect(Self.same(InkPoints.decode(legacy["encoded"]?.string ?? ""), Self.numbers(legacy["decoded"])))
        // A stroke with both reads its compact points.
        let first = p2["cases"]?.array?.first?.object ?? [:]
        let record = Record(id: "s", kind: "stroke", fields: ["points": .string(legacy["encoded"]?.string ?? ""), "points2": first["encoded"] ?? .null],
                            createdHLC: "0", updatedHLC: "0")
        #expect(Self.same(InkStroke(record).points, Self.numbers(first["decoded"])))
        #expect(InkPoints.decode2("") == [] && InkPoints.decode2("AAAA") == [])
        for c in f["nibs"]?.array ?? [] {
            let o = c.object ?? [:]
            let got = InkOutline.meanNib((o["angles"]?.array ?? []).compactMap(\.number).map { InkPoint(x: 0, y: 0, angle: $0) })
            if let want = o["expect"]?.number { #expect(abs((got ?? -9) - want) < 1e-9) } else { #expect(got == nil) }
        }
    }

    @Test func fastBase64MatchesFoundationAndDecodesQuickly() {
        var rng = SystemRandomNumberGenerator()
        for n in [0, 1, 2, 3, 16, 17, 100, 1601] {
            let data = Data((0..<n).map { _ in UInt8.random(in: 0...255, using: &rng) })
            #expect(InkPoints.base64URLBytes(data.base64URL) == [UInt8](data))
            #expect(InkPoints.base64URLBytes(data.base64EncodedString()) == [UInt8](data))
        }
        #expect(InkPoints.base64URLBytes("a$bc") == nil && InkPoints.base64URLBytes("abcde") == nil)
        let stroke = (0..<200).map { InkPoint(x: Double($0), y: Double($0) / 3, pressure: 0.5, t: Double($0) * 8) }
        let legacy = InkPoints.encode(stroke), compact = InkPoints.encode2(stroke)
        let start = Date()
        for _ in 0..<2000 { _ = InkPoints.decode(legacy) }
        let legacyTime = Date().timeIntervalSince(start)
        let mid = Date()
        for _ in 0..<2000 { _ = InkPoints.decode2(compact) }
        let compactTime = Date().timeIntervalSince(mid)
        print("decode 200-point stroke: points \(Int(legacyTime / 2000 * 1e6)) µs, points2 \(Int(compactTime / 2000 * 1e6)) µs; sizes \(legacy.count) vs \(compact.count) chars")
        #expect(InkPoints.decode(legacy).count == 200)
    }

    @Test func penSettingsMatchTheWebsite() throws {
        let f = try fixture()
        for c in f["settings"]?.array ?? [] {
            let o = c.object ?? [:], expect = o["expect"]?.object ?? [:]
            let got = InkSettings(fields: o["fields"]?.object ?? [:])
            for t in InkTool.allCases {
                let want = expect["pens"]?.object?[t.rawValue]?.object ?? [:]
                let pen = got.pen(t)
                #expect(Double(pen.smoothing) == want["smoothing"]?.number && pen.curve.rawValue == want["curve"]?.string && Double(pen.minWidth) == want["minWidth"]?.number)
            }
            let favourites = (expect["favourites"]?.array ?? []).map { v -> InkFavourite in
                let x = v.object ?? [:]
                return InkFavourite(tool: InkTool(rawValue: x["tool"]?.string ?? "") ?? .pen, color: x["color"]?.string ?? "", width: x["width"]?.number ?? 0)
            }
            #expect(got.favourites == favourites)
            #expect(got.palette == (expect["palette"]?.array ?? []).compactMap(\.string))
            #expect(got.compactPoints == (expect["compactPoints"]?.bool ?? false))
        }
        for c in f["curves"]?.array ?? [] {
            let o = c.object ?? [:]
            let s = PenSettings(curve: PenSettings.Curve(rawValue: o["curve"]?.string ?? "") ?? .normal, minWidth: Int(o["minWidth"]?.number ?? 0))
            #expect(abs(s.pressure(o["p"]?.number ?? 0) - (o["expect"]?.number ?? -1)) < 1e-9)
        }
        for c in f["filters"]?.array ?? [] {
            let o = c.object ?? [:], s = o["settings"]?.object ?? [:]
            let settings = PenSettings(smoothing: Int(s["smoothing"]?.number ?? 0), curve: PenSettings.Curve(rawValue: s["curve"]?.string ?? "") ?? .normal,
                                       minWidth: Int(s["minWidth"]?.number ?? 0))
            #expect(Self.same(PenFilter.apply(Self.points(o["raw"]), settings), Self.numbers(o["expect"])))
        }
    }

    @Test func gridAndGrainMatchTheWebsite() throws {
        let f = try fixture()
        let g = f["grid"]?.object ?? [:]
        func rect(_ v: JSONValue?) -> InkGeometry.Rect {
            let o = v?.object ?? [:]
            return InkGeometry.Rect(x: o["x"]?.number ?? 0, y: o["y"]?.number ?? 0, width: o["w"]?.number ?? 0, height: o["h"]?.number ?? 0)
        }
        var grid = InkGrid(cell: g["cell"]?.number ?? 256)
        for b in g["boxes"]?.array ?? [] { grid.add(b.object?["id"]?.string ?? "", rect(b.object?["rect"])) }
        for id in g["removed"]?.array ?? [] { grid.remove(id.string ?? "") }
        for q in g["queries"]?.array ?? [] {
            #expect(grid.query(rect(q.object?["rect"])) == (q.object?["expect"]?.array ?? []).compactMap(\.string))
        }
        let grain = f["grain"]?.object ?? [:]
        #expect(Data(InkOutline.grainTile).base64URL == grain["tile"]?.string)
    }

    @Test func compactPointsStylesSettingsAndTapeInTheLibrary() async {
        let lib = Library(engine: SyncEngine(device: "D", keys: .generate(), transports: []))
        let sketch = await lib.addSketch()
        let line = [InkPoint(x: 0, y: 0, pressure: 0.5), InkPoint(x: 100, y: 0, pressure: 0.5, t: 16)]
        let old = await lib.addStroke(on: sketch, pageKey: "0", tool: .pen, color: "#000000", width: 4, points: line, style: InkStrokeStyle(dash: "dot"))
        var r = await lib.engine.record(old ?? "")
        #expect(r?["points"]?.string?.isEmpty == false && r?["points2"] == nil)
        await lib.setCompactPoints(true)
        let neu = await lib.addStroke(on: sketch, pageKey: "0", tool: .fountain, color: "#000000", width: 4,
                                      points: line.map { InkPoint(x: $0.x, y: $0.y, pressure: $0.pressure, t: $0.t, angle: 1) })
        let compact = await lib.engine.record(neu ?? "")
        let compactSize: Int = compact?["points2"]?.string?.count ?? 99, fullSize: Int = r?["points"]?.string?.count ?? 0
        #expect(compact?["points"] == nil)
        #expect(compactSize < fullSize)
        let angle: Double = compact.flatMap { InkStroke($0).points.first?.angle } ?? 0
        #expect(abs(angle - 1) < 0.01)
        await lib.transformStrokes([old ?? ""], by: .move(10, 0))
        r = await lib.engine.record(old ?? "")
        let movedX: Double? = r.flatMap { InkStroke($0).points.first?.x }
        #expect(r?["points"]?.string == "")
        #expect(movedX == 10)
        let pieces = await lib.eraseStrokes(on: sketch, pageKey: "0", along: [InkPoint(x: 60, y: -5), InkPoint(x: 60, y: 5)], radius: 5, near: [old ?? ""])
        #expect(pieces.count == 2)
        let strokes = await lib.strokes(on: sketch, pageKey: "0")
        #expect(strokes.filter { pieces.contains($0.id) }.allSatisfy { $0.style.dash == "dot" })
        #expect(strokes.contains { $0.id == neu })
        await lib.setPenSettings(.pen, PenSettings(smoothing: 30, curve: .firm, minWidth: 10))
        await lib.setInkFavourites([InkFavourite(tool: .pen, color: "#FF0000", width: 3)])
        let settings = await lib.inkSettings()
        #expect(settings.pen(.pen) == PenSettings(smoothing: 30, curve: .firm, minWidth: 10))
        #expect(settings.favourites == [InkFavourite(tool: .pen, color: "#ff0000", width: 3)] && settings.compactPoints)
        let tape = await lib.addElement(on: sketch, pageKey: "0", kind: .tape, frame: InkGeometry.Rect(x: 0, y: 0, width: 100, height: 20), color: "#f2c94c")
        let e = await lib.elements(on: sketch, pageKey: "0").first { $0.id == tape }
        #expect(e?.kind == .tape && e?.color == "#f2c94c")
    }
}
