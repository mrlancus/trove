import Foundation

/// Drawing (PROTOCOL.md §10). Every stroke is its own `stroke` record, so two devices drawing at
/// once just add up, erasing is a delete and undo deletes your last stroke. The ink sits on a
/// sketch item's own pages, or on top of a file (a PDF page or an image), which never changes.
/// web/public/core/ink.js is the same code for the website; both check Fixtures/ink-cases.json.
public enum InkTool: String, Codable, CaseIterable, Sendable {
    /// `ballpoint`: one even thickness however hard it's pressed. Its points are stored at pressure
    /// 1, so a Trove that doesn't know it (and draws it as a `pen`) still draws it full and even.
    case pen, ballpoint, pencil, marker, highlighter, fountain, brush

    /// How see-through the ink is.
    public var opacity: Double {
        switch self {
        case .pen, .ballpoint, .marker, .fountain, .brush: 1
        case .pencil: 0.85
        case .highlighter: 0.35
        }
    }

    /// Pens, pencils, fountain pens and brushes get thinner when pressed lightly; ballpoints, markers and highlighters don't.
    public var usesPressure: Bool { self != .marker && self != .highlighter && self != .ballpoint }

    /// The points as stored: a ballpoint's at pressure 1 (see above), the rest as drawn.
    public func stored(_ points: [InkPoint]) -> [InkPoint] {
        guard self == .ballpoint else { return points }
        return points.map { var p = $0; p.pressure = 1; return p }
    }
}

public struct InkPoint: Sendable, Equatable {
    /// In page points (a PDF page's points, an image's pixels, or a sketch page).
    public var x: Double
    public var y: Double
    /// 0…1 (0.5 when the device can't tell).
    public var pressure: Double
    /// Milliseconds since the stroke started.
    public var t: Double
    /// The fountain nib's angle here, in radians (Apple Pencil Pro's barrel roll), when known.
    public var angle: Double?

    public init(x: Double, y: Double, pressure: Double = 0.5, t: Double = 0, angle: Double? = nil) {
        self.x = x; self.y = y; self.pressure = pressure; self.t = t; self.angle = angle
    }
}

/// How a stroke looks beyond its tool, colour and width (PROTOCOL.md §10): a closed shape's fill,
/// dashes or dots, arrowheads on a line shape, and the fountain nib's angle for the whole stroke.
public struct InkStrokeStyle: Sendable, Equatable {
    public var fill: String?
    /// "dash" or "dot".
    public var dash: String?
    /// "end", "start" or "both".
    public var arrow: String?
    /// Radians.
    public var nib: Double?

    public init(fill: String? = nil, dash: String? = nil, arrow: String? = nil, nib: Double? = nil) {
        self.fill = fill; self.dash = dash; self.arrow = arrow; self.nib = nib
    }

    public static let dashes = ["dash", "dot"], arrows = ["end", "start", "both"]
    public static let closedShapes: Set<String> = ["triangle", "rectangle", "polygon", "circle", "ellipse"]

    public var isEmpty: Bool { fill == nil && dash == nil && arrow == nil && nib == nil }

    /// The fields to store (only those set).
    public var fields: [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        if let fill { out[InkStroke.Field.fill] = .string(fill) }
        if let dash { out[InkStroke.Field.dash] = .string(dash) }
        if let arrow { out[InkStroke.Field.arrow] = .string(arrow) }
        if let nib { out[InkStroke.Field.nib] = .number(nib) }
        return out
    }
}

public struct InkStroke: Identifiable, Sendable {
    public enum Field {
        public static let on = "on", layer = "layer", page = "page", tool = "tool", color = "color", width = "width"
        public static let points = "points", createdAt = "createdAt", device = "device", shape = "shape"
        public static let points2 = "points2", fill = "fill", dash = "dash", arrow = "arrow", nib = "nib"
    }

    public let record: Record
    public init(_ record: Record) { self.record = record }

    public var id: String { record.id }
    /// The item the ink belongs to.
    public var on: String { record[Field.on]?.string ?? "" }
    /// "" for a sketch's own pages, or the attachment id of the file it's drawn on.
    public var layer: String { record[Field.layer]?.string ?? "" }
    /// 0-based page of a file (PDF page, or 0 for an image).
    public var page: Int { InkPage.int(record[Field.page]?.number ?? Double(record[Field.page]?.string ?? "") ?? 0) ?? 0 }
    /// The page as a sketch knows it: its id in `pageList` (a number n is the page "n").
    public var pageKey: String { InkPage.key(record[Field.page]) }
    /// The clean shape this stroke was snapped to, if any.
    public var shape: String? { record[Field.shape]?.string }
    public var tool: InkTool { InkTool(rawValue: record[Field.tool]?.string ?? "") ?? .pen }
    /// "#rrggbb".
    public var color: String { record[Field.color]?.string ?? "#000000" }
    /// The full width, in page points.
    public var width: Double { record[Field.width]?.number ?? 2 }
    /// `points2` (compact) when the stroke has them, else `points`.
    public var points: [InkPoint] {
        if let compact = record[Field.points2]?.string, !compact.isEmpty { return InkPoints.decode2(compact) }
        return InkPoints.decode(record[Field.points]?.string ?? "")
    }
    public var createdAt: Date { record[Field.createdAt]?.date ?? Date(timeIntervalSince1970: 0) }
    /// Fill, dashes, arrowheads and nib angle.
    public var style: InkStrokeStyle {
        let fill = record[Field.fill]?.string.flatMap { InkSettings.isHex($0) ? $0 : nil }
        let dash = record[Field.dash]?.string.flatMap { InkStrokeStyle.dashes.contains($0) ? $0 : nil }
        let arrow = record[Field.arrow]?.string.flatMap { InkStrokeStyle.arrows.contains($0) ? $0 : nil }
        let nib = record[Field.nib]?.number.flatMap { $0.isFinite ? $0 : nil }
        return InkStrokeStyle(fill: fill, dash: dash, arrow: arrow, nib: nib)
    }

    /// The width at a point: pressure thins pens and pencils (35 % of `width` at no pressure) and
    /// brushes (15 %). A fountain pen also follows its direction (`InkGeometry.fountainWidth`).
    public static func width(_ width: Double, tool: InkTool, pressure: Double) -> Double {
        let p = min(1, max(0, pressure))
        switch tool {
        case .pen, .pencil: return width * (0.35 + 0.65 * p)
        case .brush: return width * (0.15 + 0.85 * p)
        case .fountain: return width * (0.6 + 0.4 * p)
        case .ballpoint, .marker, .highlighter: return width
        }
    }

    /// Red, green and blue (0…1) from "#rrggbb".
    public static func rgb(_ hex: String) -> (Double, Double, Double) {
        let s = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return (0, 0, 0) }
        return (Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255)
    }
}

/// Points packed as little-endian float32 (x, y, pressure, t) quadruples, in base64url.
public enum InkPoints {
    public static func encode(_ points: [InkPoint]) -> String {
        var data = Data(capacity: points.count * 16)
        for p in points {
            for v in [p.x, p.y, p.pressure, p.t] {
                var bits = Float(v).bitPattern.littleEndian
                withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
            }
        }
        return data.base64URL
    }

    public static func decode(_ string: String) -> [InkPoint] {
        guard let bytes = base64URLBytes(string) else { return [] }
        let n = bytes.count / 16
        var out: [InkPoint] = []
        out.reserveCapacity(n)
        bytes.withUnsafeBytes { raw in
            func f(_ i: Int) -> Double { Double(Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: i, as: UInt32.self)))) }
            for k in 0..<n {
                let o = k * 16
                out.append(InkPoint(x: f(o), y: f(o + 4), pressure: f(o + 8), t: f(o + 12)))
            }
        }
        return out
    }

    /// base64url (or standard base64, padding optional) straight to bytes: much faster than going
    /// through Foundation for the thousands of strokes a notebook has. Nil when it isn't base64.
    static func base64URLBytes(_ string: String) -> [UInt8]? {
        var text = string
        return text.withUTF8 { src -> [UInt8]? in
            var end = src.count
            while end > 0, src[end - 1] == UInt8(ascii: "=") { end -= 1 }
            if end % 4 == 1 { return nil }
            var out = [UInt8](repeating: 0, count: end / 4 * 3 + max(0, end % 4 - 1))
            var ok = true
            out.withUnsafeMutableBufferPointer { dst in
                var acc: UInt32 = 0, bits = 0, j = 0
                for i in 0..<end {
                    let v = base64Table[Int(src[i])]
                    if v == 255 { ok = false; return }
                    acc = acc << 6 | UInt32(v)
                    bits += 6
                    if bits >= 8 {
                        bits -= 8
                        dst[j] = UInt8(truncatingIfNeeded: acc >> UInt32(bits))
                        j += 1
                    }
                }
            }
            return ok ? out : nil
        }
    }

    private static let base64Table: [UInt8] = {
        var t = [UInt8](repeating: 255, count: 256)
        let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789".utf8)
        for (i, c) in chars.enumerated() { t[Int(c)] = UInt8(i) }
        t[Int(UInt8(ascii: "-"))] = 62; t[Int(UInt8(ascii: "+"))] = 62
        t[Int(UInt8(ascii: "_"))] = 63; t[Int(UInt8(ascii: "/"))] = 63
        return t
    }()

    /// Positions are kept to 1/256 point (core/ink.js `POINTS2_SCALE`): at the deepest zoom (10×) on
    /// a 3× screen a point is 30 pixels, so a position is never more than 0.06 of a pixel off,
    /// whatever the zoom or size it was drawn at. Pressure and nib angle are kept to 1/4096.
    public static let scale2 = 256.0, levels2: Int64 = 4096
    /// Version 1 (still read): 1/20 point, one byte each for pressure and angle.
    public static let scale2v1 = 20.0

    /// The fields that store points: `points2` when the vault writes compact points, else `points`.
    /// `had` (the record before) empties the other one if it was set.
    public static func fields(_ points: [InkPoint], compact: Bool, had: Record? = nil) -> [String: JSONValue] {
        var out: [String: JSONValue] = compact ? [InkStroke.Field.points2: .string(encode2(points))] : [InkStroke.Field.points: .string(encode(points))]
        if let had {
            if compact, let old = had[InkStroke.Field.points]?.string, !old.isEmpty { out[InkStroke.Field.points] = .string("") }
            if !compact, let old = had[InkStroke.Field.points2]?.string, !old.isEmpty { out[InkStroke.Field.points2] = .string("") }
        }
        return out
    }

    private static func roundHalfUp(_ v: Double) -> Int64 { Int64((v + 0.5).rounded(.down)) }

    private static func varint(_ n: Int64, into out: inout [UInt8]) {
        var v = UInt64(n)
        while v >= 128 { out.append(UInt8(v % 128) + 128); v /= 128 }
        out.append(UInt8(v))
    }

    /// A nib angle in [0, π) as a whole number of π/4096 steps, 0…4095.
    private static func angleLevel(_ a: Double) -> Int64 {
        var v = a.truncatingRemainder(dividingBy: Double.pi)
        if v < 0 { v += Double.pi }
        return roundHalfUp(v / Double.pi * Double(levels2)) % levels2
    }

    /// `points2` version 2 (PROTOCOL.md §10, core/ink.js `encodePoints2`): byte 2, flags (1 = nib
    /// angles), a varint count, then per point zigzag varint steps: x and y in 1/256 points,
    /// pressure in 1/4096, the time in ms (plain varint) and, with angles, the angle in π/4096 the
    /// short way round.
    public static func encode2(_ points: [InkPoint]) -> String {
        let angles = points.contains { $0.angle != nil }
        var out: [UInt8] = [2, angles ? 1 : 0]
        varint(Int64(points.count), into: &out)
        var px: Int64 = 0, py: Int64 = 0, pp: Int64 = 0, pt: Int64 = 0, pa: Int64 = 0
        func fin(_ v: Double) -> Double { v.isFinite ? v : 0 }
        // Far past any page; keeps the steps inside Int64.
        func place(_ v: Double) -> Int64 { roundHalfUp(min(1e9, max(-1e9, fin(v))) * scale2) }
        func zigzag(_ n: Int64) -> Int64 { n >= 0 ? 2 * n : -2 * n - 1 }
        for p in points {
            let x = place(p.x), y = place(p.y)
            let pr = roundHalfUp(min(1, max(0, fin(p.pressure))) * Double(levels2))
            let t = max(pt, roundHalfUp(max(0, fin(p.t))))
            varint(zigzag(x - px), into: &out)
            varint(zigzag(y - py), into: &out)
            varint(zigzag(pr - pp), into: &out)
            varint(t - pt, into: &out)
            if angles {
                let a = angleLevel(fin(p.angle ?? InkGeometry.nibAngle))
                var d = (a - pa) % levels2
                if d >= levels2 / 2 { d -= levels2 } else if d < -levels2 / 2 { d += levels2 }
                varint(zigzag(d), into: &out)
                pa = a
            }
            px = x; py = y; pp = pr; pt = t
        }
        return Data(out).base64URL
    }

    /// Reads `points2` version 2, and version 1 (1/20 point, one byte each for pressure and angle).
    public static func decode2(_ string: String) -> [InkPoint] {
        guard let bytes = base64URLBytes(string), bytes.count >= 3, bytes[0] == 1 || bytes[0] == 2 else { return [] }
        let v1 = bytes[0] == 1, angles = bytes[1] & 1 == 1
        let scale = v1 ? scale2v1 : scale2
        var i = 2
        func varint() -> Int64? {
            var n: UInt64 = 0, shift: UInt64 = 0
            while i < bytes.count, shift <= 49 {
                let b = bytes[i]
                i += 1
                n |= UInt64(b & 127) << shift
                if b < 128 { return Int64(n) }
                shift += 7
            }
            return nil
        }
        func byte() -> Int64? {
            guard i < bytes.count else { return nil }
            i += 1
            return Int64(bytes[i - 1])
        }
        func unzigzag(_ z: Int64) -> Int64 { z % 2 == 0 ? z / 2 : -(z + 1) / 2 }
        var out: [InkPoint] = []
        guard let count = varint() else { return [] }
        var x: Int64 = 0, y: Int64 = 0, p: Int64 = 0, t: Int64 = 0, a: Int64 = 0
        var k: Int64 = 0
        while k < count {
            guard let dx = varint(), let dy = varint() else { break }
            x += unzigzag(dx)
            y += unzigzag(dy)
            if v1 { guard let b = byte() else { break }; p = b } else { guard let dp = varint() else { break }; p += unzigzag(dp) }
            guard let dt = varint() else { break }
            t += dt
            let pressure = min(1, max(0, v1 ? Double(p) / 255 : Double(p) / Double(levels2)))
            var point = InkPoint(x: Double(x) / scale, y: Double(y) / scale, pressure: pressure, t: Double(t))
            if angles {
                if v1 {
                    guard let b = byte() else { break }
                    point.angle = Double(b) * Double.pi / 256
                } else {
                    guard let da = varint() else { break }
                    a = ((a + unzigzag(da)) % levels2 + levels2) % levels2
                    point.angle = Double(a) * Double.pi / Double(levels2)
                }
            }
            out.append(point)
            k += 1
        }
        return out
    }
}

/// The paper a sketch page is printed with (core/ink.js `PAPERS`).
public enum InkPaper: String, Codable, CaseIterable, Sendable {
    case blank, lined, narrow, wide, margin, grid, smallgrid, graph, dotted, smalldots, isometric
    case cornell, todo, planner, storyboard, music, calligraphy

    /// Line spacing in page points (the default for every lined, squared and dotted paper).
    public static let spacing = 32.0

    /// This paper's spacing (core/ink.js `paperSpacing`).
    public var spacing: Double {
        switch self {
        case .narrow: 24
        case .wide, .todo: 40
        case .smallgrid, .smalldots: 16
        case .graph, .music: 8
        case .isometric: 24
        default: Self.spacing
        }
    }

    public var title: String {
        switch self {
        case .blank: "Blank"
        case .lined: "Lined"
        case .narrow: "Narrow lined"
        case .wide: "Wide lined"
        case .margin: "Lined with margin"
        case .grid: "Squared"
        case .smallgrid: "Small squares"
        case .graph: "Graph paper"
        case .dotted: "Dotted"
        case .smalldots: "Small dots"
        case .isometric: "Isometric dots"
        case .cornell: "Cornell notes"
        case .todo: "To-do list"
        case .planner: "Week planner"
        case .storyboard: "Storyboard"
        case .music: "Music"
        case .calligraphy: "Handwriting guides"
        }
    }

    /// Papers grouped for pickers (core/ink.js `PAPER_GROUPS`).
    public static let groups: [(title: String, papers: [InkPaper])] = [
        ("Plain", [.blank]), ("Lines", [.lined, .narrow, .wide, .margin, .calligraphy]), ("Grids", [.grid, .smallgrid, .graph]),
        ("Dots", [.dotted, .smalldots, .isometric]), ("Layouts", [.cornell, .todo, .planner, .storyboard, .music]),
    ]
}

/// Named page sizes in page points, portrait (core/ink.js `PAGE_SIZES`): real sizes scaled so a page
/// is about 768 points wide, so pens look the same on each. Landscape swaps them.
public enum InkPageSize: String, CaseIterable, Sendable {
    case tablet, a4, a5, letter, legal, square, wide, phone

    public var size: (width: Double, height: Double) {
        switch self {
        case .tablet: (768, 1024)
        case .a4: (768, 1086)
        case .a5: (543, 768)
        case .letter: (791, 1024)
        case .legal: (791, 1303)
        case .square: (768, 768)
        case .wide: (576, 1024)
        case .phone: (473, 1024)
        }
    }

    public var title: String {
        switch self {
        case .tablet: "iPad"
        case .a4: "A4"
        case .a5: "A5"
        case .letter: "US Letter"
        case .legal: "US Legal"
        case .square: "Square"
        case .wide: "Widescreen 16:9"
        case .phone: "Phone"
        }
    }

    /// The named size and orientation of a size, if it is one.
    public static func named(_ w: Double, _ h: Double) -> (size: InkPageSize, landscape: Bool)? {
        for s in allCases {
            let (a, b) = s.size
            if w == a && h == b { return (s, false) }
            if w == b && h == a { return (s, a != b) }
        }
        return nil
    }

    public func dimensions(landscape: Bool) -> [Double] {
        let (a, b) = size
        return landscape ? [b, a] : [a, b]
    }
}

/// One page of a sketch: a stable id (so pages can be reordered while another device draws), and
/// its own paper and colour when they differ from the sketch's.
public struct InkPage: Equatable, Sendable, Identifiable {
    public var id: String
    public var paper: InkPaper?
    /// "#rrggbb"; white when nil.
    public var color: String?
    /// [width, height] in page points when the page has its own size.
    public var size: [Double]?

    public init(id: String, paper: InkPaper? = nil, color: String? = nil, size: [Double]? = nil) {
        self.id = id; self.paper = paper; self.color = color; self.size = Self.valid(size)
    }

    init?(json: JSONValue) {
        guard let o = json.object, let id = o["id"]?.string, !id.isEmpty else { return nil }
        self.init(id: id, paper: o["paper"]?.string.flatMap(InkPaper.init(rawValue:)), color: o["color"]?.string, size: o["size"]?.array?.compactMap(\.number))
    }

    var json: JSONValue {
        var o: [String: JSONValue] = ["id": .string(id)]
        if let paper { o["paper"] = .string(paper.rawValue) }
        if let color { o["color"] = .string(color) }
        if let size { o["size"] = .array(size.map(JSONValue.number)) }
        return .object(o)
    }

    /// [w, h] if it's a usable page size (36 to 4000 points a side), like core/ink.js `validSize`.
    public static func valid(_ size: [Double]?) -> [Double]? {
        guard let size, size.count == 2, size.allSatisfy({ $0 >= 36 && $0 <= 4000 }) else { return nil }
        return size
    }

    /// A stroke's or element's `page` field as a page id: numbers are the old page indexes.
    public static func key(_ value: JSONValue?) -> String {
        if let s = value?.string { return s }
        if let n = value?.number { return int(n).map(String.init) ?? "0" }
        return "0"
    }

    /// A number as an Int, truncated, or nil when it isn't one an Int can hold (NaN, ±∞, huge):
    /// `Int(_:)` would stop the app on those.
    public static func int(_ n: Double) -> Int? {
        n.isFinite && abs(n) < 9e15 ? Int(n) : nil
    }

    /// Colours offered for pages.
    public static let colors = ["#ffffff", "#fbf6e9", "#fff7c2", "#fde8ec", "#eef5ec", "#eaf1fb", "#f2f2f2", "#3a3d42", "#26282c", "#121212"]
    public static let colorTitles = ["#ffffff": "White", "#fbf6e9": "Cream", "#fff7c2": "Yellow", "#fde8ec": "Pink", "#eef5ec": "Green", "#eaf1fb": "Blue",
                                     "#f2f2f2": "Grey", "#3a3d42": "Slate", "#26282c": "Dark", "#121212": "Black"]

    /// Paper lines show up on dark pages too.
    public static func isDark(_ color: String?) -> Bool {
        guard let color else { return false }
        let (r, g, b) = InkStroke.rgb(color)
        return 0.2126 * r + 0.7152 * g + 0.0722 * b < 0.4
    }
}

extension Item {
    public enum SketchField {
        public static let paper = "paper", pages = "pages", pageSize = "pageSize"
        public static let pageList = "pageList", canvas = "canvas", sketchText = "sketchText", inkText = "inkText"
    }

    /// A sketch's paper, page count and page size (768 × 1024 points unless set).
    public var paper: InkPaper { InkPaper(rawValue: record[SketchField.paper]?.string ?? "") ?? .blank }
    public var sketchPages: Int { sketchPageList.count }
    /// The pages in order. Sketches made before page ids have pages "0", "1", …
    public var sketchPageList: [InkPage] {
        let list = record[SketchField.pageList]?.array?.compactMap(InkPage.init(json:)) ?? []
        if !list.isEmpty { return list }
        let count = record[SketchField.pages]?.number.flatMap(InkPage.int) ?? 1
        return (0..<min(1000, max(1, count))).map { InkPage(id: String($0)) }
    }
    /// One endless page instead of pages.
    public var isInfiniteCanvas: Bool { record[SketchField.canvas]?.string == "infinite" }
    /// The words in a sketch's text boxes, and the handwriting an Apple device read, for search.
    public var sketchText: String? { record[SketchField.sketchText]?.string }
    public var inkText: String? { record[SketchField.inkText]?.string }
    /// Notebooks (attachment ids) whose ink was handed to Trove's editor (PROTOCOL.md §10).
    public var goodnotesInk: [String] { record["goodnotesInk"]?.array?.compactMap(\.string) ?? [] }
    public var sketchPageSize: (width: Double, height: Double) {
        let a = record[SketchField.pageSize]?.array?.compactMap(\.number) ?? []
        return a.count == 2 && a[0] > 0 && a[1] > 0 ? (a[0], a[1]) : (768, 1024)
    }
    /// A page's size: its own, else the sketch's.
    public func pageSize(of page: InkPage) -> (width: Double, height: Double) {
        if let s = page.size { return (s[0], s[1]) }
        return sketchPageSize
    }
}

extension Library {
    /// Strokes on an item (a sketch, or `layer` = the file's attachment id), oldest first, which is
    /// the order they're drawn in.
    public func strokes(on itemId: String, layer: String = "", page: Int? = nil) async -> [InkStroke] {
        let strokes = await engine.ink(on: itemId).filter { $0.kind == "stroke" }.map(InkStroke.init)
            .filter { $0.layer == layer && (page == nil || $0.page == page) }
        return Self.drawOrder(strokes, createdAt: { $0.record[InkStroke.Field.createdAt]?.number ?? 0 })
    }

    /// Oldest first, ties by id. Each record's time is read once (reading it in every comparison
    /// made a page's reload several times slower).
    static func drawOrder<T: Identifiable>(_ list: [T], createdAt: (T) -> Double) -> [T] where T.ID == String {
        let keyed: [(key: Double, value: T)] = list.map { (key: createdAt($0), value: $0) }
        let sorted = keyed.sorted { (a: (key: Double, value: T), b: (key: Double, value: T)) -> Bool in
            if a.key != b.key { return a.key < b.key }
            return a.value.id < b.value.id
        }
        return sorted.map { $0.value }
    }

    /// Every item that has ink on it, and on which layers.
    public func inkedLayers() async -> [String: Set<String>] {
        var out: [String: Set<String>] = [:]
        for r in await engine.records(kind: "stroke") {
            let s = InkStroke(r)
            out[s.on, default: []].insert(s.layer)
        }
        return out
    }

    /// Adds a stroke. `id` lets a drawing view that tracks its own strokes (PencilKit) name it.
    @discardableResult
    public func addStroke(id givenId: String? = nil, on itemId: String, layer: String = "", page: Int, tool: InkTool, color: String,
                          width: Double, points: [InkPoint]) async -> String? {
        guard !points.isEmpty else { return nil }
        let id = givenId ?? newId()
        // Strokes draw in creation order, so each one gets a later time than the last, even within a millisecond.
        let created = await nextInkTime(on: itemId)
        let compact = await inkSettings().compactPoints
        var fields: [String: JSONValue] = [
            InkStroke.Field.on: .string(itemId), InkStroke.Field.layer: .string(layer), InkStroke.Field.page: .number(Double(page)),
            InkStroke.Field.tool: .string(tool.rawValue), InkStroke.Field.color: .string(color), InkStroke.Field.width: .number(width),
            InkStroke.Field.createdAt: .number(created), InkStroke.Field.device: .string(await engine.device),
        ]
        fields.merge(InkPoints.fields(tool.stored(points), compact: compact)) { _, b in b }
        await engine.set(fields, record: id, kind: "stroke")
        return id
    }

    /// A small preview image for an item's card (shared with every device), e.g. a sketch's first page.
    public func setThumbnail(_ itemId: String, jpeg: Data) async throws {
        let blob = try await engine.storeBlob(jpeg)
        await update(itemId, [Field.thumbnail: Attachment(id: blob, name: "thumbnail.jpg", mime: "image/jpeg", size: jpeg.count).json])
    }

    public func deleteStrokes(_ ids: [String]) async {
        // With the kind, a delete that lands before the stroke is stored still names a stroke.
        for id in ids { await engine.set(["_deleted": .bool(true)], record: id, kind: "stroke") }
    }

    /// A new, empty sketch.
    @discardableResult
    public func addSketch(title: String = "", paper: InkPaper = .blank, folder: [String] = [], infinite: Bool = false) async -> String {
        let id = newId()
        var fields = await baseFields(kind: .sketch, source: .app, title: title)
        fields[Item.SketchField.paper] = .string(paper.rawValue)
        fields[Item.SketchField.pages] = .number(1)
        if infinite { fields[Item.SketchField.canvas] = .string("infinite") }
        fields.merge(await filing(kind: .sketch, source: .app, importPath: folder)) { _, b in b }
        await engine.set(fields, record: id, kind: "item")
        return id
    }

    public func setSketch(_ id: String, paper: InkPaper? = nil, pages: Int? = nil) async {
        var fields: [String: JSONValue] = [:]
        if let paper { fields[Item.SketchField.paper] = .string(paper.rawValue) }
        if let pages {
            // Sketches with page ids grow or shrink at the end.
            if let sketch = await item(id), sketch.record[Item.SketchField.pageList] != nil {
                var list = sketch.sketchPageList
                while list.count < max(1, pages) { list.append(InkPage(id: String(newId().prefix(8)), paper: list.last?.paper, color: list.last?.color)) }
                if list.count > max(1, pages) { list = Array(list.prefix(max(1, pages))) }
                fields[Item.SketchField.pageList] = .array(list.map(\.json))
            }
            fields[Item.SketchField.pages] = .number(Double(max(1, pages)))
        }
        if !fields.isEmpty { await update(id, fields) }
    }
}
