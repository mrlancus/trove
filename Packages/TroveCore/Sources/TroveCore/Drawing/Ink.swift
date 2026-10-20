import Foundation

/// Drawing (PROTOCOL.md §10). Every stroke is its own `stroke` record, so two devices drawing at
/// once just add up, erasing is a delete and undo deletes your last stroke. The ink sits on a
/// sketch item's own pages, or on top of a file (a PDF page or an image), which never changes.
/// web/public/core/ink.js is the same code for the website; both check Fixtures/ink-cases.json.
public enum InkTool: String, Codable, CaseIterable, Sendable {
    case pen, pencil, marker, highlighter

    /// How see-through the ink is.
    public var opacity: Double {
        switch self {
        case .pen, .marker: 1
        case .pencil: 0.85
        case .highlighter: 0.35
        }
    }

    /// Pen and pencil get thinner when pressed lightly; markers and highlighters don't.
    public var usesPressure: Bool { self == .pen || self == .pencil }
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
        public static let points = "points", createdAt = "createdAt", device = "device"
    }

    public let record: Record
    public init(_ record: Record) { self.record = record }

    public var id: String { record.id }
    /// The item the ink belongs to.
    public var on: String { record[Field.on]?.string ?? "" }
    /// "" for a sketch's own pages, or the attachment id of the file it's drawn on.
    public var layer: String { record[Field.layer]?.string ?? "" }
    /// 0-based page.
    public var page: Int { Int(record[Field.page]?.number ?? 0) }
    public var tool: InkTool { InkTool(rawValue: record[Field.tool]?.string ?? "") ?? .pen }
    /// "#rrggbb".
    public var color: String { record[Field.color]?.string ?? "#000000" }
    /// The full width, in page points.
    public var width: Double { record[Field.width]?.number ?? 2 }
    public var points: [InkPoint] { InkPoints.decode(record[Field.points]?.string ?? "") }
    public var createdAt: Date { record[Field.createdAt]?.date ?? Date(timeIntervalSince1970: 0) }

    /// The width at a point: pressure thins pens and pencils (35 % of `width` at no pressure).
    public static func width(_ width: Double, tool: InkTool, pressure: Double) -> Double {
        tool.usesPressure ? width * (0.35 + 0.65 * min(1, max(0, pressure))) : width
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

/// Lined, squared or dotted paper for a sketch.
public enum InkPaper: String, Codable, CaseIterable, Sendable {
    case blank, lined, grid, dotted

    /// Line spacing in page points.
    public static let spacing = 32.0
}

extension Item {
    public enum SketchField {
        public static let paper = "paper", pages = "pages", pageSize = "pageSize"
    }

    /// A sketch's paper, page count and page size (768 × 1024 points unless set).
    public var paper: InkPaper { InkPaper(rawValue: record[SketchField.paper]?.string ?? "") ?? .blank }
    public var sketchPages: Int { max(1, Int(record[SketchField.pages]?.number ?? 1)) }
    public var sketchPageSize: (width: Double, height: Double) {
        let a = record[SketchField.pageSize]?.array?.compactMap(\.number) ?? []
        return a.count == 2 && a[0] > 0 && a[1] > 0 ? (a[0], a[1]) : (768, 1024)
    }
}

extension Library {
    /// Strokes on an item (a sketch, or `layer` = the file's attachment id), oldest first, which is
    /// the order they're drawn in.
    public func strokes(on itemId: String, layer: String = "", page: Int? = nil) async -> [InkStroke] {
        await engine.records.filter { $0.kind == "stroke" }.map(InkStroke.init)
            .filter { $0.on == itemId && $0.layer == layer && (page == nil || $0.page == page) }
            .sorted { $0.createdAt != $1.createdAt ? $0.createdAt < $1.createdAt : $0.id < $1.id }
    }

    /// Every item that has ink on it, and on which layers.
    public func inkedLayers() async -> [String: Set<String>] {
        var out: [String: Set<String>] = [:]
        for r in await engine.records where r.kind == "stroke" {
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
        let latest = await engine.records.filter { $0.kind == "stroke" && $0[InkStroke.Field.on]?.string == itemId }
            .compactMap { $0[InkStroke.Field.createdAt]?.number }.max() ?? 0
        let created = max((now().timeIntervalSince1970 * 1000).rounded(), latest + 1)
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
        for id in ids { await engine.delete(id) }
    }

    /// A new, empty sketch.
    @discardableResult
    public func addSketch(title: String = "", paper: InkPaper = .blank, folder: [String] = []) async -> String {
        let id = newId()
        var fields = await baseFields(kind: .sketch, source: .app, title: title)
        fields[Item.SketchField.paper] = .string(paper.rawValue)
        fields[Item.SketchField.pages] = .number(1)
        fields.merge(await filing(kind: .sketch, source: .app, importPath: folder)) { _, b in b }
        await engine.set(fields, record: id, kind: "item")
        return id
    }

    public func setSketch(_ id: String, paper: InkPaper? = nil, pages: Int? = nil) async {
        var fields: [String: JSONValue] = [:]
        if let paper { fields[Item.SketchField.paper] = .string(paper.rawValue) }
        if let pages { fields[Item.SketchField.pages] = .number(Double(max(1, pages))) }
        if !fields.isEmpty { await update(id, fields) }
    }
}
