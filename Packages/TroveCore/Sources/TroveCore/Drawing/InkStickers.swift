import Foundation

/// A stroke in a library element (or being placed from one): its look and its points.
public struct InkStickerStroke: Sendable, Equatable {
    /// The tool's name as stored (a tool this Trove doesn't know draws as a pen).
    public var tool: String
    public var color: String
    public var width: Double
    public var shape: String?
    public var style: InkStrokeStyle
    public var points: [InkPoint]

    public init(tool: String, color: String, width: Double, shape: String? = nil, style: InkStrokeStyle = InkStrokeStyle(), points: [InkPoint]) {
        self.tool = tool; self.color = color; self.width = width; self.shape = shape; self.style = style; self.points = points
    }

    public init(_ s: InkStroke) {
        self.init(tool: s.record[InkStroke.Field.tool]?.string ?? s.tool.rawValue, color: s.color, width: s.width, shape: s.shape, style: s.style, points: s.points)
    }

    public var inkTool: InkTool { InkTool(rawValue: tool) ?? .pen }
}

/// A text box, picture or tape strip in a library element.
public struct InkStickerElement: Sendable, Equatable {
    /// `text`, `image` or `tape`.
    public var kind: String
    public var x, y, w, h: Double
    public var text: String
    public var size: Double
    public var color: String
    /// The picture's attachment (the same blob as where it was saved from).
    public var image: JSONValue?
    public var rotate: Double
    public var flip: Bool
    public var font: String
    public var bold: Bool
    public var italic: Bool

    public init(kind: String, x: Double, y: Double, w: Double, h: Double, text: String = "", size: Double = 20, color: String = "#000000", image: JSONValue? = nil,
                rotate: Double = 0, flip: Bool = false, font: String = "sans", bold: Bool = false, italic: Bool = false) {
        self.kind = kind; self.x = x; self.y = y; self.w = w; self.h = h; self.text = text; self.size = size; self.color = color; self.image = image
        self.rotate = rotate; self.flip = flip; self.font = font; self.bold = bold; self.italic = italic
    }

    public init(_ e: InkElement) {
        let f = e.frame
        self.init(kind: e.kind.rawValue, x: f.x, y: f.y, w: f.width, h: f.height, text: e.text, size: e.size, color: e.color, image: e.record[InkElement.Field.image],
                  rotate: e.rotate, flip: e.flip, font: e.font.rawValue, bold: e.bold, italic: e.italic)
    }

    public var frame: InkEditing.Frame { InkEditing.Frame(x: x, y: y, w: w, h: h, rotate: rotate, flip: flip) }
    public var textStyle: InkTextStyle {
        InkTextStyle(font: InkTextStyle.Font(rawValue: font) ?? .sans, bold: bold, italic: italic)
    }
}

/// A reusable element from the library (PROTOCOL.md §10 "The elements library"): a `sticker`
/// record, or one Trove comes with (`builtin`, ids `builtin.*`, the same on every device). Its
/// content's box starts at 0, 0 and is `w` × `h`.
public struct InkSticker: Identifiable, Sendable, Equatable {
    public var id: String
    public var name: String
    /// One level; "" for none.
    public var folder: String
    public var w, h: Double
    public var strokes: [InkStickerStroke]
    public var elements: [InkStickerElement]
    public var builtin: Bool
    public var createdAt: Double

    public static let kind = "sticker"
}

/// The elements library: saving a selection, reading records, placing one, and the built-in set.
/// The same as web/public/core/inkedit.js (`stickerFields`, `stickerView`, `placeSticker`,
/// `builtInStickers`), checked against Fixtures/ink-editing.json.
public enum InkStickers {
    static let strokeKeys = ["tool", "color", "width", "shape", "fill", "dash", "arrow", "nib"]

    /// A sticker's fields from strokes and elements on a page, moved so their box starts at 0, 0.
    /// Strokes keep their look; points are `points2` when the vault writes compact points.
    public static func fields(name: String, folder: String = "", strokes: [InkStickerStroke], elements: [InkStickerElement], compact: Bool) -> [String: JSONValue] {
        var box: InkGeometry.Rect?
        for s in strokes { box = InkGeometry.union(box, InkGeometry.bounds(s.points, pad: s.width / 2)) }
        for e in elements { box = InkGeometry.union(box, InkEditing.bounds(e.frame)) }
        let ox = box?.x ?? 0, oy = box?.y ?? 0
        let cleanName = name.isEmpty ? "Element" : String(name.prefix(80))
        var strokeList: [JSONValue] = []
        for s in strokes {
            var f: [String: JSONValue] = ["tool": .string(s.tool), "color": .string(s.color), "width": .number(s.width)]
            if let shape = s.shape, !shape.isEmpty { f["shape"] = .string(shape) }
            f.merge(s.style.fields) { _, b in b }
            let moved = s.points.map { (p: InkPoint) -> InkPoint in
                var q = p
                q.x = p.x - ox
                q.y = p.y - oy
                return q
            }
            f.merge(InkPoints.fields(moved, compact: compact)) { _, b in b }
            strokeList.append(.object(f))
        }
        var elementList: [JSONValue] = []
        for e in elements {
            var f: [String: JSONValue] = ["type": .string(e.kind), "x": .number(e.x - ox), "y": .number(e.y - oy), "w": .number(e.w), "h": .number(e.h),
                                          "size": .number(e.size)]
            if !e.text.isEmpty { f["text"] = .string(e.text) }
            if !e.color.isEmpty { f["color"] = .string(e.color) }
            if let image = e.image, image != .null { f["image"] = image }
            if e.rotate != 0 { f["rotate"] = .number(e.rotate) }
            if e.flip { f["flip"] = .bool(true) }
            if !e.font.isEmpty && e.font != "sans" { f["font"] = .string(e.font) }
            if e.bold { f["bold"] = .bool(true) }
            if e.italic { f["italic"] = .bool(true) }
            elementList.append(.object(f))
        }
        let w = box.map { $0.width } ?? 0, h = box.map { $0.height } ?? 0
        return ["name": .string(cleanName), "folder": .string(String(folder.prefix(80))), "w": .number(w), "h": .number(h),
                "strokes": .array(strokeList), "elements": .array(elementList)]
    }

    private static func str(_ v: JSONValue?, _ d: String = "") -> String { v?.string ?? d }
    private static func num(_ v: JSONValue?, _ d: Double = 0) -> Double {
        guard let n = v?.number, n.isFinite else { return d }
        return n
    }

    /// A sticker record's fields (or a built-in's) as a sticker. Bad entries are dropped.
    public static func view(id: String, fields f: [String: JSONValue], builtin: Bool = false) -> InkSticker {
        var strokes: [InkStickerStroke] = []
        for v in f["strokes"]?.array ?? [] {
            guard let s = v.object else { continue }
            let points: [InkPoint]
            if let list = s["points"]?.array {
                points = list.map { (p: JSONValue) -> InkPoint in
                    let a = p.array ?? []
                    let x = a.count > 0 ? (a[0].number ?? 0) : 0, y = a.count > 1 ? (a[1].number ?? 0) : 0
                    let pressure = a.count > 2 ? (a[2].number ?? 0.5) : 0.5, t = a.count > 3 ? (a[3].number ?? 0) : 0
                    return InkPoint(x: x, y: y, pressure: pressure, t: t)
                }
            } else if let compact = s["points2"]?.string, !compact.isEmpty {
                points = InkPoints.decode2(compact)
            } else {
                points = InkPoints.decode(s["points"]?.string ?? "")
            }
            guard !points.isEmpty else { continue }
            let style = InkStrokeStyle(fill: s["fill"]?.string, dash: s["dash"]?.string, arrow: s["arrow"]?.string, nib: s["nib"]?.number)
            strokes.append(InkStickerStroke(tool: str(s["tool"], "pen"), color: str(s["color"], "#000000"), width: num(s["width"], 2),
                                            shape: s["shape"]?.string, style: style, points: points))
        }
        var elements: [InkStickerElement] = []
        for v in f["elements"]?.array ?? [] {
            guard let e = v.object, let type = e["type"]?.string, ["text", "image", "tape"].contains(type) else { continue }
            let image: JSONValue? = e["image"]?.object?["id"]?.string != nil ? e["image"] : nil
            elements.append(InkStickerElement(kind: type, x: num(e["x"]), y: num(e["y"]), w: max(1, num(e["w"], 100)), h: max(1, num(e["h"], 40)),
                                              text: str(e["text"]), size: num(e["size"], 20), color: str(e["color"], "#000000"), image: image,
                                              rotate: num(e["rotate"]), flip: e["flip"]?.bool == true, font: str(e["font"], "sans"),
                                              bold: e["bold"]?.bool == true, italic: e["italic"]?.bool == true))
        }
        return InkSticker(id: id, name: str(f["name"], "Element"), folder: str(f["folder"]), w: num(f["w"]), h: num(f["h"]),
                          strokes: strokes, elements: elements, builtin: builtin, createdAt: num(f["createdAt"]))
    }

    /// What placing a sticker adds: its strokes and elements moved so its box is centred on `at`
    /// and scaled by `scale` (widths, text sizes and boxes too).
    public static func place(_ sticker: InkSticker, at: InkPoint, scale: Double = 1) -> (strokes: [InkStickerStroke], elements: [InkStickerElement]) {
        let ox = at.x - sticker.w * scale / 2, oy = at.y - sticker.h * scale / 2
        let strokes = sticker.strokes.map { (s: InkStickerStroke) -> InkStickerStroke in
            var out = s
            out.width = s.width * scale
            out.points = s.points.map { (p: InkPoint) -> InkPoint in
                var q = p
                q.x = ox + p.x * scale
                q.y = oy + p.y * scale
                return q
            }
            return out
        }
        let elements = sticker.elements.map { (e: InkStickerElement) -> InkStickerElement in
            var out = e
            out.x = ox + e.x * scale
            out.y = oy + e.y * scale
            out.w = e.w * scale
            out.h = e.h * scale
            out.size = e.size * scale
            return out
        }
        return (strokes, elements)
    }

    /// The elements Trove comes with: arrows, checkboxes, dividers, a star, a heart and planner tags.
    public static let builtIns: [InkSticker] = makeBuiltIns()

    private static func makeBuiltIns() -> [InkSticker] {
        func p(_ x: Double, _ y: Double) -> InkPoint { InkPoint(x: x, y: y, pressure: 0.5, t: 0) }
        func line(_ a: (Double, Double), _ b: (Double, Double)) -> [InkPoint] { [p(a.0, a.1), p(b.0, b.1)] }
        func box(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> [InkPoint] {
            InkEditing.shapePoints("rectangle", from: InkPoint(x: x, y: y), to: InkPoint(x: x + w, y: y + h)) ?? []
        }
        func flat(_ pts: [InkPoint]?) -> [InkPoint] { (pts ?? []).map { p($0.x, $0.y) } }
        func s(_ points: [InkPoint], shape: String, color: String = "#1c1c1e", width: Double = 3, fill: String? = nil, dash: String? = nil,
               arrow: String? = nil) -> InkStickerStroke {
            InkStickerStroke(tool: "pen", color: color, width: width, shape: shape, style: InkStrokeStyle(fill: fill, dash: dash, arrow: arrow), points: points)
        }
        typealias Raw = (id: String, name: String, folder: String, strokes: [InkStickerStroke], elements: [InkStickerElement])
        var list: [Raw] = [
            ("arrow-right", "Arrow", "Arrows", [s(line((0, 12), (120, 12)), shape: "line", arrow: "end")], []),
            ("arrow-both", "Two-way arrow", "Arrows", [s(line((0, 12), (120, 12)), shape: "line", arrow: "both")], []),
            ("arrow-curve", "Curved arrow", "Arrows", [s(flat(InkEditing.curvePoints(InkPoint(x: 0, y: 60), InkPoint(x: 60, y: -20), InkPoint(x: 120, y: 60))), shape: "curve")], []),
            ("checkbox", "Checkbox", "Checkboxes", [s(box(0, 0, 28, 28), shape: "rectangle", width: 2.5)], []),
            ("checkbox-ticked", "Ticked box", "Checkboxes", [s(box(0, 0, 28, 28), shape: "rectangle", width: 2.5),
                                                              s([p(6, 15), p(12, 22), p(24, 6)], shape: "polyline", color: "#34c759", width: 3.5)], []),
            ("divider", "Divider", "Dividers", [s(line((0, 0), (480, 0)), shape: "line", color: "#8e8e93", width: 2)], []),
            ("divider-dots", "Dotted divider", "Dividers", [s(line((0, 0), (480, 0)), shape: "line", color: "#8e8e93", width: 3, dash: "dot")], []),
            ("star", "Star", "Shapes", [s(flat(InkEditing.shapePoints("star", from: InkPoint(x: 0, y: 0), to: InkPoint(x: 60, y: 57))), shape: "star",
                                          color: "#ff9500", width: 2, fill: "#ffd60a")], []),
            ("heart", "Heart", "Shapes", [s(flat(InkEditing.shapePoints("heart", from: InkPoint(x: 0, y: 0), to: InkPoint(x: 60, y: 54))), shape: "heart",
                                            color: "#ff3b30", width: 2, fill: "#ff6b6b")], []),
        ]
        let tags: [(String, String, String, String)] = [("important", "Important", "#ff3b30", "#ffe1e1"), ("todo", "To do", "#0a84ff", "#e1efff"),
                                                        ("done", "Done", "#34c759", "#e3f7e8"), ("due", "Due", "#ff9500", "#fff0db")]
        for (id, name, color, fill) in tags {
            let text = InkStickerElement(kind: "text", x: 12, y: 7, w: 100, h: 22, text: name, size: 18, color: color, bold: true)
            list.append((id, name, "Planner", [s(box(0, 0, 120, 36), shape: "rectangle", color: color, width: 2, fill: fill)], [text]))
        }
        return list.map { (b: Raw) -> InkSticker in
            var bx: InkGeometry.Rect?
            for x in b.strokes { bx = InkGeometry.union(bx, InkGeometry.bounds(x.points, pad: x.width / 2)) }
            let ox = bx?.x ?? 0, oy = bx?.y ?? 0
            // Moved so the box starts at 0, 0, like a saved sticker.
            let strokes = b.strokes.map { (x: InkStickerStroke) -> InkStickerStroke in
                var out = x
                out.points = x.points.map { p($0.x - ox, $0.y - oy) }
                return out
            }
            let elements = b.elements.map { (e: InkStickerElement) -> InkStickerElement in
                var out = e
                out.x = e.x - ox
                out.y = e.y - oy
                return out
            }
            return InkSticker(id: "builtin.\(b.id)", name: b.name, folder: b.folder, w: bx?.width ?? 0, h: bx?.height ?? 0,
                              strokes: strokes, elements: elements, builtin: true, createdAt: 0)
        }
    }
}
