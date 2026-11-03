import Foundation

/// Export to GoodNotes (docs/MASTER_PLAN.md G13): notebooks, whiteboards and every other drawing
/// as `.goodnotes` files, written in the layouts `GoodNotesInk` reads (docs/GOODNOTES.md).
///
/// - **Round trip** (`patch`): a notebook that came from GoodNotes is copied and only Trove's ink is
///   added. GoodNotes' own ink and typed text on each page are marked erased (GoodNotes' own erase
///   flag, field 3 = 1), since Trove's copy of them is what was edited; everything else in the file
///   (pictures, shape fills, sticky notes, audio, things Trove can't read yet) stays byte for byte.
/// - **Fresh** (`notebook`): a sketch, notebook or whiteboard made in Trove, with each page's
///   paper as a PDF background.
///
/// GoodNotes doesn't document its format, so every export is read back with `GoodNotesInk` in the
/// tests, and PDF export stays next to this as the fallback.
public enum GoodNotesWriter {
    /// A stroke in page points (Trove's units).
    public struct Stroke: Sendable, Equatable {
        public var color: String
        public var width: Double
        public var points: [InkPoint]
        public var highlighter: Bool
        public init(color: String, width: Double, points: [InkPoint], highlighter: Bool = false) {
            self.color = color; self.width = width; self.points = points; self.highlighter = highlighter
        }
    }

    public struct Text: Sendable, Equatable {
        public var x: Double, y: Double, w: Double, h: Double
        public var text: String
        public var size: Double
        public var color: String
        public init(x: Double, y: Double, w: Double, h: Double, text: String, size: Double, color: String) {
            self.x = x; self.y = y; self.w = w; self.h = h; self.text = text; self.size = size; self.color = color
        }
    }

    public struct PageInk: Sendable, Equatable {
        public var strokes: [Stroke]
        public var texts: [Text]
        public init(strokes: [Stroke] = [], texts: [Text] = []) { self.strokes = strokes; self.texts = texts }
    }

    /// What didn't go across exactly, for the export report.
    public struct Report: Sendable, Equatable {
        public var pages = 0
        public var strokes = 0
        public var texts = 0
        public var notes: [String] = []
    }

    public enum Failure: Error, Equatable { case notANotebook }

    // MARK: Round trip

    /// The original notebook with Trove's ink for each page (by page index) in place of GoodNotes'
    /// own ink and text. Pages not in `pages` are left exactly as they were.
    public static func patch(_ original: Data, pages: [Int: PageInk]) throws -> (data: Data, report: Report) {
        guard let zip = try? ZipArchive(original), let notebook = try? GoodNotesInk.read(original) else { throw Failure.notANotebook }
        var report = Report()
        var appended: [String: [UInt8]] = [:]
        for (index, ink) in pages.sorted(by: { $0.key < $1.key }) where index < notebook.pages.count {
            let page = notebook.pages[index]
            guard !page.path.isEmpty else { continue }
            var records: [[UInt8]] = []
            // GoodNotes' own ink and text: erased (Trove's copy replaces them).
            var erased: Set<String> = []
            // An outline that owns a fill stays (erasing it would hide its fill too).
            let owners = Set(page.strokes.compactMap(\.fillOf))
            if !owners.isEmpty { report.notes.append("Page \(index + 1): \(owners.count) filled shape\(owners.count == 1 ? "" : "s") kept as GoodNotes drew them") }
            for layer in page.layers {
                switch layer {
                case .ink(let s) where !s.isFill: if let id = s.id, !owners.contains(id) { erased.insert(id) }
                case .text(let t): if let id = t.id { erased.insert(id) }
                default: break
                }
            }
            for id in erased.sorted() { records.append(element(id, erased: true)) }
            // From Trove's points back to GoodNotes' units (and where fitToContent moved things from).
            let toGN = { (x: Double, y: Double) -> (Double, Double) in (x / GoodNotesInk.scale - page.offsetX, y / GoodNotesInk.scale - page.offsetY) }
            for s in ink.strokes where !s.points.isEmpty {
                let id = newId()
                records.append(element(id, erased: false))
                records.append(strokeRecord(id: id, s, transform: toGN))
                report.strokes += 1
            }
            for t in ink.texts where !t.text.isEmpty {
                let (x, y) = toGN(t.x, t.y)
                records.append(textRecord(id: newId(), x: x, y: y, w: t.w / GoodNotesInk.scale, h: t.h / GoodNotesInk.scale,
                                          text: t.text, size: t.size / GoodNotesInk.scale, color: t.color))
                report.texts += 1
            }
            appended[page.path, default: []] += delimited(records)
            report.pages += 1
        }
        var entries: [(String, [UInt8])] = []
        for e in zip.entries where !e.isDirectory {
            var bytes = [UInt8]((try? zip.data(for: e)) ?? Data())
            if let extra = appended[e.path] { bytes += extra }
            entries.append((e.path, bytes))
        }
        return (Data(ZipWriter.stored(entries)), report)
    }

    // MARK: Fresh

    public struct FreshPage: Sendable {
        public var width: Double
        public var height: Double
        /// One page of PDF drawn with the page's paper; nil for none (whiteboards).
        public var background: Data?
        public var ink: PageInk
        public init(width: Double, height: Double, background: Data?, ink: PageInk) {
            self.width = width; self.height = height; self.background = background; self.ink = ink
        }
    }

    /// A new notebook (or, with one page and no background, a whiteboard).
    public static func notebook(_ pages: [FreshPage]) -> (data: Data, report: Report) {
        var report = Report()
        var notesIndex: [[UInt8]] = [], attachIndex: [[UInt8]] = [], events: [[UInt8]] = []
        var files: [(String, [UInt8])] = []
        let identity = { (x: Double, y: Double) -> (Double, Double) in (x / GoodNotesInk.scale, y / GoodNotesInk.scale) }
        for (i, page) in pages.enumerated() {
            let pageId = newId()
            let path = "notes/\(pageId)"
            notesIndex.append(msg(fLen(1, pageId), fLen(2, path)))
            events.append(msg(fLen(54, msg(fLen(2, pageId), fLen(4, msg(fLen(1, orderKey(i)))))), fInt(14, UInt64(i + 1))))
            if let pdf = page.background {
                let attId = newId()
                attachIndex.append(msg(fLen(1, attId), fLen(2, "attachments/\(attId)")))
                files.append(("attachments/\(attId)", [UInt8](pdf)))
                // Page ↔ background, as GoodNotes pairs them in an event.
                events.append(msg(fLen(1, pageId), fLen(2, attId)))
            }
            var records: [[UInt8]] = []
            for s in page.ink.strokes where !s.points.isEmpty {
                let id = newId()
                records.append(element(id, erased: false))
                records.append(strokeRecord(id: id, s, transform: identity))
                report.strokes += 1
            }
            for t in page.ink.texts where !t.text.isEmpty {
                records.append(textRecord(id: newId(), x: t.x / GoodNotesInk.scale, y: t.y / GoodNotesInk.scale, w: t.w / GoodNotesInk.scale,
                                          h: t.h / GoodNotesInk.scale, text: t.text, size: t.size / GoodNotesInk.scale, color: t.color))
                report.texts += 1
            }
            files.append((path, delimited(records)))
            report.pages += 1
        }
        let all: [(String, [UInt8])] = [
            ("index.notes.pb", delimited(notesIndex)),
            ("index.attachments.pb", delimited(attachIndex)),
            ("index.events.pb", delimited(events)),
        ] + files
        return (Data(ZipWriter.stored(all)), report)
    }

    /// Fractional-index style keys that sort in page order ("a0000", "a0001", …).
    static func orderKey(_ i: Int) -> String { "a" + String(format: "%04d", i) }

    // MARK: Records

    static func newId() -> String { UUID().uuidString.uppercased() }

    static func element(_ id: String, erased: Bool) -> [UInt8] {
        erased ? msg(fLen(1, id), fInt(3, 1), fInt(16, 24)) : msg(fLen(1, id), fInt(16, 24))
    }

    /// A stroke in the GoodNotes 6 layout: a start point (x, y, r, 0), then (x, y, r) for the rest;
    /// r is the half-width there (from pressure, as `editableInk` reads it back).
    static func strokeRecord(id: String, _ s: Stroke, transform: (Double, Double) -> (Double, Double)) -> [UInt8] {
        let half = s.width / GoodNotesInk.scale / 2
        func radius(_ p: InkPoint) -> Double { s.highlighter ? half : half * (0.35 + 0.65 * min(1, max(0, p.pressure))) }
        var start: [Double] = [], rest: [Double] = []
        for (i, p) in s.points.enumerated() {
            var (x, y) = transform(p.x, p.y)
            // The reader skips (|x|, |y|) < 10 as markers: nudge real points out of that corner.
            if Swift.abs(x) < 10 && Swift.abs(y) < 10 { x = x < 0 ? -10.01 : 10.01 }
            if i == 0 { start = [x, y, radius(p), 0] } else { rest += [x, y, radius(p)] }
        }
        var w = TPLWriter()
        w.u16(2)
        w.u32(2); w.u16(0); w.u16(1)
        w.u32(UInt32(start.count / 1)); for v in start { w.f32(v) }
        w.u32(UInt32(rest.count)); for v in rest { w.f32(v) }
        for _ in 0..<7 { w.u32(0) }
        let image = w.image(format: "vA(v)A(u)A(u)A(v)A(v)A(u)A(u)A(u)A(u)A(v)")
        let (r, g, b) = rgb(s.color)
        let alpha = s.highlighter ? 0.5 : 1.0
        return fLen(7, msg(fLen(1, id), fLen(2, lz4(image)), fInt(3, 1), fLen(4, colour(r, g, b, alpha))))
    }

    static func textRecord(id: String, x: Double, y: Double, w: Double, h: Double, text: String, size: Double, color: String) -> [UInt8] {
        let (r, g, b) = rgb(color)
        let rich = msg(fLen(1, msg(fLen(1, text), fLen(2, msg(fFloat(40, size), fLen(3, colour(r, g, b, 1)))))))
        return msg(fLen(1, id), fLen(21, msg(fLen(20, msg(fLen(1, xy(x, y)))),
            fLen(32, msg(fLen(1, msg(fLen(2, lz4(rich)))), fLen(2, xy(w, h)), fLen(5, msg(fLen(1, msg(fFloat(40, size))))), fLen(10, xy(5, 5)))))))
    }

    static func rgb(_ hex: String) -> (Double, Double, Double) {
        let h = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard h.count >= 6, let v = UInt32(h.prefix(6), radix: 16) else { return (0, 0, 0) }
        return (Double(v >> 16 & 0xFF) / 255, Double(v >> 8 & 0xFF) / 255, Double(v & 0xFF) / 255)
    }

    // MARK: Protobuf

    static func varint(_ value: UInt64) -> [UInt8] {
        var v = value, out: [UInt8] = []
        repeat {
            var byte = UInt8(v & 0x7F)
            v >>= 7
            if v != 0 { byte |= 0x80 }
            out.append(byte)
        } while v != 0
        return out
    }
    static func fLen(_ n: Int, _ bytes: [UInt8]) -> [UInt8] { varint(UInt64(n * 8 + 2)) + varint(UInt64(bytes.count)) + bytes }
    static func fLen(_ n: Int, _ text: String) -> [UInt8] { fLen(n, Array(text.utf8)) }
    static func fInt(_ n: Int, _ v: UInt64) -> [UInt8] { varint(UInt64(n * 8)) + varint(v) }
    static func fFloat(_ n: Int, _ v: Double) -> [UInt8] {
        let bits = Float(v).bitPattern
        return varint(UInt64(n * 8 + 5)) + [UInt8(bits & 0xFF), UInt8(bits >> 8 & 0xFF), UInt8(bits >> 16 & 0xFF), UInt8(bits >> 24 & 0xFF)]
    }
    static func msg(_ fields: [UInt8]...) -> [UInt8] { fields.flatMap { $0 } }
    static func xy(_ x: Double, _ y: Double) -> [UInt8] { msg(fFloat(1, x), fFloat(2, y)) }
    static func colour(_ r: Double, _ g: Double, _ b: Double, _ a: Double) -> [UInt8] { msg(fFloat(1, r), fFloat(2, g), fFloat(3, b), fFloat(4, a)) }
    static func delimited(_ records: [[UInt8]]) -> [UInt8] { records.flatMap { varint(UInt64($0.count)) + $0 } }

    /// Apple LZ4 frame holding one block of literals (valid LZ4 every decoder accepts), then the end marker.
    static func lz4(_ data: [UInt8]) -> [UInt8] {
        let lit = data.count
        var block: [UInt8] = [UInt8(min(lit, 15) << 4)]
        if lit >= 15 {
            var rest = lit - 15
            while rest >= 255 { block.append(255); rest -= 255 }
            block.append(UInt8(rest))
        }
        block += data
        func le32(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24 & 0xFF)] }
        return Array("bv41".utf8) + le32(data.count) + le32(block.count) + block + Array("bv4$".utf8)
    }
}

/// A TPL image: "tpl", a flag byte, the total size, the format string, then little-endian values.
struct TPLWriter {
    private var body: [UInt8] = []
    mutating func u16(_ v: UInt16) { body += [UInt8(v & 0xFF), UInt8(v >> 8)] }
    mutating func u32(_ v: UInt32) { body += [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24 & 0xFF)] }
    mutating func f32(_ v: Double) { u32(Float(v).bitPattern) }
    func image(format: String) -> [UInt8] {
        var all = Array("tpl".utf8) + [0, 0, 0, 0, 0] + Array(format.utf8) + [0] + body
        let n = all.count
        all[4] = UInt8(n & 0xFF); all[5] = UInt8(n >> 8 & 0xFF); all[6] = UInt8(n >> 16 & 0xFF); all[7] = UInt8(n >> 24 & 0xFF)
        return all
    }
}

/// Writes a zip of stored (uncompressed) entries.
public enum ZipWriter {
    public static func stored(_ entries: [(String, [UInt8])]) -> [UInt8] {
        var out: [UInt8] = [], central: [UInt8] = []
        func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF)] }
        func le32(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24 & 0xFF)] }
        for (name, data) in entries {
            let n = Array(name.utf8)
            let crc = CRC32.checksum(Data(data))
            let offset = UInt32(out.count)
            out += le32(0x04034B50) + le16(20) + le16(0x0800) + le16(0) + le16(0) + le16(0) + le32(crc)
                + le32(UInt32(data.count)) + le32(UInt32(data.count)) + le16(n.count) + le16(0) + n + data
            central += le32(0x02014B50) + le16(20) + le16(20) + le16(0x0800) + le16(0) + le16(0) + le16(0) + le32(crc)
                + le32(UInt32(data.count)) + le32(UInt32(data.count)) + le16(n.count) + le16(0) + le16(0) + le16(0) + le16(0)
                + le32(0) + le32(offset) + n
        }
        let dirOffset = UInt32(out.count)
        out += central
        out += le32(0x06054B50) + le16(0) + le16(0) + le16(entries.count) + le16(entries.count) + le32(UInt32(central.count)) + le32(dirOffset) + le16(0)
        return out
    }
}
