import Foundation

/// A text box or a picture placed on a sketch page or on a file (PROTOCOL.md §10): an `element`
/// record. Pictures draw under the ink and text boxes over it.
public struct InkElement: Identifiable, Sendable {
    /// Tape (`tape`) is a strip that hides what's under it until tapped.
    public enum Kind: String, Sendable { case text, image, tape }
    public enum Field {
        public static let on = "on", layer = "layer", page = "page", type = "type", x = "x", y = "y", w = "w", h = "h"
        public static let text = "text", size = "size", color = "color", image = "image", createdAt = "createdAt", device = "device"
        public static let rotate = "rotate", flip = "flip", font = "font", bold = "bold", italic = "italic", group = "group"
    }

    public let record: Record
    public init(_ record: Record) { self.record = record }

    public var id: String { record.id }
    public var on: String { record[Field.on]?.string ?? "" }
    public var layer: String { record[Field.layer]?.string ?? "" }
    public var pageKey: String { InkPage.key(record[Field.page]) }
    public var kind: Kind { Kind(rawValue: record[Field.type]?.string ?? "") ?? .text }
    /// Where it sits, in page points. A text box grows downwards as it wraps, so `h` is a minimum.
    public var frame: InkGeometry.Rect {
        InkGeometry.Rect(x: record[Field.x]?.number ?? 0, y: record[Field.y]?.number ?? 0,
                         width: max(1, record[Field.w]?.number ?? 200), height: max(1, record[Field.h]?.number ?? 40))
    }
    public var text: String { record[Field.text]?.string ?? "" }
    /// Font size in page points.
    public var size: Double { record[Field.size]?.number ?? 20 }
    public var color: String { record[Field.color]?.string ?? "#000000" }
    public var image: Attachment? { record[Field.image].flatMap(Attachment.init(json:)) }
    public var createdAt: Date { record[Field.createdAt]?.date ?? Date(timeIntervalSince1970: 0) }
    /// Radians, clockwise about the box's centre (0 when unset or not a real number).
    public var rotate: Double {
        guard let r = record[Field.rotate]?.number, r.isFinite else { return 0 }
        return r
    }
    /// A picture mirrored left to right (before turning).
    public var flip: Bool { kind == .image && record[Field.flip]?.bool == true }
    public var font: InkTextStyle.Font { InkTextStyle.Font(rawValue: record[Field.font]?.string ?? "") ?? .sans }
    public var bold: Bool { record[Field.bold]?.bool == true }
    public var italic: Bool { record[Field.italic]?.bool == true }
    public var textStyle: InkTextStyle { InkTextStyle(font: font, bold: bold, italic: italic) }
    /// Strokes and elements sharing a group id are picked and moved as one; "" for none.
    public var group: String { record[Field.group]?.string ?? "" }
    /// The box, its turn and (pictures) mirroring, for hit tests and the lasso.
    public var editFrame: InkEditing.Frame { InkEditing.Frame(frame, rotate: rotate, flip: flip) }
}

/// A text box's typeface and weight (PROTOCOL.md §10 "Text style"). Bullet lists are plain text:
/// lines starting "• ".
public struct InkTextStyle: Equatable, Sendable {
    public enum Font: String, CaseIterable, Sendable {
        case sans, serif, mono, rounded
        public var title: String {
            switch self {
            case .sans: "Sans"
            case .serif: "Serif"
            case .mono: "Mono"
            case .rounded: "Rounded"
            }
        }
    }
    public var font: Font
    public var bold: Bool
    public var italic: Bool
    public init(font: Font = .sans, bold: Bool = false, italic: Bool = false) { self.font = font; self.bold = bold; self.italic = italic }

    /// The fields to store; `all` writes the off values too (to turn a style off).
    public func fields(all: Bool = false) -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        if font != .sans || all { out[InkElement.Field.font] = .string(font.rawValue) }
        if bold || all { out[InkElement.Field.bold] = .bool(bold) }
        if italic || all { out[InkElement.Field.italic] = .bool(italic) }
        return out
    }

    /// Bullets on (or off, when every line already has one) for the lines of `text`.
    public static func toggleBullets(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        let on = !lines.allSatisfy { $0.hasPrefix("• ") }
        let out = lines.map { (l: String) -> String in
            if on { return l.hasPrefix("• ") ? l : "• " + l }
            return l.hasPrefix("• ") ? String(l.dropFirst(2)) : l
        }
        return out.joined(separator: "\n")
    }
}

extension Library {
    // MARK: Strokes by page id

    /// Strokes on one page of a sketch (or a file's layer), oldest first.
    public func strokes(on itemId: String, layer: String = "", pageKey: String) async -> [InkStroke] {
        await strokes(on: itemId, layer: layer).filter { $0.pageKey == pageKey }
    }

    /// Adds a stroke on a sketch page by its id. `createdAt` keeps a stroke's place when the partial
    /// eraser replaces it with its pieces; `shape` names a snapped shape.
    @discardableResult
    public func addStroke(id givenId: String? = nil, on itemId: String, layer: String = "", pageKey: String, tool: InkTool, color: String, width: Double,
                          points: [InkPoint], shape: String? = nil, createdAt: Double? = nil, style: InkStrokeStyle? = nil,
                          group: String = "", from: String = "", to: String = "") async -> String? {
        guard !points.isEmpty else { return nil }
        let id = givenId ?? newId()
        let created: Double
        if let createdAt { created = createdAt } else { created = await nextInkTime(on: itemId) }
        let compact = await inkSettings().compactPoints
        var fields: [String: JSONValue] = [
            InkStroke.Field.on: .string(itemId), InkStroke.Field.layer: .string(layer), InkStroke.Field.page: .string(pageKey),
            InkStroke.Field.tool: .string(tool.rawValue), InkStroke.Field.color: .string(color), InkStroke.Field.width: .number(width),
            InkStroke.Field.createdAt: .number(created), InkStroke.Field.device: .string(await engine.device),
        ]
        fields.merge(InkPoints.fields(tool.stored(points), compact: compact)) { _, b in b }
        if let shape { fields[InkStroke.Field.shape] = .string(shape) }
        if let style { fields.merge(style.fields) { _, b in b } }
        if !group.isEmpty { fields[InkStroke.Field.group] = .string(group) }
        if !from.isEmpty { fields[InkStroke.Field.from] = .string(from) }
        if !to.isEmpty { fields[InkStroke.Field.to] = .string(to) }
        // `points` can't hold per-point nib angles: keep their average as the stroke's `nib`.
        if !compact, fields[InkStroke.Field.nib] == nil, let nib = InkOutline.meanNib(points) { fields[InkStroke.Field.nib] = .number(nib) }
        await engine.set(fields, record: id, kind: "stroke")
        return id
    }

    /// A later time than anything drawn on the item, so new ink draws on top. The store keeps the
    /// newest time per item, so this no longer reads every stroke on each new one.
    func nextInkTime(on itemId: String) async -> Double {
        let latest = await engine.newestInkTime(on: itemId) ?? 0
        return max((now().timeIntervalSince1970 * 1000).rounded(), latest + 1)
    }

    /// Moves, resizes, turns, flips or recolours strokes (the lasso). Widths scale with the shape,
    /// and a fountain pen's nib turns with it.
    public func transformStrokes(_ ids: [String], by transform: InkGeometry.Transform? = nil, color: String? = nil) async {
        // A move or resize that isn't a real number would store points nothing can draw.
        if let transform, !transform.isUsable { return }
        let compact = await inkSettings().compactPoints
        for id in ids {
            guard let r = await engine.record(id), r.kind == "stroke", !r.isDeleted else { continue }
            let stroke = InkStroke(r)
            var fields: [String: JSONValue] = [:]
            if let transform {
                fields.merge(InkPoints.fields(stroke.points.map(transform.apply), compact: compact, had: r)) { _, b in b }
                if transform.widthScale != 1 { fields[InkStroke.Field.width] = .number(stroke.width * transform.widthScale) }
                if let nib = stroke.style.nib, transform.changesAngles { fields[InkStroke.Field.nib] = .number(transform.angle(nib)) }
            }
            if let color { fields[InkStroke.Field.color] = .string(color) }
            if !fields.isEmpty { await engine.set(fields, record: id, kind: "stroke") }
        }
    }

    /// The partial eraser: each stroke the eraser crossed is replaced by what's left of it, drawn
    /// in the same place among the others. Returns the ids of the new pieces.
    @discardableResult
    public func eraseStrokes(on itemId: String, layer: String = "", pageKey: String, along path: [InkPoint], radius: Double,
                             only tools: Set<InkTool>? = nil, near: Set<String>? = nil) async -> [String] {
        var added: [String] = []
        for stroke in await strokes(on: itemId, layer: layer, pageKey: pageKey) {
            if let tools, !tools.contains(stroke.tool) { continue }
            if let near, !near.contains(stroke.id) { continue }
            guard let pieces = InkGeometry.erase(stroke.points, along: path, radius: radius + stroke.width / 2) else { continue }
            await engine.delete(stroke.id)
            for piece in pieces {
                if let id = await addStroke(on: itemId, layer: layer, pageKey: pageKey, tool: stroke.tool, color: stroke.color,
                                            width: stroke.width, points: piece, shape: nil,
                                            createdAt: stroke.createdAt.timeIntervalSince1970 * 1000, style: Self.pieceStyle(stroke.style),
                                            group: stroke.group) { added.append(id) }
            }
        }
        return added
    }

    /// What pieces of an erased stroke keep: dashes and nib (a piece of a shape is no longer that shape, so no fill or arrows).
    static func pieceStyle(_ s: InkStrokeStyle) -> InkStrokeStyle { InkStrokeStyle(dash: s.dash, nib: s.nib) }

    /// Replaces a stroke with pieces of it, drawn in its place (a partial erase the editor already
    /// worked out while showing it). No pieces deletes it. Returns the pieces' ids.
    @discardableResult
    public func replaceStroke(_ id: String, with pieces: [[InkPoint]]) async -> [String] {
        guard let r = await engine.record(id), r.kind == "stroke", !r.isDeleted else { return [] }
        let s = InkStroke(r)
        await engine.delete(id)
        var out: [String] = []
        for piece in pieces where piece.count >= 2 {
            if let new = await addStroke(on: s.on, layer: s.layer, pageKey: s.pageKey, tool: s.tool, color: s.color, width: s.width, points: piece,
                                         createdAt: s.createdAt.timeIntervalSince1970 * 1000, style: Self.pieceStyle(s.style), group: s.group) { out.append(new) }
        }
        return out
    }

    /// Copies of strokes and elements on a page (duplicate, paste), moved by `transform`. Copied
    /// groups become new groups, and a copied connector stays joined only to copies.
    @discardableResult
    public func duplicateInk(strokes strokeIds: [String], elements elementIds: [String], to itemId: String, layer: String = "",
                             pageKey: String, by transform: InkGeometry.Transform = .move(20, 20)) async -> [String] {
        var out: [String] = []
        guard transform.isUsable else { return out }
        var groups: [String: String] = [:], copies: [String: String] = [:]
        var connectors: [(copy: String, from: String, to: String)] = []
        func groupOf(_ g: String) -> String {
            if g.isEmpty { return "" }
            if let known = groups[g] { return known }
            let fresh = newId()
            groups[g] = fresh
            return fresh
        }
        for id in strokeIds {
            guard let r = await engine.record(id), r.kind == "stroke", !r.isDeleted else { continue }
            let s = InkStroke(r)
            var style = s.style
            if let nib = style.nib, transform.changesAngles { style.nib = transform.angle(nib) }
            if let new = await addStroke(on: itemId, layer: layer, pageKey: pageKey, tool: s.tool, color: s.color, width: s.width * transform.widthScale,
                                         points: s.points.map(transform.apply), shape: s.shape, style: style, group: groupOf(s.group)) {
                out.append(new)
                copies[id] = new
                if !s.from.isEmpty || !s.to.isEmpty { connectors.append((new, s.from, s.to)) }
            }
        }
        for id in elementIds {
            guard let r = await engine.record(id), r.kind == "element", !r.isDeleted else { continue }
            let e = InkElement(r)
            let moved = InkEditing.transform(transform, e.editFrame, image: e.kind == .image)
            let new = await addElement(on: itemId, layer: layer, pageKey: pageKey, kind: e.kind, frame: moved.rect,
                                       text: e.text, size: e.size * transform.widthScale, color: e.color, image: e.image,
                                       rotate: moved.rotate, flip: moved.flip, textStyle: e.textStyle, group: groupOf(e.group))
            out.append(new)
            copies[id] = new
        }
        for c in connectors {
            await engine.set([InkStroke.Field.from: .string(copies[c.from] ?? ""), InkStroke.Field.to: .string(copies[c.to] ?? "")], record: c.copy, kind: "stroke")
        }
        return out
    }

    // MARK: Text boxes and pictures

    public func elements(on itemId: String, layer: String = "", pageKey: String? = nil) async -> [InkElement] {
        let elements = await engine.ink(on: itemId).filter { $0.kind == "element" }.map(InkElement.init)
            .filter { $0.layer == layer && (pageKey == nil || $0.pageKey == pageKey) }
        return Self.drawOrder(elements, createdAt: { $0.record[InkElement.Field.createdAt]?.number ?? 0 })
    }

    @discardableResult
    public func addElement(on itemId: String, layer: String = "", pageKey: String, kind: InkElement.Kind, frame: InkGeometry.Rect,
                           text: String = "", size: Double = 20, color: String = "#000000", image: Attachment? = nil,
                           rotate: Double = 0, flip: Bool = false, textStyle: InkTextStyle = InkTextStyle(), group: String = "") async -> String {
        let id = newId()
        var fields: [String: JSONValue] = [
            InkElement.Field.on: .string(itemId), InkElement.Field.layer: .string(layer), InkElement.Field.page: .string(pageKey),
            InkElement.Field.type: .string(kind.rawValue), InkElement.Field.x: .number(frame.x), InkElement.Field.y: .number(frame.y),
            InkElement.Field.w: .number(frame.width), InkElement.Field.h: .number(frame.height),
            InkElement.Field.createdAt: .number(await nextInkTime(on: itemId)), InkElement.Field.device: .string(await engine.device),
        ]
        if kind == .text {
            fields[InkElement.Field.text] = .string(text)
            fields[InkElement.Field.size] = .number(size)
            fields[InkElement.Field.color] = .string(color)
        }
        if kind == .tape { fields[InkElement.Field.color] = .string(color) }
        if let image { fields[InkElement.Field.image] = image.json }
        if rotate != 0, rotate.isFinite { fields[InkElement.Field.rotate] = .number(rotate) }
        if kind == .image, flip { fields[InkElement.Field.flip] = .bool(true) }
        if kind == .text { fields.merge(textStyle.fields()) { _, b in b } }
        if !group.isEmpty { fields[InkElement.Field.group] = .string(group) }
        await engine.set(fields, record: id, kind: "element")
        if kind == .text { await refreshSketchText(itemId) }
        return id
    }

    /// Picture bytes become an encrypted blob, placed at `frame`.
    @discardableResult
    public func addPicture(_ data: Data, mime: String, on itemId: String, layer: String = "", pageKey: String, frame: InkGeometry.Rect) async throws -> String {
        let blob = try await engine.storeBlob(data)
        let ext = mime == "image/jpeg" ? "jpg" : (mime.split(separator: "/").last.map(String.init) ?? "png")
        return await addElement(on: itemId, layer: layer, pageKey: pageKey, kind: .image, frame: frame,
                                image: Attachment(id: blob, name: "Picture.\(ext)", mime: mime, size: data.count))
    }

    /// Changes a text box, picture or tape strip; `textStyle` writes font, bold and italic (off values too).
    public func updateElement(_ id: String, frame: InkGeometry.Rect? = nil, text: String? = nil, size: Double? = nil, color: String? = nil,
                              rotate: Double? = nil, flip: Bool? = nil, textStyle: InkTextStyle? = nil) async {
        guard let r = await engine.record(id), r.kind == "element", !r.isDeleted else { return }
        var fields: [String: JSONValue] = [:]
        if let frame {
            fields[InkElement.Field.x] = .number(frame.x); fields[InkElement.Field.y] = .number(frame.y)
            fields[InkElement.Field.w] = .number(frame.width); fields[InkElement.Field.h] = .number(frame.height)
        }
        if let text { fields[InkElement.Field.text] = .string(text) }
        if let size { fields[InkElement.Field.size] = .number(size) }
        if let color { fields[InkElement.Field.color] = .string(color) }
        if let rotate, rotate.isFinite { fields[InkElement.Field.rotate] = .number(rotate) }
        if let flip, InkElement(r).kind == .image { fields[InkElement.Field.flip] = .bool(flip) }
        if let textStyle, InkElement(r).kind == .text { fields.merge(textStyle.fields(all: true)) { _, b in b } }
        guard !fields.isEmpty else { return }
        await engine.set(fields, record: id, kind: "element")
        if text != nil { await refreshSketchText(InkElement(r).on) }
    }

    /// Moves, resizes, turns or flips elements (the lasso): each moves by its centre and turns with
    /// the selection; a mirrored picture flips; text grows with the box (InkEditing.transform).
    public func transformElements(_ ids: [String], by transform: InkGeometry.Transform) async {
        guard transform.isUsable else { return }
        for id in ids {
            guard let r = await engine.record(id), r.kind == "element", !r.isDeleted else { continue }
            let e = InkElement(r)
            let next = InkEditing.transform(transform, e.editFrame, image: e.kind == .image)
            let size: Double? = e.kind == .text && transform.widthScale != 1 ? e.size * transform.widthScale : nil
            await updateElement(id, frame: next.rect, size: size, rotate: next.rotate != e.rotate ? next.rotate : nil, flip: next.flip != e.flip ? next.flip : nil)
        }
    }

    public func deleteElements(_ ids: [String]) async {
        var items: Set<String> = []
        for id in ids {
            if let r = await engine.record(id), r.kind == "element" { items.insert(InkElement(r).on) }
            await engine.delete(id)
        }
        for item in items { await refreshSketchText(item) }
    }

    /// The item's `sketchText`: every text box's words, for search.
    func refreshSketchText(_ itemId: String) async {
        let records = await engine.ink(on: itemId).filter { $0.kind == "element" }
        let boxes: [InkElement] = records.map(InkElement.init).filter { $0.on == itemId && $0.kind == .text }
        let words: [String] = boxes.sorted { $0.createdAt < $1.createdAt }.map(\.text).filter { !$0.isEmpty }
        let text = words.joined(separator: "\n")
        let current: String = await item(itemId)?.sketchText ?? ""
        guard current != text else { return }
        await update(itemId, [Item.SketchField.sketchText: .string(text)])
    }

    /// Handwriting an Apple device read off the pages (Vision), for search.
    public func setInkText(_ itemId: String, _ text: String) async {
        guard await item(itemId)?.inkText != text else { return }
        await update(itemId, [Item.SketchField.inkText: .string(text)])
    }

    // MARK: Undo

    /// Brings ink back (`alive`) or removes it, keeping the same ids: the drawing editor's undo and redo.
    public func setInk(_ ids: [(id: String, kind: String)], alive: Bool) async {
        var items: Set<String> = []
        for (id, kind) in ids where kind == "stroke" || kind == "element" {
            await engine.set(["_deleted": .bool(!alive)], record: id, kind: kind)
            if kind == "element", let r = await engine.record(id) { items.insert(InkElement(r).on) }
        }
        for item in items { await refreshSketchText(item) }
    }

    /// Some fields of an ink record, to put back on undo. A field it doesn't have comes back as its
    /// "off" value (no turn, no group, upright text…), so undo takes back a style that was added.
    public func inkFields(_ id: String, _ names: [String]) async -> [String: JSONValue] {
        guard let r = await engine.record(id) else { return [:] }
        var out: [String: JSONValue] = [:]
        for name in names {
            if let v = r[name] { out[name] = v }
            // Points not there are put back empty, so undo can't leave newer compact points in front.
            else if let off = Self.inkOffValues[name] { out[name] = off }
        }
        return out
    }

    static let inkOffValues: [String: JSONValue] = [
        InkStroke.Field.points: .string(""), InkStroke.Field.points2: .string(""), InkStroke.Field.group: .string(""),
        InkStroke.Field.shape: .null, InkStroke.Field.nib: .null, InkElement.Field.rotate: .number(0), InkElement.Field.flip: .bool(false),
        InkElement.Field.font: .string("sans"), InkElement.Field.bold: .bool(false), InkElement.Field.italic: .bool(false),
    ]

    public func setInkFields(_ id: String, kind: String, _ fields: [String: JSONValue]) async {
        guard kind == "stroke" || kind == "element", !fields.isEmpty else { return }
        await engine.set(fields, record: id, kind: kind)
        if kind == "element", fields[InkElement.Field.text] != nil, let r = await engine.record(id) { await refreshSketchText(InkElement(r).on) }
    }

    /// Everything drawn on a page, as a box in page points (the endless canvas, exports).
    public func inkBounds(on itemId: String, layer: String = "", pageKey: String) async -> InkGeometry.Rect? {
        var box: InkGeometry.Rect?
        for s in await strokes(on: itemId, layer: layer, pageKey: pageKey) { box = InkGeometry.union(box, InkGeometry.bounds(s.points, pad: s.width / 2)) }
        for e in await elements(on: itemId, layer: layer, pageKey: pageKey) { box = InkGeometry.union(box, e.frame) }
        return box
    }

    /// Changes whenever a sketch's ink does, so handwriting is read again only when needed.
    public func inkSignature(_ itemId: String) async -> String {
        let records = await engine.ink(on: itemId)
        let latest = records.map(\.updatedHLC).max() ?? ""
        return "\(records.count)-\(latest)"
    }

    // MARK: Pages

    private func setPages(_ id: String, _ pages: [InkPage]) async {
        await update(id, [Item.SketchField.pageList: .array(pages.map(\.json)), Item.SketchField.pages: .number(Double(pages.count))])
    }

    /// A new blank page after `after` (at the end when nil), with that page's paper and colour.
    @discardableResult
    public func addPage(to sketchId: String, after: String? = nil) async -> String? {
        guard let sketch = await item(sketchId) else { return nil }
        var pages = sketch.sketchPageList
        let index = after.flatMap { a in pages.firstIndex { $0.id == a } }.map { $0 + 1 } ?? pages.count
        let like = pages[max(0, min(pages.count - 1, index - 1))]
        let page = InkPage(id: String(newId().prefix(8)), paper: like.paper, color: like.color, size: like.size)
        pages.insert(page, at: index)
        await setPages(sketchId, pages)
        return page.id
    }

    /// A copy of a page and everything on it, right after it.
    @discardableResult
    public func duplicatePage(_ pageKey: String, of sketchId: String) async -> String? {
        guard let sketch = await item(sketchId), let index = sketch.sketchPageList.firstIndex(where: { $0.id == pageKey }) else { return nil }
        var pages = sketch.sketchPageList
        var copy = pages[index]
        copy.id = String(newId().prefix(8))
        pages.insert(copy, at: index + 1)
        await setPages(sketchId, pages)
        let strokes = await strokes(on: sketchId, pageKey: pageKey).map(\.id)
        let elements = await elements(on: sketchId, pageKey: pageKey).map(\.id)
        await duplicateInk(strokes: strokes, elements: elements, to: sketchId, pageKey: copy.id, by: InkGeometry.Transform())
        return copy.id
    }

    /// Moves a page to `index` in the order.
    public func movePage(_ pageKey: String, of sketchId: String, to index: Int) async {
        guard let sketch = await item(sketchId) else { return }
        var pages = sketch.sketchPageList
        guard let from = pages.firstIndex(where: { $0.id == pageKey }) else { return }
        let page = pages.remove(at: from)
        pages.insert(page, at: max(0, min(pages.count, index)))
        await setPages(sketchId, pages)
    }

    /// Deletes a page and what's on it. The last page can't go.
    public func deletePage(_ pageKey: String, of sketchId: String) async {
        guard let sketch = await item(sketchId), sketch.sketchPageList.count > 1 else { return }
        await setPages(sketchId, sketch.sketchPageList.filter { $0.id != pageKey })
        await deleteStrokes(await strokes(on: sketchId, pageKey: pageKey).map(\.id))
        await deleteElements(await elements(on: sketchId, pageKey: pageKey).map(\.id))
    }

    /// One page's paper or colour ("" colour = white).
    public func setPage(_ pageKey: String, of sketchId: String, paper: InkPaper? = nil, color: String? = nil, size: [Double]? = nil) async {
        guard let sketch = await item(sketchId) else { return }
        await setPages(sketchId, sketch.sketchPageList.map { page in
            guard page.id == pageKey else { return page }
            var p = page
            if let paper { p.paper = paper }
            if let color { p.color = color.isEmpty ? nil : color }
            if let size = InkPage.valid(size) { p.size = size }
            return p
        })
    }

    /// Every page's paper, colour or size at once, and the sketch's own paper and size (core/ink.js `setAllPages`).
    public func setAllPages(of sketchId: String, paper: InkPaper? = nil, color: String? = nil, size: [Double]? = nil) async {
        guard let sketch = await item(sketchId) else { return }
        let pages = sketch.sketchPageList.map { page in
            var p = page
            if let paper { p.paper = paper }
            if let color { p.color = color.isEmpty ? nil : color }
            if let size = InkPage.valid(size) { p.size = size }
            return p
        }
        var fields: [String: JSONValue] = [Item.SketchField.pageList: .array(pages.map(\.json)), Item.SketchField.pages: .number(Double(pages.count))]
        if let paper { fields[Item.SketchField.paper] = .string(paper.rawValue) }
        if let size = InkPage.valid(size) { fields[Item.SketchField.pageSize] = .array(size.map(JSONValue.number)) }
        await update(sketchId, fields)
    }

    /// Pages, or one endless canvas.
    public func setSketchCanvas(_ sketchId: String, infinite: Bool) async {
        await update(sketchId, [Item.SketchField.canvas: .string(infinite ? "infinite" : "pages")])
    }
}

extension Library {
    /// Hands a GoodNotes notebook's ink and typed text to Trove's editor: they become strokes and
    /// text boxes on the notebook's attachment (page n = the notebook's page n), and the item notes
    /// it in `goodnotesInk`, so viewers draw Trove's copy from then on and it's never imported twice
    /// (core/vault.js `importGoodNotesInk`). Returns how many were added.
    @discardableResult
    public func importGoodNotesInk(_ itemId: String, attachment attId: String, pages: [GoodNotesInk.EditablePage]) async -> Int {
        guard let item = await item(itemId), !item.goodnotesInk.contains(attId) else { return 0 }
        await engine.hold()
        var t = await nextInkTime(on: itemId), n = 0
        let device = await engine.device
        for (index, page) in pages.enumerated() {
            for s in page.strokes {
                if await addStroke(on: itemId, layer: attId, pageKey: String(index), tool: s.tool, color: s.color, width: s.width,
                                   points: s.points, shape: s.shape, createdAt: t) != nil { n += 1 }
                t += 1
            }
            for x in page.texts {
                await engine.set([
                    InkElement.Field.on: .string(itemId), InkElement.Field.layer: .string(attId), InkElement.Field.page: .string(String(index)),
                    InkElement.Field.type: .string(InkElement.Kind.text.rawValue), InkElement.Field.x: .number(x.x), InkElement.Field.y: .number(x.y),
                    InkElement.Field.w: .number(x.w), InkElement.Field.h: .number(x.h), InkElement.Field.text: .string(x.text),
                    InkElement.Field.size: .number(x.size), InkElement.Field.color: .string(x.color),
                    InkElement.Field.createdAt: .number(t), InkElement.Field.device: .string(device),
                ], record: newId(), kind: "element")
                t += 1
                n += 1
            }
        }
        await update(itemId, ["goodnotesInk": .array((item.goodnotesInk + [attId]).map(JSONValue.string))])
        await engine.release()
        return n
    }
}
