import Foundation

// PDFs like a PDF app (PROTOCOL.md §10 "PDF text, highlights and forms"): the text of a PDF for
// search, text highlights and form values saved as elements on the file's layer, and the mapping
// between PDF space and Trove's page points. web/public/core/pdfmarks.js does the same; both are
// checked against Fixtures/pdf-cases.json.

/// A PDF's text for search (`ocrText`), the same on every device.
public enum PDFText {
    /// 40 characters or fewer means "no text layer" (a scan): read the pages with OCR instead.
    public static let minimum = 40
    /// `ocrText` keeps at most this many characters (Unicode scalars).
    public static let maximum = 50_000
    /// A highlight's quote keeps at most this many characters.
    public static let quoteMaximum = 5_000

    /// The whitespace both sides fold: tab, line breaks, space, NEL, no-break and the Unicode spaces, BOM.
    static func isSpace(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, 0x85, 0xA0, 0x1680, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF: return true
        case 0x2000...0x200A: return true
        default: return false
        }
    }

    /// Runs of whitespace as one space, nothing at either end.
    static func collapse(_ scalars: [Unicode.Scalar]) -> String {
        var out = String.UnicodeScalarView()
        var pending = false
        for s in scalars {
            if isSpace(s) { pending = true; continue }
            if pending && !out.isEmpty { out.append(" ") }
            pending = false
            out.append(s)
        }
        return String(out)
    }

    /// A page's text tidied: line breaks as "\n", runs of spaces as one, lines trimmed, empty lines dropped.
    public static func normalizePage(_ text: String) -> String {
        var lines: [String] = []
        var line: [Unicode.Scalar] = []
        var afterCR = false
        for s in text.unicodeScalars {
            if s == "\n" && afterCR { afterCR = false; continue }
            afterCR = s == "\r"
            if s == "\n" || s == "\r" {
                lines.append(collapse(line))
                line = []
            } else {
                line.append(s)
            }
        }
        lines.append(collapse(line))
        return lines.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// `ocrText` from the pages' text: tidied pages, blank ones skipped, a blank line between pages.
    /// "" when 40 characters or fewer; at most 50,000.
    public static func join(_ pages: [String]) -> String {
        let text = pages.map(normalizePage).filter { !$0.isEmpty }.joined(separator: "\n\n")
        let count = text.unicodeScalars.count
        if count <= minimum { return "" }
        if count <= maximum { return text }
        var out = String.UnicodeScalarView()
        out.append(contentsOf: text.unicodeScalars.prefix(maximum))
        return String(out)
    }

    /// A highlight's quote: whitespace (line breaks too) as single spaces, trimmed, at most 5,000 characters.
    public static func cleanQuote(_ text: String) -> String {
        let s = collapse(Array(text.unicodeScalars))
        guard s.unicodeScalars.count > quoteMaximum else { return s }
        var out = String.UnicodeScalarView()
        out.append(contentsOf: s.unicodeScalars.prefix(quoteMaximum))
        return String(out)
    }
}

/// A text highlight's box and pieces (PROTOCOL.md §10).
public struct HighlightGeometry: Equatable, Sendable {
    /// The box round every piece, in page points (to 1/100 point).
    public var frame: InkGeometry.Rect
    /// Each piece as `[x, y, w, h]` fractions of `frame` (to 1/10,000).
    public var rects: [[Double]]

    public init(frame: InkGeometry.Rect, rects: [[Double]]) { self.frame = frame; self.rects = rects }

    static func round(_ v: Double, _ k: Double) -> Double { (v * k + 0.5).rounded(.down) / k }

    static func union(_ a: InkGeometry.Rect, _ b: InkGeometry.Rect) -> InkGeometry.Rect {
        let x = min(a.x, b.x), y = min(a.y, b.y)
        return InkGeometry.Rect(x: x, y: y, width: max(a.maxX, b.maxX) - x, height: max(a.maxY, b.maxY) - y)
    }

    private struct Line {
        var box: InkGeometry.Rect
        var order: Int
        var items: [(rect: InkGeometry.Rect, order: Int)]
    }

    /// From the selected text's boxes (page points): boxes on a line (overlapping by half the smaller
    /// height) join, pieces of a line closer than a line's height join. Nil when nothing is left.
    public static func make(_ boxes: [InkGeometry.Rect]) -> HighlightGeometry? {
        let usable = boxes.enumerated().filter { _, b in
            b.x.isFinite && b.y.isFinite && b.width.isFinite && b.height.isFinite && b.width >= 0.5 && b.height >= 0.5
        }
        let sorted = usable.sorted { a, b in
            let ca = a.element.y + a.element.height / 2, cb = b.element.y + b.element.height / 2
            if ca != cb { return ca < cb }
            if a.element.x != b.element.x { return a.element.x < b.element.x }
            return a.offset < b.offset
        }
        var lines: [Line] = []
        for (n, entry) in sorted.enumerated() {
            let b = entry.element
            var joined = false
            for i in lines.indices {
                let l = lines[i].box
                let overlap = min(l.maxY, b.maxY) - max(l.y, b.y)
                if overlap >= 0.5 * min(l.height, b.height) {
                    lines[i].items.append((b, n))
                    lines[i].box = union(l, b)
                    joined = true
                    break
                }
            }
            if !joined { lines.append(Line(box: b, order: lines.count, items: [(b, n)])) }
        }
        lines.sort { a, b in
            if a.box.y != b.box.y { return a.box.y < b.box.y }
            if a.box.x != b.box.x { return a.box.x < b.box.x }
            return a.order < b.order
        }
        var pieces: [InkGeometry.Rect] = []
        for line in lines {
            let items = line.items.sorted { a, b in a.rect.x != b.rect.x ? a.rect.x < b.rect.x : a.order < b.order }.map(\.rect)
            var current = items[0]
            for b in items.dropFirst() {
                if b.x - current.maxX <= max(current.height, b.height) {
                    current = union(current, b)
                } else {
                    pieces.append(current)
                    current = b
                }
            }
            pieces.append(current)
        }
        guard var box = pieces.first else { return nil }
        for p in pieces { box = union(box, p) }
        let x = round(box.x, 100), y = round(box.y, 100)
        let w = max(0.01, round(box.width, 100)), h = max(0.01, round(box.height, 100))
        let rects: [[Double]] = pieces.map { p in
            [round((p.x - x) / w, 1e4), round((p.y - y) / h, 1e4), round(p.width / w, 1e4), round(p.height / h, 1e4)]
        }
        return HighlightGeometry(frame: InkGeometry.Rect(x: x, y: y, width: w, height: h), rects: rects)
    }

    /// The pieces in page points (the whole box when there are none).
    public static func pieces(frame: InkGeometry.Rect, rects: [[Double]]?) -> [InkGeometry.Rect] {
        let usable = (rects ?? []).filter { $0.count == 4 && $0.allSatisfy(\.isFinite) }
        if usable.isEmpty { return [frame] }
        return usable.map { r in
            InkGeometry.Rect(x: frame.x + r[0] * frame.width, y: frame.y + r[1] * frame.height,
                             width: r[2] * frame.width, height: r[3] * frame.height)
        }
    }
}

/// A PDF page's box: its crop box `[x1, y1, x2, y2]` turned by `/Rotate`. Page points have the
/// origin top left, y down, as pdf.js shows a page at scale 1 and the apps draw it.
public struct PDFPageBox: Equatable, Sendable {
    public let x1, y1, x2, y2: Double
    /// 0, 90, 180 or 270.
    public let rotate: Int

    public init(view: [Double], rotate: Int = 0) {
        let a = view.count == 4 ? view : [0, 0, 0, 0]
        x1 = min(a[0], a[2]); y1 = min(a[1], a[3]); x2 = max(a[0], a[2]); y2 = max(a[1], a[3])
        let quarter = Int((Double(rotate) / 90 + 0.5).rounded(.down))
        self.rotate = ((quarter * 90) % 360 + 360) % 360
    }

    var turned: Bool { rotate == 90 || rotate == 270 }
    public var width: Double { turned ? y2 - y1 : x2 - x1 }
    public var height: Double { turned ? x2 - x1 : y2 - y1 }

    /// PDF space → page points.
    public func toPage(_ x: Double, _ y: Double) -> (x: Double, y: Double) {
        switch rotate {
        case 90: return (y - y1, x - x1)
        case 180: return (x2 - x, y - y1)
        case 270: return (y2 - y, x2 - x)
        default: return (x - x1, y2 - y)
        }
    }

    /// Page points → PDF space.
    public func toPDF(_ x: Double, _ y: Double) -> (x: Double, y: Double) {
        switch rotate {
        case 90: return (x1 + y, y1 + x)
        case 180: return (x2 - x, y1 + y)
        case 270: return (x2 - y, y2 - x)
        default: return (x1 + x, y2 - y)
        }
    }
}

public enum PDFForm {
    /// One record per field (item, file, field name), so two devices filling it write the same one.
    public static func elementId(item: String, layer: String, name: String) -> String { "pdffield:\(item):\(layer):\(name)" }

    /// A field value as stored: text, true/false, or a list of strings. Nil for anything else.
    public static func value(_ v: JSONValue?) -> JSONValue? {
        guard let v else { return nil }
        switch v {
        case .string, .bool: return v
        case .array(let a): return a.allSatisfy { $0.string != nil } ? v : nil
        default: return nil
        }
    }
}

public extension InkElement {
    /// A highlight's text.
    var quote: String { record[Field.quote]?.string ?? "" }
    /// A highlight's pieces as fractions of its box.
    var rects: [[Double]]? {
        guard let list = record[Field.rects]?.array else { return nil }
        return list.compactMap { r in r.array.map { $0.compactMap(\.number) } }
    }
    /// A highlight's pieces in page points.
    var highlightPieces: [InkGeometry.Rect] { HighlightGeometry.pieces(frame: frame, rects: rects) }
    /// A form value's field name.
    var fieldName: String { record[Field.name]?.string ?? "" }
    /// A form value: text, true/false or a list of strings.
    var fieldValue: JSONValue? { PDFForm.value(record[Field.value]) }
}

extension Library {
    // MARK: PDFs: highlights, form values, quotes and text

    /// Highlights text on a PDF page. `boxes`: the selected text's boxes in page points.
    @discardableResult
    public func addHighlight(on itemId: String, layer: String, pageKey: String, boxes: [InkGeometry.Rect], quote: String,
                             color: String = "#ffd60a") async -> String? {
        guard let g = HighlightGeometry.make(boxes) else { return nil }
        let rects = JSONValue.array(g.rects.map { r in JSONValue.array(r.map { JSONValue.number($0) }) })
        let extra: [String: JSONValue] = [InkElement.Field.rects: rects, InkElement.Field.quote: .string(PDFText.cleanQuote(quote))]
        return await addElement(on: itemId, layer: layer, pageKey: pageKey, kind: .highlight, frame: g.frame, color: color, extra: extra)
    }

    /// Saved form values on a file, by field name.
    public func pdfFields(on itemId: String, layer: String) async -> [String: InkElement] {
        var out: [String: InkElement] = [:]
        for e in await elements(on: itemId, layer: layer) where e.kind == .field && !e.fieldName.isEmpty && e.fieldValue != nil {
            out[e.fieldName] = e
        }
        return out
    }

    /// Saves a form field's value; the file never changes. `pageKey` and `frame`: the widget showing it.
    @discardableResult
    public func setPDFField(on itemId: String, layer: String, pageKey: String, name: String, value: JSONValue,
                            frame: InkGeometry.Rect) async -> String? {
        guard let v = PDFForm.value(value), !name.isEmpty else { return nil }
        let id = PDFForm.elementId(item: itemId, layer: layer, name: name)
        let existing = await engine.record(id)
        let live = existing.map { !$0.isDeleted } ?? false
        if live, let r = existing, r[InkElement.Field.value] == v, InkPage.key(r[InkElement.Field.page]) == pageKey { return id }
        var fields: [String: JSONValue] = [
            InkElement.Field.on: .string(itemId), InkElement.Field.layer: .string(layer), InkElement.Field.page: .string(pageKey),
            InkElement.Field.type: .string(InkElement.Kind.field.rawValue), InkElement.Field.name: .string(name), InkElement.Field.value: v,
            InkElement.Field.x: .number(frame.x), InkElement.Field.y: .number(frame.y),
            InkElement.Field.w: .number(frame.width), InkElement.Field.h: .number(frame.height), InkElement.Field.device: .string(await engine.device),
        ]
        if !live {
            fields[InkElement.Field.createdAt] = .number(await nextInkTime(on: itemId))
            fields["_deleted"] = .bool(false)
        }
        await engine.set(fields, record: id, kind: "element")
        return id
    }

    /// A quote item (Quotes & Highlights) from highlighted text, connected to the item it came from.
    @discardableResult
    public func addQuote(_ text: String, from sourceId: String?, page: Int? = nil) async -> String? {
        let quote = PDFText.cleanQuote(text)
        guard !quote.isEmpty else { return nil }
        var title = ""
        var links: [String] = []
        if let sourceId, let source = await item(sourceId) {
            title = source.displayTitle
            links = [source.id]
        }
        let ref = page.map { " (p. \($0 + 1))" } ?? ""
        let body = "> " + quote + "\n\n— " + (title.isEmpty ? "PDF" : title) + ref
        let id = newId()
        var fields = await baseFields(kind: .highlight, source: .app, title: title)
        fields[Field.category] = .string(ItemCategory.quote.rawValue)
        let place = await filing(kind: .highlight, category: .quote, source: .app, collection: title.isEmpty ? nil : title)
        fields.merge(place) { _, b in b }
        if !links.isEmpty { fields[Field.links] = JSONValue(links) }
        await engine.set(fields, record: id, kind: "item")
        await engine.editText(Field.body, value: body, record: id, kind: "item")
        return id
    }

    /// A PDF's text for search (`ocrText`, `PDFText.join`).
    public func setPDFText(_ itemId: String, _ text: String) async {
        guard !text.isEmpty, let current = await item(itemId), current.ocrText != text else { return }
        await update(itemId, [Field.ocrText: .string(text)])
    }
}
