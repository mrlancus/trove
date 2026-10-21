import Foundation
import Testing
@testable import TroveCore

/// Turning and flipping, the shape picker, handles, connectors, the ruler and protractor,
/// straightening, groups and the elements library (PROTOCOL.md §10). Fixtures/ink-editing.json
/// comes from web/test/make-editing-fixture.mjs (core/inkedit.js), so the apps edit ink exactly
/// like the website.
@Suite struct InkEditingTests {
    func fixture() throws -> [String: JSONValue] {
        let url = try #require(Bundle.module.url(forResource: "ink-editing", withExtension: "json", subdirectory: "Fixtures"))
        return try #require(try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url)).object)
    }

    static let tolerance = 1e-9

    static func near(_ a: Double, _ b: Double?) -> Bool {
        guard let b else { return false }
        return abs(a - b) <= tolerance * max(1, abs(b))
    }

    static func point(_ v: JSONValue?) -> InkPoint {
        let a = v?.array?.compactMap(\.number) ?? [0, 0]
        return InkPoint(x: a[0], y: a[1])
    }

    static func xy(_ got: [InkPoint], _ want: JSONValue?) -> Bool {
        let w = InkOutlineTests.numbers(want)
        guard got.count == w.count else { return false }
        for (p, q) in zip(got, w) where !near(p.x, q[0]) || !near(p.y, q[1]) { return false }
        return true
    }

    static func flat(_ got: [InkPoint], _ want: JSONValue?) -> Bool {
        let w = InkOutlineTests.numbers(want)
        guard got.count == w.count else { return false }
        for (p, q) in zip(got, w) {
            let a = InkOutlineTests.flat(p)
            guard a.count == q.count else { return false }
            for (x, y) in zip(a, q) where !near(x, y) { return false }
        }
        return true
    }

    static func transform(_ v: JSONValue?) -> InkGeometry.Transform {
        let o = v?.object ?? [:]
        return InkGeometry.Transform(sx: o["sx"]?.number ?? 1, sy: o["sy"]?.number ?? 1, ox: o["ox"]?.number ?? 0, oy: o["oy"]?.number ?? 0,
                                     dx: o["dx"]?.number ?? 0, dy: o["dy"]?.number ?? 0, r: o["r"]?.number ?? 0)
    }

    static func rect(_ v: JSONValue?) -> InkGeometry.Rect? {
        guard let o = v?.object else { return nil }
        return InkGeometry.Rect(x: o["x"]?.number ?? 0, y: o["y"]?.number ?? 0, width: o["w"]?.number ?? 0, height: o["h"]?.number ?? 0)
    }

    static func same(_ r: InkGeometry.Rect, _ v: JSONValue?) -> Bool {
        let o = v?.object ?? [:]
        return near(r.x, o["x"]?.number) && near(r.y, o["y"]?.number) && near(r.width, o["w"]?.number) && near(r.height, o["h"]?.number)
    }

    static func frame(_ v: JSONValue?) -> (InkEditing.Frame, Bool) {
        let o = v?.object ?? [:]
        let f = InkEditing.Frame(x: o["x"]?.number ?? 0, y: o["y"]?.number ?? 0, w: o["w"]?.number ?? 0, h: o["h"]?.number ?? 0,
                                 rotate: o["rotate"]?.number ?? 0, flip: o["flip"]?.bool == true)
        return (f, o["type"]?.string == "image")
    }

    /// JSON equality, numbers within the tolerance.
    static func sameJSON(_ a: JSONValue?, _ b: JSONValue?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (.number(x)?, .number(y)?): return near(x, y)
        case let (.array(x)?, .array(y)?):
            guard x.count == y.count else { return false }
            for (p, q) in zip(x, y) where !sameJSON(p, q) { return false }
            return true
        case let (.object(x)?, .object(y)?):
            guard Set(x.keys) == Set(y.keys) else { return false }
            for (k, v) in x where !sameJSON(v, y[k]) { return false }
            return true
        default: return a == b
        }
    }

    @Test func transformsAndElementsMatchTheWebsite() throws {
        let f = try fixture()
        let transforms = f["transforms"]?.array ?? []
        #expect(transforms.count == 8)
        for c in transforms {
            let o = c.object ?? [:], t = Self.transform(o["t"])
            #expect(Self.flat(InkOutlineTests.points(o["points"]).map(t.apply), o["expect"]))
            #expect(Self.same(t.apply(InkGeometry.Rect(x: 10, y: 20, width: 60, height: 30)), o["rect"]))
            #expect(Self.near(t.angle(0.7), o["angle"]?.number))
        }
        let elements = f["elements"]?.array ?? []
        #expect(elements.count == 32)
        for c in elements {
            let o = c.object ?? [:], (e, image) = Self.frame(o["element"]), want = o["expect"]?.object ?? [:]
            let got = InkEditing.transform(Self.transform(o["t"]), e, image: image)
            #expect(Self.near(got.x, want["x"]?.number) && Self.near(got.y, want["y"]?.number) && Self.near(got.w, want["w"]?.number) && Self.near(got.h, want["h"]?.number))
            #expect(Self.near(got.rotate, want["rotate"]?.number), "\(c)")
            #expect(got.flip == (want["flip"]?.bool == true))
        }
        for c in f["boxes"]?.array ?? [] {
            let o = c.object ?? [:], (e, _) = Self.frame(o["element"])
            #expect(Self.same(InkEditing.bounds(e), o["bounds"]))
            for h in o["hits"]?.array ?? [] {
                let p = h.object ?? [:]
                #expect(InkEditing.contains(e, InkPoint(x: p["x"]?.number ?? 0, y: p["y"]?.number ?? 0)) == (p["inside"]?.bool == true))
            }
        }
    }

    @Test func shapesHandlesAndConnectorsMatchTheWebsite() throws {
        let f = try fixture()
        let shapes = f["shapes"]?.array ?? []
        #expect(shapes.count == InkEditing.pickerShapes.count)
        for c in shapes {
            let o = c.object ?? [:], name = o["shape"]?.string ?? ""
            let got = InkEditing.shapePoints(name, from: Self.point(o["a"]), to: Self.point(o["b"])) ?? []
            #expect(Self.xy(got, o["expect"]), "\(name)")
        }
        let curve = f["curve"]?.object ?? [:]
        #expect(Self.xy(InkEditing.curvePoints(Self.point(curve["a"]), Self.point(curve["c"]), Self.point(curve["b"])), curve["expect"]))
        for c in f["handles"]?.array ?? [] {
            let o = c.object ?? [:], s = o["stroke"]?.object ?? [:], name = o["name"]?.string ?? ""
            let shape = s["shape"]?.string, pts = InkOutlineTests.points(s["points"])
            #expect(Self.xy(InkEditing.shapeHandles(shape: shape, points: pts), o["handles"]), "\(name)")
            for m in o["moves"]?.array ?? [] {
                let mo = m.object ?? [:]
                let got = InkEditing.moveShapeHandle(shape: shape, points: pts, index: Int(mo["index"]?.number ?? 0), to: Self.point(mo["to"]))
                #expect(got.shape == mo["shape"]?.string, "\(name)")
                #expect(Self.flat(got.points, mo["points"]), "\(name) \(mo["index"]?.number ?? -1)")
            }
        }
        let connectors = f["connectors"]?.object ?? [:]
        for c in connectors["exits"]?.array ?? [] {
            let o = c.object ?? [:], want = o["expect"]?.object ?? [:]
            let got = InkEditing.boxExit(try #require(Self.rect(o["box"])), toward: Self.point(o["toward"]))
            #expect(Self.near(got.x, want["x"]?.number) && Self.near(got.y, want["y"]?.number))
        }
        for c in connectors["ends"]?.array ?? [] {
            let o = c.object ?? [:], want = o["expect"]?.array ?? []
            let (a, b) = InkEditing.connectorEnds(Self.point(o["a"]), Self.point(o["b"]), from: Self.rect(o["from"]), to: Self.rect(o["to"]))
            #expect(want.count == 2)
            #expect(Self.near(a.x, want[0].object?["x"]?.number) && Self.near(a.y, want[0].object?["y"]?.number))
            #expect(Self.near(b.x, want[1].object?["x"]?.number) && Self.near(b.y, want[1].object?["y"]?.number))
        }
    }

    @Test func rulerProtractorStraighteningAndGroupsMatchTheWebsite() throws {
        let f = try fixture()
        let t = f["tools"]?.object ?? [:]
        func guide(_ v: JSONValue?) -> InkEditing.Guide {
            let o = v?.object ?? [:]
            return InkEditing.Guide(x: o["x"]?.number ?? 0, y: o["y"]?.number ?? 0, angle: o["angle"]?.number ?? 0,
                                    length: o["length"]?.number ?? InkEditing.rulerLength, width: o["width"]?.number ?? InkEditing.rulerWidth,
                                    radius: o["radius"]?.number ?? InkEditing.protractorRadius)
        }
        let ruler = guide(t["ruler"]), pro = guide(t["protractor"])
        for c in t["rulerEdges"]?.array ?? [] {
            let o = c.object ?? [:], p = Self.point(o["p"])
            #expect(InkEditing.rulerEdge(ruler, p, tolerance: o["tolerance"]?.number ?? 0) == Int(o["edge"]?.number ?? 9))
            #expect(InkEditing.onRuler(ruler, p) == (o["on"]?.bool == true))
        }
        for c in t["rulerSnaps"]?.array ?? [] {
            let o = c.object ?? [:], p = Self.point(o["p"])
            #expect(Self.xy([InkEditing.onRulerEdge(ruler, edge: -1, p)], .array([o["top"] ?? .null])))
            #expect(Self.xy([InkEditing.onRulerEdge(ruler, edge: 1, p)], .array([o["bottom"] ?? .null])))
        }
        for c in t["arcs"]?.array ?? [] {
            let o = c.object ?? [:], p = Self.point(o["p"])
            #expect(InkEditing.onProtractorArc(pro, p, tolerance: o["tolerance"]?.number ?? 0) == (o["near"]?.bool == true))
            #expect(Self.xy([InkEditing.onArc(pro, p)], .array([o["on"] ?? .null])))
            #expect(Self.near(InkEditing.protractorDegrees(pro, p), o["degrees"]?.number))
        }
        for c in t["degrees"]?.array ?? [] {
            let o = c.object ?? [:]
            #expect(Self.near(InkEditing.degrees(o["angle"]?.number ?? 0), o["expect"]?.number))
        }
        for c in t["snaps"]?.array ?? [] {
            let o = c.object ?? [:]
            #expect(Self.near(InkEditing.snapRotation(o["r"]?.number ?? 0), o["expect"]?.number), "\(c)")
        }
        let straighten = f["straighten"]?.array ?? []
        #expect(straighten.count == 6)
        for c in straighten {
            let o = c.object ?? [:]
            #expect(Self.near(InkEditing.straightenAngle(InkOutlineTests.points(o["points"])), o["expect"]?.number))
        }
        let groups = f["groups"]?.object ?? [:]
        let all = (groups["all"]?.array ?? []).map { (id: $0.object?["id"]?.string ?? "", group: $0.object?["group"]?.string ?? "") }
        for c in groups["cases"]?.array ?? [] {
            let o = c.object ?? [:]
            let ids = (o["ids"]?.array ?? []).compactMap(\.string)
            #expect(InkEditing.withGroups(ids, all: all).sorted() == (o["expect"]?.array ?? []).compactMap(\.string))
        }
    }

    static func stickerJSON(_ s: InkSticker) -> JSONValue {
        func strokeJSON(_ x: InkStickerStroke) -> JSONValue {
            .object(["tool": .string(x.tool), "color": .string(x.color), "width": .number(x.width), "shape": x.shape.map(JSONValue.string) ?? .null,
                     "fill": x.style.fill.map(JSONValue.string) ?? .null, "dash": x.style.dash.map(JSONValue.string) ?? .null,
                     "arrow": x.style.arrow.map(JSONValue.string) ?? .null, "nib": x.style.nib.map(JSONValue.number) ?? .null,
                     "points": .array(x.points.map { .array(InkOutlineTests.flat($0).map(JSONValue.number)) })])
        }
        return .object(["id": .string(s.id), "name": .string(s.name), "folder": .string(s.folder), "w": .number(s.w), "h": .number(s.h),
                        "strokes": .array(s.strokes.map(strokeJSON)), "elements": .array(s.elements.map(elementJSON)), "builtin": .bool(s.builtin)])
    }

    static func elementJSON(_ e: InkStickerElement) -> JSONValue {
        .object(["type": .string(e.kind), "x": .number(e.x), "y": .number(e.y), "w": .number(e.w), "h": .number(e.h), "text": .string(e.text),
                 "size": .number(e.size), "color": .string(e.color), "image": e.image ?? .null, "rotate": .number(e.rotate), "flip": .bool(e.flip),
                 "font": .string(e.font), "bold": .bool(e.bold), "italic": .bool(e.italic)])
    }

    @Test func theElementsLibraryMatchesTheWebsite() throws {
        let f = try fixture()
        let st = f["stickers"]?.object ?? [:], sample = st["sample"]?.object ?? [:]
        let strokes = (sample["strokes"]?.array ?? []).map { (v: JSONValue) -> InkStickerStroke in
            let o = v.object ?? [:]
            return InkStickerStroke(tool: o["tool"]?.string ?? "pen", color: o["color"]?.string ?? "", width: o["width"]?.number ?? 0, shape: o["shape"]?.string,
                                    style: InkStrokeStyle(fill: o["fill"]?.string, dash: o["dash"]?.string, arrow: o["arrow"]?.string, nib: o["nib"]?.number),
                                    points: InkOutlineTests.points(o["points"]))
        }
        let elements = (sample["elements"]?.array ?? []).map { (v: JSONValue) -> InkStickerElement in
            let o = v.object ?? [:]
            return InkStickerElement(kind: o["type"]?.string ?? "text", x: o["x"]?.number ?? 0, y: o["y"]?.number ?? 0, w: o["w"]?.number ?? 0, h: o["h"]?.number ?? 0,
                                     text: o["text"]?.string ?? "", size: o["size"]?.number ?? 20, color: o["color"]?.string ?? "",
                                     rotate: o["rotate"]?.number ?? 0, flip: o["flip"]?.bool == true, font: o["font"]?.string ?? "sans",
                                     bold: o["bold"]?.bool == true, italic: o["italic"]?.bool == true)
        }
        let name = sample["name"]?.string ?? "", folder = sample["folder"]?.string ?? ""
        let fields = InkStickers.fields(name: name, folder: folder, strokes: strokes, elements: elements, compact: false)
        #expect(Self.sameJSON(.object(fields), st["fields"]), "\(fields)")
        let fields2 = InkStickers.fields(name: name, folder: folder, strokes: strokes, elements: elements, compact: true)
        #expect(Self.sameJSON(.object(fields2), st["fields2"]), "\(fields2)")
        let view = InkStickers.view(id: "s1", fields: st["fields"]?.object ?? [:])
        #expect(Self.sameJSON(Self.stickerJSON(view), st["view"]))
        let placedWant = st["placed"]?.object ?? [:]
        let placed = InkStickers.place(view, at: Self.point(placedWant["at"]), scale: placedWant["scale"]?.number ?? 1)
        let wantStrokes = placedWant["strokes"]?.array ?? []
        #expect(placed.strokes.count == wantStrokes.count)
        for (s, w) in zip(placed.strokes, wantStrokes) {
            let o = w.object ?? [:]
            #expect(Self.near(s.width, o["width"]?.number) && s.shape == o["shape"]?.string && Self.flat(s.points, o["points"]))
        }
        #expect(Self.sameJSON(.array(placed.elements.map(Self.elementJSON)), placedWant["elements"]))
        let builtins = st["builtins"]?.array ?? []
        #expect(builtins.count == 13)
        #expect(InkStickers.builtIns.count == builtins.count)
        for (b, w) in zip(InkStickers.builtIns, builtins) { #expect(Self.sameJSON(Self.stickerJSON(b), w), "\(b.id)") }
        let bad = st["bad"]?.object ?? [:]
        #expect(Self.sameJSON(Self.stickerJSON(InkStickers.view(id: "bad", fields: bad["fields"]?.object ?? [:])), bad["expect"]))
    }

    @Test func lassoEditsInTheLibrary() async throws {
        let lib = Library(engine: SyncEngine(device: "MAC", keys: .generate()))
        let sketch = await lib.addSketch()
        let page = "0"
        let box = try #require(await lib.addStroke(on: sketch, pageKey: page, tool: .pen, color: "#000000", width: 2,
                                                   points: InkEditing.shapePoints("rectangle", from: InkPoint(x: 0, y: 0), to: InkPoint(x: 100, y: 50)) ?? [], shape: "rectangle"))
        let other = try #require(await lib.addStroke(on: sketch, pageKey: page, tool: .pen, color: "#000000", width: 2,
                                                     points: InkEditing.shapePoints("ellipse", from: InkPoint(x: 300, y: 0), to: InkPoint(x: 400, y: 50)) ?? [], shape: "ellipse"))
        let (a, b) = InkEditing.connectorEnds(InkPoint(x: 50, y: 25), InkPoint(x: 350, y: 25), from: await lib.inkBox(box), to: await lib.inkBox(other))
        let link = try #require(await lib.addStroke(on: sketch, pageKey: page, tool: .pen, color: "#000000", width: 2, points: [a, b], shape: "line",
                                                    style: InkStrokeStyle(arrow: "end"), from: box, to: other))
        #expect(await lib.connectors(on: sketch, pageKey: page, joinedTo: [other]) == [link])
        // Moving the ellipse down: the connector follows.
        await lib.transformStrokes([other], by: .move(0, 200))
        await lib.rerouteConnectors([link])
        let moved = try #require(await lib.strokes(on: sketch, pageKey: page).first { $0.id == link })
        #expect((moved.points.last?.y ?? 0) > 150 && moved.from == box && moved.to == other && moved.style.arrow == "end")
        // A text box in a serif font, turned a quarter; then bold off and italic on.
        let text = await lib.addElement(on: sketch, pageKey: page, kind: .text, frame: InkGeometry.Rect(x: 0, y: 100, width: 100, height: 30), text: "Hi",
                                        textStyle: InkTextStyle(font: .serif, bold: true))
        var e = try #require(await lib.elements(on: sketch, pageKey: page).first { $0.id == text })
        #expect(e.font == .serif && e.bold && !e.italic && e.record[InkElement.Field.italic] == nil)
        await lib.transformElements([text], by: InkEditing.rotate(Double.pi / 2, about: InkPoint(x: 50, y: 115)))
        await lib.updateElement(text, textStyle: InkTextStyle(font: .serif, bold: false, italic: true))
        e = try #require(await lib.elements(on: sketch, pageKey: page).first { $0.id == text })
        #expect(abs(e.rotate - Double.pi / 2) < 1e-9 && !e.bold && e.italic)
        // A picture flipped left to right is mirrored.
        let pic = await lib.addElement(on: sketch, pageKey: page, kind: .image, frame: InkGeometry.Rect(x: 500, y: 500, width: 80, height: 40))
        await lib.transformElements([pic], by: InkEditing.flip(horizontal: true, about: InkPoint(x: 540, y: 520)))
        #expect(try #require(await lib.elements(on: sketch, pageKey: page).first { $0.id == pic }).flip)
        // Front and back.
        await lib.reorderInk([box], front: true)
        #expect(await lib.strokes(on: sketch, pageKey: page).last?.id == box)
        await lib.reorderInk([box], front: false)
        #expect(await lib.strokes(on: sketch, pageKey: page).first?.id == box)
        // Groups: a duplicated group is a new group, and a copied connector joins the copies.
        let g = await lib.setInkGroup([box, other, link])
        let copies = await lib.duplicateInk(strokes: [box, other, link], elements: [], to: sketch, pageKey: page)
        let views = await lib.strokes(on: sketch, pageKey: page).filter { copies.contains($0.id) }
        #expect(Set(views.map(\.group)).count == 1 && views.first?.group != g)
        let linkCopy = try #require(views.first { $0.isConnector })
        #expect(copies.contains(linkCopy.from) && copies.contains(linkCopy.to))
        await lib.setInkGroup([box], group: "")
        #expect(await lib.strokes(on: sketch, pageKey: page).first { $0.id == box }?.group == "")
        // A bent line: its middle handle makes a curve.
        let bent = InkEditing.moveShapeHandle(shape: "line", points: moved.points, index: 2, to: InkPoint(x: 200, y: 300))
        await lib.setStrokeShape(link, shape: bent.shape, points: bent.points)
        #expect(await lib.strokes(on: sketch, pageKey: page).first { $0.id == link }?.shape == "curve")
        // The library: save, list, place as one group, rename, delete.
        let strokes = await lib.strokes(on: sketch, pageKey: page).filter { $0.id == box || $0.id == other }
        let sid = await lib.addSticker(name: "Two shapes", folder: "Diagrams", strokes: strokes, elements: [e])
        let saved = try #require(await lib.stickers().first { $0.id == sid })
        #expect(saved.name == "Two shapes" && saved.folder == "Diagrams" && saved.strokes.count == 2 && saved.elements.count == 1)
        #expect(await lib.stickers().filter(\.builtin).count == InkStickers.builtIns.count)
        let placed = await lib.placeSticker(saved, on: sketch, pageKey: page, at: InkPoint(x: 400, y: 400))
        #expect(placed.count == 3)
        let placedGroups = Set(await lib.strokes(on: sketch, pageKey: page).filter { placed.contains($0.id) }.map(\.group))
        #expect(placedGroups.count == 1 && placedGroups.first?.isEmpty == false)
        await lib.updateSticker(sid, name: "Renamed")
        #expect(await lib.stickers().first { $0.id == sid }?.name == "Renamed")
        await lib.deleteSticker(sid)
        #expect(await lib.stickers().first { $0.id == sid } == nil)
        // Bullets toggle on every line, then off.
        #expect(InkTextStyle.toggleBullets("a\nb") == "• a\n• b")
        #expect(InkTextStyle.toggleBullets("• a\n• b") == "a\nb")
    }
}
