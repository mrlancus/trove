import Foundation

/// Reads the handwriting inside a GoodNotes 5/6 notebook (.goodnotes) so the apps can show it
/// without GoodNotes. The website does the same in web/public/core/goodnotes.js; both are checked
/// against Fixtures/ink.goodnotes (made by web/test/make-goodnotes-fixture.mjs).
///
/// The format is undocumented. What's here follows the MIT-licensed "Document Parser for GoodNotes"
/// project (github.com/Kaih1825/parser-for-goodnotes):
/// - the file is a zip: `notes/<page>` (length-prefixed protobuf records), `index.notes.pb` (pages),
///   `index.events.pb` (page order, templates, deleted pages), `index.attachments.pb` (attachment
///   ids → files) and `attachments/<id>` (PDFs and images);
/// - a stroke is a protobuf field holding Apple LZ4 ("bv41"…"bv4$") around a TPL image (Troy
///   Hanson's tpl format) with the points, followed by protobuf fields with the colour and any
///   move offset;
/// - coordinates are at 132 dots per inch; `scale` turns them into PDF points.
public enum GoodNotesInk {
    public static let scale = 72.0 / 132.0

    public struct Notebook: Sendable {
        public var pages: [Page]
        public var attachments: [String: Attachment]
    }

    public struct Attachment: Sendable {
        public var path: String
        public var data: Data
        public var mime: String
    }

    public struct Background: Sendable, Equatable, Codable {
        public var attachment: String
        public var page: Int
    }

    public struct Page: Sendable {
        public var id: String
        /// In points, from the background PDF (612 × 792 when there isn't one).
        public var width: Double
        public var height: Double
        public var background: Background?
        /// Everything on the page in drawing order.
        public var layers: [Layer]
        /// Ink found on the page that couldn't be read (a layout not known yet).
        public var unread = 0

        public var strokes: [Stroke] { layers.compactMap { if case .ink(let s) = $0 { s } else { nil } } }
        public var texts: [TextBox] { layers.compactMap { if case .text(let t) = $0 { t } else { nil } } }
        /// The typed words on the page, for search.
        public var text: String { texts.map { $0.runs.map(\.text).joined() }.joined(separator: "\n") }
    }

    public enum Layer: Sendable {
        case ink(Stroke)
        case text(TextBox)
        case image(Picture)
    }

    public struct Point: Sendable, Equatable {
        public var x: Double, y: Double, r: Double
    }

    public struct Stroke: Sendable {
        public var id: String?
        public var rgb: [Double]
        public var alpha: Double
        /// The pen's nominal width, in GoodNotes units.
        public var width: Double
        /// Pen-down runs of points; `r` is the half-width at that point.
        public var runs: [[Point]]
        public var isShape = false
        public var isPencil = false
        /// A shape's fill (one closed run), drawn with `alpha`.
        public var isFill = false

        public var isHighlighter: Bool { alpha < 0.95 }
        /// GoodNotes' pencil is grainy and light.
        public var opacity: Double { isPencil ? min(alpha, 0.5) : alpha }
        /// The line width to draw, in GoodNotes units.
        public var lineWidth: Double {
            if isShape { return max(0.5, width) }
            if isPencil { return max(0.5, width * 0.45) }
            let radii = runs.joined().map(\.r).sorted()
            let median = radii.isEmpty ? width / 2 : radii[radii.count / 2]
            return max(0.5, median * 2)
        }
    }

    public struct TextRun: Sendable, Equatable {
        public var text: String
        public var size: Double
        public var rgb: [Double]
        public var bold: Bool
        public var italic: Bool
    }

    public struct TextBox: Sendable {
        public var id: String?
        public var x: Double, y: Double, w: Double, h: Double
        public var runs: [TextRun]
    }

    public struct Picture: Sendable {
        public var attachment: String
        public var x: Double, y: Double, w: Double, h: Double
    }

    public enum Failure: Error { case notANotebook }

    // MARK: - Reading a notebook

    public static func read(_ data: Data) throws -> Notebook {
        guard let zip = try? ZipArchive(data) else { throw Failure.notANotebook }
        func entry(_ path: String) -> ZipArchive.Entry? { zip.entries.first { $0.path == path } }
        func member(_ path: String) -> [UInt8]? { entry(path).flatMap { try? zip.data(for: $0) }.map { [UInt8]($0) } }

        // Attachments: id → file, in the order they're listed.
        var attachments: [String: Attachment] = [:]
        var order: [String] = []
        for r in records(member("index.attachments.pb") ?? []) {
            var id: String?, path: String?
            for f in r { if let s = f.text { if s.hasPrefix("attachments/") { path = s } else if isUUID(s) { id = s } } }
            if let id, let path, entry(path) != nil, attachments[id] == nil {
                attachments[id] = Attachment(path: path, data: Data(), mime: "")
                order.append(id)
            }
        }
        for e in zip.entries where e.path.hasPrefix("attachments/") && !e.isDirectory && !attachments.values.contains(where: { $0.path == e.path }) {
            let id = String(e.path.dropFirst("attachments/".count))
            attachments[id] = Attachment(path: e.path, data: Data(), mime: "")
            order.append(id)
        }
        for id in order {
            let bytes = (entry(attachments[id]!.path).flatMap { try? zip.data(for: $0) }) ?? Data()
            attachments[id]?.data = bytes
            attachments[id]?.mime = FilePreview.sniff(bytes) ?? "application/octet-stream"
        }

        // Events: deleted pages, page order, templates (backgrounds).
        var deleted: Set<String> = [], orderKeys: [String: (ts: UInt64, key: String)] = [:]
        var templates: [String: Background] = [:], pageTemplate: [String: String] = [:], direct: [String: String] = [:]
        for r in records(member("index.events.pb") ?? []) {
            let ts = r.first { $0.n == 14 && $0.wt == 0 }?.int ?? 0
            for f in r {
                guard let m = f.message else { continue }
                if f.n == 56, let id = m.uuid(2) { deleted.insert(pageKey(id)) }
                if f.n == 54 || f.n == 55, let id = m.uuid(2), let key = m.message(f.n == 54 ? 4 : 3)?.string(1) {
                    if let prior = orderKeys[pageKey(id)], ts < prior.ts { } else { orderKeys[pageKey(id)] = (ts, key) }
                }
                if f.n == 2, let t = m.string(2), let a = m.string(4), !t.isEmpty, !a.isEmpty {
                    let page = m.first { $0.n == 5 && $0.wt == 0 }.map { Int($0.int) } ?? 1
                    templates[t] = Background(attachment: a, page: page)
                }
                if f.n == 54 || f.n == 3, let id = m.uuid(2), let t = m.message(3)?.string(1), !t.isEmpty { pageTemplate[pageKey(id)] = t }
            }
            var page: String?, att: String?
            for f in r { if let s = f.text, isUUID(s) { if attachments[s] != nil { att = s } else { page = s } } }
            if let page, let att { direct[pageKey(page)] = att }
        }

        // Pages, in GoodNotes' order.
        var list: [(id: String, path: String)] = []
        for r in records(member("index.notes.pb") ?? []) {
            var id: String?, path: String?
            for f in r { if let s = f.text { if s.hasPrefix("notes/") { path = s } else if isUUID(s) { id = s } } }
            if let path, entry(path) != nil {
                let pageId = id ?? String(path.dropFirst(6))
                if !deleted.contains(pageKey(pageId)) { list.append((id: pageId, path: path)) }
            }
        }
        if list.isEmpty {
            list = zip.entries.filter { $0.path.hasPrefix("notes/") && !$0.isDirectory }.map { (id: String($0.path.dropFirst(6)), path: $0.path) }
                .sorted { $0.path.utf16.lexicographicallyPrecedes($1.path.utf16) }
        }
        if !orderKeys.isEmpty {
            list = list.enumerated().sorted { a, b in
                let ka = orderKeys[pageKey(a.element.id)], kb = orderKeys[pageKey(b.element.id)]
                if let ka, let kb, ka.key != kb.key { return ka.key.utf16.lexicographicallyPrecedes(kb.key.utf16) }
                if (ka == nil) != (kb == nil) { return ka != nil }
                return a.offset < b.offset
            }.map(\.element)
        }
        // A whiteboard is one page, and its ink can be spread over more members than the index lists.
        var extra: [String] = []
        if list.count == 1 {
            let listed = Set(list.map(\.path))
            extra = zip.entries.filter { $0.path.hasPrefix("notes/") && !$0.isDirectory && !listed.contains($0.path) && !deleted.contains(pageKey(String($0.path.dropFirst(6)))) }
                .map(\.path)
        }
        let pdfs = order.enumerated().filter { attachments[$0.element]?.mime == "application/pdf" }
            .sorted { a, b in
                let sa = attachments[a.element]!.data.count, sb = attachments[b.element]!.data.count
                return sa != sb ? sa > sb : a.offset < b.offset
            }.map(\.element)

        var pages: [Page] = []
        var sizes: [String: (width: Double, height: Double)?] = [:]
        for (index, p) in list.enumerated() {
            var recs = records(member(p.path) ?? [])
            if index == 0 { for path in extra { recs += records(member(path) ?? []) } }
            var background: Background?
            if let att = direct[pageKey(p.id)] {
                background = Background(attachment: att, page: 1)
            } else if let t = pageTemplate[pageKey(p.id)].flatMap({ templates[$0] }), attachments[t.attachment] != nil {
                background = t
            } else if !pdfs.isEmpty {
                background = Background(attachment: pdfs[min(index, pdfs.count - 1)], page: index + 1)
            }
            var size = (width: 612.0, height: 792.0)
            if let id = background?.attachment, let bg = attachments[id], bg.mime == "application/pdf" {
                if sizes[id] == nil { sizes[id] = .some(pdfSize(bg.data)) }
                if let s = sizes[id] ?? nil { size = s }
            }
            let found = content(recs, attachmentIds: Set(attachments.keys))
            var page = Page(id: p.id, width: size.width, height: size.height, background: background, layers: found.layers, unread: found.unread)
            if background == nil || max(page.width, page.height) > oversized { page = fitToContent(page) }
            pages.append(page)
        }
        return Notebook(pages: pages, attachments: attachments)
    }

    /// Pages bigger than this (points) are a whiteboard's endless canvas, not paper.
    public static let oversized = 2000.0

    /// A GoodNotes whiteboard is an endless canvas, often drawn far from 0, 0, sometimes with a huge
    /// blank PDF behind it. A page with no background whose drawing runs off it, or any oversized page,
    /// becomes the size of what's on it plus a margin, moved so it all shows; an oversized page loses
    /// its (blank) background. Ordinary pages that fit are left alone (core/goodnotes.js `fitToContent`).
    public static func fitToContent(_ page: Page, margin: Double = 36) -> Page {
        var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity
        func add(_ x: Double, _ y: Double) { minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y) }
        for layer in page.layers {
            switch layer {
            case .ink(let s): for p in s.runs.joined() where p.x.isFinite && p.y.isFinite { add(p.x - p.r, p.y - p.r); add(p.x + p.r, p.y + p.r) }
            case .text(let t): add(t.x, t.y); add(t.x + t.w, t.y + t.h)
            case .image(let i): add(i.x, i.y); add(i.x + i.w, i.y + i.h)
            }
        }
        let huge = max(page.width, page.height) > oversized
        guard minX.isFinite else {
            if !huge { return page }
            var out = page
            (out.width, out.height, out.background) = (612, 792, nil)
            return out
        }
        // In points from here (layers are in GoodNotes units).
        let x0 = minX * scale, y0 = minY * scale, x1 = maxX * scale, y1 = maxY * scale
        if !huge, x0 >= 0, y0 >= 0, x1 <= page.width, y1 <= page.height { return page }
        let dx = (margin - x0) / scale, dy = (margin - y0) / scale
        var out = page
        if huge { out.background = nil }
        out.width = max(200, x1 - x0 + 2 * margin)
        out.height = max(200, y1 - y0 + 2 * margin)
        out.layers = page.layers.map { layer in
            switch layer {
            case .ink(var s):
                s.runs = s.runs.map { $0.map { Point(x: $0.x + dx, y: $0.y + dy, r: $0.r) } }
                return .ink(s)
            case .text(var t): t.x += dx; t.y += dy; return .text(t)
            case .image(var i): i.x += dx; i.y += dy; return .image(i)
            }
        }
        return out
    }

    /// Strokes, shapes, text boxes and images on one page, in drawing order. Erased things (field
    /// 3 = 1 on their element) are skipped.
    static func content(_ recs: [Message], attachmentIds: Set<String>) -> (layers: [Layer], unread: Int) {
        var erased: Set<String> = [], seen: Set<String> = []
        for r in recs where r.varint(3) == 1 { if let id = r.uuid(1) { erased.insert(id) } }
        var layers: [Layer] = []
        var unread = 0
        func take(_ v: ArraySlice<UInt8>) {
            guard find(bv41, in: v) != nil else { return }
            for part in strokeParts(v) {
                guard let s = stroke(part) else {
                    // Not a stroke we can read (text boxes hold LZ4 too, but never a TPL image).
                    if looksLikeInk(part) { unread += 1 }
                    continue
                }
                if let id = s.id { guard !seen.contains(id), !erased.contains(id) else { continue }; seen.insert(id) }
                layers.append(.ink(s))
            }
        }
        for (i, r) in recs.enumerated() {
            for f in r { if let b = f.bytes { take(b) } }
            if let f7 = r.bytes(7), find(bv41, in: f7) == nil, let sub = try? decodeMessage(f7) {
                for f in sub { if let b = f.bytes { take(b) } }
            }
            let text = textBox(r)
            if let text, !(text.id.map { erased.contains($0) } ?? false) { layers.append(.text(text)) }
            let outline = text == nil ? shape(r) : nil
            if let outline, !(outline.id.map { erased.contains($0) } ?? false) { layers.append(.ink(outline)) }
            if text == nil, outline == nil, let f = fill(r), !(f.stroke.id.map { erased.contains($0) } ?? false), !(f.of.map { erased.contains($0) } ?? false) {
                layers.append(.ink(f.stroke))
            }
            if let att = r.uuid(7) ?? r.uuid(4), attachmentIds.contains(att), r.varint(3) != 1,
               let box = imageBox(r) ?? (i + 1 < recs.count ? imageBox(recs[i + 1]) : nil) {
                layers.append(.image(Picture(attachment: att, x: box.x, y: box.y, w: box.w, h: box.h)))
            }
        }
        return (layers, unread)
    }

    /// The stroke payloads in a field. Usually the field is one stroke; grouped ink (whiteboards,
    /// things moved together) nests several, each starting `\n$<uuid>` with its own LZ4 before the next.
    static func strokeParts(_ v: ArraySlice<UInt8>) -> [ArraySlice<UInt8>] {
        var heads: [Int] = []
        var i = v.startIndex
        while i + 38 <= v.endIndex {
            if v[i] == 0x0A, v[i + 1] == 0x24, isUUIDBytes(v, at: i + 2) { heads.append(i) }
            i += 1
        }
        let good = heads.enumerated().filter { k, p in
            let next = k + 1 < heads.count ? heads[k + 1] : v.endIndex
            return find(bv41, in: v[p..<next]) != nil
        }.map(\.element)
        guard good.count >= 2 else { return [v] }
        return good.enumerated().map { k, p in v[p..<(k + 1 < good.count ? good[k + 1] : v.endIndex)] }
    }

    static func isUUIDBytes(_ b: ArraySlice<UInt8>, at i: Int) -> Bool {
        guard i + 36 <= b.endIndex else { return false }
        for k in 0..<36 {
            let c = b[i + k]
            if k == 8 || k == 13 || k == 18 || k == 23 { if c != 0x2D { return false } }
            else if !((c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x46) || (c >= 0x61 && c <= 0x66)) { return false }
        }
        return true
    }

    /// Whether a payload's LZ4 holds a TPL image with points in it (ink). A shape's is empty.
    static func looksLikeInk(_ v: ArraySlice<UInt8>) -> Bool {
        guard let start = find(bv41, in: v) else { return false }
        guard let unpacked = try? appleLZ4(v[start...]) else { return true }
        guard unpacked.0.first == 0x74, let tpl = try? decodeTPL(unpacked.0) else { return false }
        return tpl.values.contains { ($0.list?.count ?? 0) > 1 }
    }

    // MARK: - Strokes

    static let bv41: [UInt8] = Array("bv41".utf8)

    /// A stroke payload (`\n$<uuid>…bv41…bv4$<trailer>`).
    static func stroke(_ v: ArraySlice<UInt8>) -> Stroke? {
        guard let start = find(bv41, in: v), let unpacked = try? appleLZ4(v[start...]), unpacked.0.first == 0x74,
              let tpl = try? decodeTPL(unpacked.0) else { return nil }
        let used = unpacked.1
        let found = points(tpl)
        var runs = found.0
        let width = found.1
        guard !runs.isEmpty else { return nil }
        let style = trailerStyle(v[(start + used)...])
        if style.dx != 0 || style.dy != 0 {
            runs = runs.map { $0.map { Point(x: $0.x + style.dx, y: $0.y + style.dy, r: $0.r) } }
        }
        var id: String?
        let b = v.startIndex
        if v.count >= 38, v[b] == 0x0A, v[b + 1] == 0x24 { id = String(decoding: v[(b + 2)..<(b + 38)], as: UTF8.self) }
        return Stroke(id: id, rgb: style.rgb, alpha: style.alpha, width: width, runs: runs, isPencil: tpl.format.contains("A(S(uuuuuuuuuuu"))
    }

    /// Point runs from a stroke's TPL values, and its nominal width.
    static func points(_ tpl: TPLImage) -> ([[Point]], Double) {
        let values = tpl.values, format = tpl.format
        func at(_ i: Int) -> TPLValue? { i < values.count ? values[i] : nil }
        let w = at(1).flatMap { if case .num(let n) = $0, n > 1000 { Double(f32(n)) } else { nil } } ?? 0
        let nominal = w >= 0.05 && w <= 100 ? w : 1
        var runs: [[Point]] = [], run: [Point] = []
        func add(_ x: Double, _ y: Double, _ r: Double) {
            // Whiteboards are endless: ink can sit far from 0, 0.
            guard x.isFinite, y.isFinite, abs(x) <= 1_000_000, abs(y) <= 1_000_000 else { return }
            if let last = run.last, hypot(x - last.x, y - last.y) < 1e-3 { return }
            run.append(Point(x: x, y: y, r: r.isFinite && r >= 0.001 && r <= 100 ? r : nominal / 2))
        }
        func cut() { if !run.isEmpty { runs.append(run) }; run = [] }
        func words(_ v: TPLValue) -> [Int64] { if case .tuple(let t) = v { t.compactMap(\.number) } else { [] } }

        if format.contains("A(S(uuuuuuuuuuu") {
            // Pencil: a start (x, y, ?, ?, r) and 11-word segments (?, x1, y1, ?, ?, r1, x2, y2, ?, ?, r2).
            for p in at(3)?.list ?? [] { let p = words(p); if p.count >= 5 { add(d(p[0]), d(p[1]), d(p[4])) } }
            for s in at(4)?.list ?? [] {
                let s = words(s)
                if s.count >= 11 { add(d(s[1]), d(s[2]), d(s[5])); add(d(s[6]), d(s[7]), d(s[10])) }
            }
        } else if format.contains("A(S(uuuu))") {
            // Pens and highlighters: a start (x, y) and segments of two points; a 0 in values[2] lifts the pen.
            let rawFlags = at(2)?.list?.compactMap(\.number) ?? []
            let flags = rawFlags.allSatisfy { $0 == 0 || $0 == 1 } ? rawFlags : []
            for p in at(3)?.list ?? [] { let p = words(p); if p.count >= 2 { add(d(p[0]), d(p[1]), nominal / 2) } }
            for (i, q) in (at(4)?.list ?? []).enumerated() {
                let q = words(q)
                guard q.count >= 4 else { continue }
                if i + 1 < flags.count, flags[i + 1] == 0 { cut() }
                add(d(q[0]), d(q[1]), nominal / 2)
                add(d(q[2]), d(q[3]), nominal / 2)
            }
        } else {
            // GoodNotes 6: flat word arrays after the flags. The first holds the start point
            // (x, y, r[, 0]), the second the rest as (x, y, r), with (0, 0, r) markers, skipped.
            // The first two plain number arrays (A(u) float bits, or A(f) doubles) wherever they are:
            // newer GoodNotes versions add fields in front.
            let nodes = (try? parseFormat(format)) ?? []
            let arrays = nodes.enumerated().compactMap { i, node -> Int? in
                if case .array(let c) = node, c.count == 1, case .scalar(let ch) = c[0], ch == "u" || ch == "f" { return i }
                return nil
            }
            let first = arrays.first ?? (format.hasPrefix("vu") ? 3 : 2)
            let second = arrays.count > 1 ? arrays[1] : first + 1
            func triples(_ index: Int, max: Int = .max) -> [Point] {
                guard let list = at(index)?.list, !list.isEmpty else { return [] }
                let n: [Double] = list.compactMap { v in
                    switch v {
                    case .num(let w): d(w)
                    case .double(let x): x
                    default: nil
                    }
                }
                var out: [Point] = []
                var i = 0
                while i + 2 < n.count, out.count < max {
                    let x = n[i], y = n[i + 1]
                    if !(abs(x) < 10 && abs(y) < 10) { out.append(Point(x: x, y: y, r: n[i + 2])) }
                    i += 3
                }
                return out
            }
            for p in triples(first, max: 1) + triples(second) { add(p.x, p.y, p.r) }
        }
        cut()
        return (runs, nominal)
    }

    struct Style { var rgb: [Double] = [0, 0, 0], alpha = 1.0, dx = 0.0, dy = 0.0 }

    /// Colour, opacity and move offset from the protobuf after the ink.
    static func trailerStyle(_ b: ArraySlice<UInt8>) -> Style {
        let msg = decodeMessage(b, lenient: true)
        var style = Style()
        if let colour = msg.message(4) {
            func channel(_ n: Int, _ fallback: Double) -> Double {
                guard let v = colour.float(n), v.isFinite else { return fallback }
                return min(1, max(0, v))
            }
            style.rgb = [channel(1, 0), channel(2, 0), channel(3, 0)]
            style.alpha = channel(4, 1)
        }
        if let offset = msg.message(6) { style.dx = offset.float(1) ?? 0; style.dy = offset.float(2) ?? 0 }
        return style
    }

    // MARK: - Shapes

    /// The first two fixed32 floats of a message (by field number), looking one level down if needed.
    static func pointOf(_ msg: Message) -> (Double, Double)? {
        let direct = msg.filter { $0.wt == 5 }.sorted { $0.n < $1.n }
        if direct.count >= 2 { return (d32(direct[0].int), d32(direct[1].int)) }
        for f in msg.sorted(by: { $0.n < $1.n }) {
            let pts = f.message?.filter { $0.wt == 5 }.sorted { $0.n < $1.n } ?? []
            if pts.count >= 2 { return (d32(pts[0].int), d32(pts[1].int)) }
        }
        return nil
    }

    static func bezier(_ p0: (Double, Double), _ cs: [(Double, Double)], into out: inout [(Double, Double)]) {
        for j in 1...24 {
            let t = Double(j) / 24, u = 1 - t
            if cs.count == 2 {
                out.append((u * u * p0.0 + 2 * u * t * cs[0].0 + t * t * cs[1].0, u * u * p0.1 + 2 * u * t * cs[0].1 + t * t * cs[1].1))
            } else {
                out.append((pow(u, 3) * p0.0 + 3 * u * u * t * cs[0].0 + 3 * u * t * t * cs[1].0 + pow(t, 3) * cs[2].0,
                            pow(u, 3) * p0.1 + 3 * u * u * t * cs[0].1 + 3 * u * t * t * cs[1].1 + pow(t, 3) * cs[2].1))
            }
        }
    }

    /// A path container: line points, with commands 3 (quadratic) and 4 (cubic) flattened.
    static func pathPoints(_ container: Message) -> [(Double, Double)] {
        var cmds: [(Int, (Double, Double))] = []
        for f in container {
            guard let item = f.message, let head = item.first, let pt = pointOf(item) else { continue }
            cmds.append((head.n >= 1 && head.n <= 5 ? head.n : f.n, pt))
        }
        var pts: [(Double, Double)] = []
        var i = 0
        while i < cmds.count {
            let (cmd, pt) = cmds[i]
            if cmd == 3, i + 1 < cmds.count { bezier(pts.last ?? pt, [pt, cmds[i + 1].1], into: &pts); i += 2 }
            else if cmd == 4, i + 2 < cmds.count { bezier(pts.last ?? pt, [pt, cmds[i + 1].1, cmds[i + 2].1], into: &pts); i += 3 }
            else { pts.append(pt); i += 1 }
        }
        return pts
    }

    /// A shape record (field 7 → {4: colour, 9: geometry, 14/6: move}).
    static func shape(_ rec: Message) -> Stroke? {
        guard let outer = rec.message(7), let geo = outer.message(9) else { return nil }
        let pts = geometryPoints(geo)
        guard pts.count >= 2 else { return nil }
        let (dx, dy) = moveOf(outer, rec)
        let width = geo.float(15) ?? 1
        var rgb = [0.0, 0, 0], alpha = 1.0
        if let colour = outer.message(4) {
            rgb = [1, 2, 3].map { min(1, max(0, colour.float($0) ?? 0)) }
            alpha = colour.float(4) ?? 1
        }
        return Stroke(id: outer.uuid(1), rgb: rgb, alpha: alpha, width: width,
                      runs: [pts.map { Point(x: $0.0 + dx, y: $0.1 + dy, r: width / 2) }], isShape: true)
    }

    /// A shape's fill (field 9 → {1: id, 4: geometry, 5: the shape it fills, 7: colour}), drawn
    /// under its outline as one closed run.
    static func fill(_ rec: Message) -> (stroke: Stroke, of: String?)? {
        guard let outer = rec.message(9), let geo = outer.message(4), let colour = outer.message(7) else { return nil }
        let pts = geometryPoints(geo)
        guard pts.count >= 3 else { return nil }
        let (dx, dy) = moveOf(outer, rec)
        let rgb = [1, 2, 3].map { min(1, max(0, colour.float($0) ?? 0)) }
        let alpha = min(1, max(0, colour.float(4) ?? 1))
        let s = Stroke(id: outer.uuid(1), rgb: rgb, alpha: alpha, width: 0, runs: [pts.map { Point(x: $0.0 + dx, y: $0.1 + dy, r: 0) }],
                       isShape: true, isFill: true)
        return (s, outer.uuid(5))
    }

    static func moveOf(_ msgs: Message...) -> (Double, Double) {
        for m in msgs {
            if let off = m.message(14) ?? m.message(6), (off.float(1) ?? 0) != 0 || (off.float(2) ?? 0) != 0 {
                return (off.float(1) ?? 0, off.float(2) ?? 0)
            }
        }
        return (0, 0)
    }

    /// A geometry message's outline: a path (1 or 2), a rectangle (3) or an ellipse (4).
    static func geometryPoints(_ geo: Message) -> [(Double, Double)] {
        var pts: [(Double, Double)] = []
        if let container = geo.message(1) ?? geo.message(2) { pts = pathPoints(container) }
        if pts.count < 2 {
            func pair(_ m: Message, _ n: Int) -> (Double, Double)? { m.message(n).flatMap(pointOf) }
            if let ellipse = geo.message(4) {
                if let c = pair(ellipse, 1), let r = pair(ellipse, 2) {
                    let rot = ellipse.float(3) ?? 0
                    for i in 0...96 {
                        let t = 2 * Double.pi * Double(i) / 96
                        pts.append((c.0 + r.0 * cos(t) * cos(rot) - r.1 * sin(t) * sin(rot), c.1 + r.0 * cos(t) * sin(rot) + r.1 * sin(t) * cos(rot)))
                    }
                }
            } else if let rect = geo.message(3), let c = pair(rect, 1), let sz = pair(rect, 2) {
                let (l, t, r, b) = (c.0 - sz.0 / 2, c.1 - sz.1 / 2, c.0 + sz.0 / 2, c.1 + sz.1 / 2)
                pts = [(l, t), (r, t), (r, b), (l, b), (l, t)]
            }
        }
        return pts
    }

    // MARK: - Text boxes and images

    /// A text box record (field 21 → {20: position, 32: {1: {2: LZ4 rich text}, 2: size, 5: font, 10: inset}}).
    static func textBox(_ rec: Message) -> TextBox? {
        guard let msg = rec.message(21), let box = msg.message(32), let payload = box.message(1)?.bytes(2),
              let start = find(bv41, in: payload) else { return nil }
        func xy(_ m: Message?) -> (Double, Double)? { m?.message(1).map { ($0.float(1) ?? 0, $0.float(2) ?? 0) } }
        let size = box.message(2), inset = box.message(10)
        var (x, y) = xy(msg.message(20)) ?? (0, 0)
        if x == 0, y == 0 { x = size?.float(1) ?? 0; y = size?.float(2) ?? 0 }
        let w = (size?.float(1) ?? 0) + 2 * (inset?.float(1) ?? 0), h = (size?.float(2) ?? 0) + 2 * (inset?.float(2) ?? 0)
        let font = box.message(5)?.message(1)
        let defaultSize = (font?.float(40)).flatMap { $0 > 0 ? $0 : nil } ?? 24
        guard let unpacked = try? appleLZ4(payload[start...]), let rich = try? decodeMessage(unpacked.0[...]) else { return nil }
        var runs: [TextRun] = []
        for f in rich {
            guard let item = f.message, let text = item.string(1), !text.isEmpty else { continue }
            let style = item.message(2)
            let fontName = style?.string(30) ?? ""
            let c = style?.message(3)
            runs.append(TextRun(text: text, size: (style?.float(40)).flatMap { $0 > 0 ? $0 : nil } ?? defaultSize,
                                rgb: c.map { c in [1, 2, 3].map { min(1, max(0, c.float($0) ?? 0)) } } ?? [0, 0, 0],
                                bold: fontName.range(of: "bold", options: .caseInsensitive) != nil,
                                italic: style?.varint(50) == 1 || fontName.range(of: "italic", options: .caseInsensitive) != nil))
        }
        return runs.isEmpty ? nil : TextBox(id: rec.uuid(1), x: x, y: y, w: w, h: h, runs: runs)
    }

    /// An image's frame, from a nested {2: {1: {x, y}, 2: {w, h}}, 3: crop}.
    static func imageBox(_ rec: Message) -> (x: Double, y: Double, w: Double, h: Double)? {
        for f in rec {
            guard let msg = f.message, let frame = msg.message(2) else { continue }
            let xy = frame.message(1), wh = frame.message(2)
            guard let w = wh?.float(1), let h = wh?.float(2), w > 0, h > 0 else { continue }
            let crop = msg.message(3), c = crop?.message(1), cs = crop?.message(2)
            if let cw = cs?.float(1), let ch = cs?.float(2), let cx = c?.float(1), let cy = c?.float(2), cw > 0, ch > 0, cx > 0 {
                return (cx - cw / 2, cy - ch / 2, cw, ch)
            }
            return (xy?.float(1) ?? 0, xy?.float(2) ?? 0, w, h)
        }
        return nil
    }

    static func pdfSize(_ data: Data) -> (width: Double, height: Double)? {
        let text = String(decoding: data.prefix(4 * 1024 * 1024), as: UTF8.self)
        guard let re = try? NSRegularExpression(pattern: #"/MediaBox\s*\[\s*([-\d.]+)\s+([-\d.]+)\s+([-\d.]+)\s+([-\d.]+)\s*\]"#),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        let n = (1...4).map { Range(m.range(at: $0), in: text).flatMap { Double(text[$0]) } ?? 0 }
        let w = abs(n[2] - n[0]), h = abs(n[3] - n[1])
        return w > 0 && h > 0 ? (w, h) : nil
    }

    // MARK: - Protobuf wire format

    struct Field {
        let n: Int
        let wt: Int
        /// Varint value, or the raw bits of a fixed32.
        let int: UInt64
        let bytes: ArraySlice<UInt8>?

        var message: Message? { bytes.flatMap { $0.isEmpty ? nil : try? decodeMessage($0) } }
        var text: String? { bytes.map { String(decoding: $0, as: UTF8.self) } }
    }
    typealias Message = [Field]

    static func varint(_ b: ArraySlice<UInt8>, _ pos: inout Int) throws -> UInt64 {
        var value: UInt64 = 0, shift: UInt64 = 0
        for _ in 0..<10 {
            guard pos < b.endIndex else { throw Failure.notANotebook }
            let byte = b[pos]
            pos += 1
            if shift < 64 { value |= UInt64(byte & 0x7F) << shift }
            if byte & 0x80 == 0 { return value }
            shift += 7
        }
        throw Failure.notANotebook
    }

    /// The fields read before any bad bytes (a stroke's trailer cut from a group).
    static func decodeMessage(_ b: ArraySlice<UInt8>, lenient: Bool) -> Message {
        var fields: Message = []
        try? decodeFields(b, into: &fields)
        return fields
    }

    static func decodeMessage(_ b: ArraySlice<UInt8>) throws -> Message {
        var fields: Message = []
        try decodeFields(b, into: &fields)
        return fields
    }

    /// Reads fields into `fields`, which keeps what was read when it throws.
    static func decodeFields(_ b: ArraySlice<UInt8>, into fields: inout Message) throws {
        var pos = b.startIndex
        while pos < b.endIndex {
            let key = try varint(b, &pos)
            let n = Int(key >> 3), wt = Int(key & 7)
            guard n > 0 else { throw Failure.notANotebook }
            switch wt {
            case 0: fields.append(Field(n: n, wt: wt, int: try varint(b, &pos), bytes: nil))
            case 1:
                guard pos + 8 <= b.endIndex else { throw Failure.notANotebook }
                fields.append(Field(n: n, wt: wt, int: 0, bytes: b[pos..<(pos + 8)])); pos += 8
            case 5:
                guard pos + 4 <= b.endIndex else { throw Failure.notANotebook }
                let v = UInt64(b[pos]) | UInt64(b[pos + 1]) << 8 | UInt64(b[pos + 2]) << 16 | UInt64(b[pos + 3]) << 24
                fields.append(Field(n: n, wt: wt, int: v, bytes: nil)); pos += 4
            case 2:
                let len = try varint(b, &pos)
                guard len <= UInt64(b.endIndex - pos) else { throw Failure.notANotebook }
                fields.append(Field(n: n, wt: wt, int: 0, bytes: b[pos..<(pos + Int(len))])); pos += Int(len)
            default: throw Failure.notANotebook
            }
        }
    }

    /// A member's records. GoodNotes writes length-prefixed records; some members are one message
    /// whose field-7 entries are the records. The length-prefixed reading is tried first, since a
    /// short record stream can also happen to parse as one message.
    static func records(_ data: [UInt8]) -> [Message] {
        guard !data.isEmpty else { return [] }
        let b = data[...]
        var out: [Message] = []
        var pos = b.startIndex
        var ok = true
        while pos < b.endIndex {
            guard let len = try? varint(b, &pos), len <= UInt64(b.endIndex - pos),
                  let msg = try? decodeMessage(b[pos..<(pos + Int(len))]) else { ok = false; break }
            out.append(msg)
            pos += Int(len)
        }
        if ok { return out }
        guard let msg = try? decodeMessage(b) else { return [] }
        let nested = msg.filter { $0.n == 7 }.compactMap(\.message)
        return nested.isEmpty ? [msg] : nested
    }

    static func isUUID(_ s: String) -> Bool {
        s.utf8.count == 36 && s.utf8[s.utf8.index(s.utf8.startIndex, offsetBy: 8)] == UInt8(ascii: "-")
            && s.allSatisfy { $0 == "-" || $0.isHexDigit }
    }

    /// GoodNotes bumps a page id's last character per revision: compare without it.
    static func pageKey(_ id: String) -> String { String(id.prefix(32)) }

    static func f32(_ word: Int64) -> Float { Float(bitPattern: UInt32(truncatingIfNeeded: word)) }
    static func d(_ word: Int64) -> Double { Double(f32(word)) }
    static func d32(_ bits: UInt64) -> Double { Double(Float(bitPattern: UInt32(truncatingIfNeeded: bits))) }

    static func find(_ pattern: [UInt8], in b: ArraySlice<UInt8>) -> Int? {
        guard b.count >= pattern.count else { return nil }
        var i = b.startIndex
        while i <= b.endIndex - pattern.count {
            if b[i] == pattern[0], b[i + 1] == pattern[1], b[i + 2] == pattern[2], b[i + 3] == pattern[3] { return i }
            i += 1
        }
        return nil
    }

    // MARK: - Apple LZ4

    /// Decodes "bv41"/"bv4-" blocks up to "bv4$": the bytes, and how many input bytes were used.
    static func appleLZ4(_ b: ArraySlice<UInt8>) throws -> ([UInt8], Int) {
        var out: [UInt8] = []
        out.reserveCapacity(b.count * 4)
        var pos = b.startIndex
        func u32(_ p: Int) -> Int { Int(b[p]) | Int(b[p + 1]) << 8 | Int(b[p + 2]) << 16 | Int(b[p + 3]) << 24 }
        while true {
            guard pos + 4 <= b.endIndex else { throw Failure.notANotebook }
            let magic = String(decoding: b[pos..<(pos + 4)], as: UTF8.self)
            pos += 4
            if magic == "bv4$" { return (out, pos - b.startIndex) }
            guard magic == "bv41" || magic == "bv4-", pos + 8 <= b.endIndex else { throw Failure.notANotebook }
            let rawSize = u32(pos), stored = u32(pos + 4)
            pos += 8
            guard stored <= b.endIndex - pos else { throw Failure.notANotebook }
            let src = b[pos..<(pos + stored)]
            pos += stored
            if magic == "bv4-" { out.append(contentsOf: src); continue }
            let end = out.count + rawSize
            var i = src.startIndex
            while i < src.endIndex {
                let token = Int(src[i]); i += 1
                var lit = token >> 4
                if lit == 15 { var x = 255; while x == 255, i < src.endIndex { x = Int(src[i]); i += 1; lit += x } }
                guard lit <= src.endIndex - i else { throw Failure.notANotebook }
                out.append(contentsOf: src[i..<(i + lit)]); i += lit
                if i >= src.endIndex { break }
                guard i + 2 <= src.endIndex else { throw Failure.notANotebook }
                let offset = Int(src[i]) | Int(src[i + 1]) << 8; i += 2
                guard offset > 0, offset <= out.count else { throw Failure.notANotebook }
                var len = token & 15
                if len == 15 { var x = 255; while x == 255, i < src.endIndex { x = Int(src[i]); i += 1; len += x } }
                len += 4
                for _ in 0..<len { out.append(out[out.count - offset]) }
            }
            guard out.count == end else { throw Failure.notANotebook }
        }
    }

    // MARK: - TPL

    indirect enum TPLValue {
        case num(Int64)
        case double(Double)
        case string(String)
        case bytes([UInt8])
        case list([TPLValue])
        case tuple([TPLValue])

        var number: Int64? { if case .num(let n) = self { n } else { nil } }
        var list: [TPLValue]? { if case .list(let l) = self { l } else { nil } }
    }

    struct TPLImage {
        var format: String
        var values: [TPLValue]
    }

    indirect enum TPLNode {
        case scalar(Character)
        case array([TPLNode])
        case structure([TPLNode])
    }

    static func parseFormat(_ s: String) throws -> [TPLNode] {
        let chars = Array(s)
        var pos = 0
        func group(_ closing: Bool) throws -> [TPLNode] {
            var nodes: [TPLNode] = []
            while pos < chars.count {
                let c = chars[pos]; pos += 1
                if c == ")" { return nodes }
                if c == "A" || c == "S" {
                    pos += 1 // "("
                    let children = try group(true)
                    nodes.append(c == "A" ? .array(children) : .structure(children))
                } else {
                    nodes.append(.scalar(c))
                }
            }
            if closing { throw Failure.notANotebook }
            return nodes
        }
        return try group(false)
    }

    /// A TPL image. `u` values stay raw 32-bit words (often float bits).
    static func decodeTPL(_ b: [UInt8]) throws -> TPLImage {
        guard b.count >= 9, b[0] == 0x74, b[1] == 0x70, b[2] == 0x6C else { throw Failure.notANotebook }
        var end = 8
        while end < b.count, b[end] != 0 { end += 1 }
        let format = String(decoding: b[8..<end], as: UTF8.self)
        var pos = end + 1
        func take(_ n: Int) throws -> ArraySlice<UInt8> {
            guard n >= 0, pos + n <= b.count else { throw Failure.notANotebook }
            defer { pos += n }
            return b[pos..<(pos + n)]
        }
        func uint(_ n: Int) throws -> UInt64 { try take(n).reversed().reduce(0) { $0 << 8 | UInt64($1) } }
        func read(_ node: TPLNode) throws -> TPLValue {
            switch node {
            case .structure(let children): return .tuple(try children.map(read))
            case .array(let children):
                let count = Int(try uint(4))
                guard count <= b.count else { throw Failure.notANotebook }
                var list: [TPLValue] = []
                list.reserveCapacity(count)
                for _ in 0..<count { list.append(children.count == 1 ? try read(children[0]) : .tuple(try children.map(read))) }
                return .list(list)
            case .scalar(let c):
                switch c {
                case "c": return .num(Int64(Int8(bitPattern: UInt8(try uint(1)))))
                case "j": return .num(Int64(Int16(bitPattern: UInt16(try uint(2)))))
                case "v": return .num(Int64(try uint(2)))
                case "i": return .num(Int64(Int32(bitPattern: UInt32(try uint(4)))))
                case "u": return .num(Int64(try uint(4)))
                case "I", "U": return .num(Int64(bitPattern: try uint(8)))
                case "f": return .double(Double(bitPattern: try uint(8)))
                case "s": let n = Int(try uint(4)); return .string(String(decoding: try take(max(n - 1, 0)), as: UTF8.self))
                case "B": let n = Int(try uint(4)); return .bytes(Array(try take(n)))
                default: throw Failure.notANotebook
                }
            }
        }
        return TPLImage(format: format, values: try parseFormat(format).map(read))
    }
}

extension Array where Element == GoodNotesInk.Field {
    func first(_ n: Int) -> GoodNotesInk.Field? { first { $0.n == n } }
    func bytes(_ n: Int) -> ArraySlice<UInt8>? { first(n)?.bytes }
    func message(_ n: Int) -> GoodNotesInk.Message? { first(n)?.message }
    func string(_ n: Int) -> String? { first(n)?.text }
    func uuid(_ n: Int) -> String? { string(n).flatMap { GoodNotesInk.isUUID($0) ? $0 : nil } }
    func varint(_ n: Int) -> UInt64? { first { $0.n == n && $0.wt == 0 }?.int }
    /// A fixed32 field as a float.
    func float(_ n: Int) -> Double? { first { $0.n == n && $0.wt == 5 }.map { GoodNotesInk.d32($0.int) } }
}
