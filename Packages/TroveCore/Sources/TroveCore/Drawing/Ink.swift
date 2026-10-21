import Foundation

/// Drawing (PROTOCOL.md §10). Every stroke is its own `stroke` record, so two devices drawing at
/// once just add up, erasing is a delete and undo deletes your last stroke. The ink sits on a
/// sketch item's own pages, or on top of a file (a PDF page or an image), which never changes.
/// web/public/core/ink.js is the same code for the website; both check Fixtures/ink-cases.json.
public enum InkTool: String, Codable, CaseIterable, Sendable {
    case pen, pencil, marker, highlighter, fountain, brush

    /// How see-through the ink is.
    public var opacity: Double {
        switch self {
        case .pen, .marker, .fountain, .brush: 1
        case .pencil: 0.85
        case .highlighter: 0.35
        }
    }

    /// Pens, pencils, fountain pens and brushes get thinner when pressed lightly; markers and highlighters don't.
    public var usesPressure: Bool { self != .marker && self != .highlighter }
}

public struct InkPoint: Sendable, Equatable {
    /// In page points (a PDF page's points, an image's pixels, or a sketch page).
    public var x: Double
    public var y: Double
    /// 0…1 (0.5 when the device can't tell).
    public var pressure: Double
    /// Milliseconds since the stroke started.
    public var t: Double

    public init(x: Double, y: Double, pressure: Double = 0.5, t: Double = 0) {
        self.x = x; self.y = y; self.pressure = pressure; self.t = t
    }
}

public struct InkStroke: Identifiable, Sendable {
    public enum Field {
        public static let on = "on", layer = "layer", page = "page", tool = "tool", color = "color", width = "width"
        public static let points = "points", createdAt = "createdAt", device = "device", shape = "shape"
    }

    public let record: Record
    public init(_ record: Record) { self.record = record }

    public var id: String { record.id }
    /// The item the ink belongs to.
    public var on: String { record[Field.on]?.string ?? "" }
    /// "" for a sketch's own pages, or the attachment id of the file it's drawn on.
    public var layer: String { record[Field.layer]?.string ?? "" }
    /// 0-based page of a file (PDF page, or 0 for an image).
    public var page: Int { Int(record[Field.page]?.number ?? Double(record[Field.page]?.string ?? "") ?? 0) }
    /// The page as a sketch knows it: its id in `pageList` (a number n is the page "n").
    public var pageKey: String { InkPage.key(record[Field.page]) }
    /// The clean shape this stroke was snapped to, if any.
    public var shape: String? { record[Field.shape]?.string }
    public var tool: InkTool { InkTool(rawValue: record[Field.tool]?.string ?? "") ?? .pen }
    /// "#rrggbb".
    public var color: String { record[Field.color]?.string ?? "#000000" }
    /// The full width, in page points.
    public var width: Double { record[Field.width]?.number ?? 2 }
    public var points: [InkPoint] { InkPoints.decode(record[Field.points]?.string ?? "") }
    public var createdAt: Date { record[Field.createdAt]?.date ?? Date(timeIntervalSince1970: 0) }

    /// The width at a point: pressure thins pens and pencils (35 % of `width` at no pressure) and
    /// brushes (15 %). A fountain pen also follows its direction (`InkGeometry.fountainWidth`).
    public static func width(_ width: Double, tool: InkTool, pressure: Double) -> Double {
        let p = min(1, max(0, pressure))
        switch tool {
        case .pen, .pencil: return width * (0.35 + 0.65 * p)
        case .brush: return width * (0.15 + 0.85 * p)
        case .fountain: return width * (0.6 + 0.4 * p)
        case .marker, .highlighter: return width
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
        guard let data = Data(base64URL: string) else { return [] }
        let bytes = [UInt8](data)
        func f(_ i: Int) -> Double {
            Double(Float(bitPattern: UInt32(bytes[i]) | UInt32(bytes[i + 1]) << 8 | UInt32(bytes[i + 2]) << 16 | UInt32(bytes[i + 3]) << 24))
        }
        return stride(from: 0, to: bytes.count - bytes.count % 16, by: 16).map { InkPoint(x: f($0), y: f($0 + 4), pressure: f($0 + 8), t: f($0 + 12)) }
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
        if let n = value?.number { return String(Int(n)) }
        return "0"
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
        return (0..<max(1, Int(record[SketchField.pages]?.number ?? 1))).map { InkPage(id: String($0)) }
    }
    /// One endless page instead of pages.
    public var isInfiniteCanvas: Bool { record[SketchField.canvas]?.string == "infinite" }
    /// The words in a sketch's text boxes, and the handwriting an Apple device read, for search.
    public var sketchText: String? { record[SketchField.sketchText]?.string }
    public var inkText: String? { record[SketchField.inkText]?.string }
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
        await engine.ink(on: itemId).filter { $0.kind == "stroke" }.map(InkStroke.init)
            .filter { $0.layer == layer && (page == nil || $0.page == page) }
            .sorted { $0.createdAt != $1.createdAt ? $0.createdAt < $1.createdAt : $0.id < $1.id }
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
        await engine.set([
            InkStroke.Field.on: .string(itemId), InkStroke.Field.layer: .string(layer), InkStroke.Field.page: .number(Double(page)),
            InkStroke.Field.tool: .string(tool.rawValue), InkStroke.Field.color: .string(color), InkStroke.Field.width: .number(width),
            InkStroke.Field.points: .string(InkPoints.encode(points)), InkStroke.Field.createdAt: .number(created),
            InkStroke.Field.device: .string(await engine.device),
        ], record: id, kind: "stroke")
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
