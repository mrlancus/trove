import CoreGraphics
import CoreText
import Foundation
import PDFKit
import TroveCore

/// Handwriting search (PROTOCOL.md §10 `inkText`): an Apple device draws a sketch's ink on white
/// and reads it with Vision. It runs when the editor closes, and from enrichment for sketches drawn
/// on the website or another device, only when the ink changed since it was last read. Each page's
/// text is kept on this device with a signature of its strokes, so a stroke on page 3 re-reads page
/// 3, not the whole notebook (docs/ROADMAP.md §3.7 item 6).
enum Handwriting {
    static let signatureField = "inkTextSig"

    /// Reads what changed; returns how many pages went through Vision. `fast` in Low Power Mode or when hot.
    @discardableResult
    static func read(_ itemId: String, library: Library, fast: Bool = false, ai: AIClient? = nil) async -> Int {
        guard let item = await library.item(itemId), item.kind == .sketch else { return 0 }
        // Read by your AI or by Vision: switching to AI reads everything again, once.
        let reader = ai == nil ? "" : "|ai"
        let sig = await library.inkSignature(itemId) + reader
        guard item.record[signatureField]?.string != sig else { return 0 }
        let signpost = Perf.begin("Read handwriting")
        defer { Perf.end("Read handwriting", signpost) }
        let known = await HandwritingPages.shared.pages(of: itemId)
        var kept: [String: HandwritingPages.Page] = [:]
        var parts: [String] = []
        var read = 0
        var aiFailed = false
        for spec in InkRenderer.sketchPages(item) {
            let strokes = await library.strokes(on: itemId, pageKey: spec.key)
            guard !strokes.isEmpty else { continue }
            let latest = strokes.map(\.record.updatedHLC).max() ?? ""
            let pageSig = "\(strokes.count)-\(latest)-\(spec.width)x\(spec.height)\(reader)"
            if let page = known[spec.key], page.sig == pageSig {
                kept[spec.key] = page
                if !page.text.isEmpty { parts.append(page.text) }
                continue
            }
            // Plain white, no ruled lines: Vision reads handwriting best that way. Text boxes are
            // searchable already (`sketchText`).
            var plain = spec
            plain.background = .paper(.blank, color: nil)
            var area: InkGeometry.Rect?
            if spec.infinite, let b = await library.inkBounds(on: itemId, pageKey: spec.key) {
                area = InkGeometry.Rect(x: b.x - 16, y: b.y - 16, width: b.width + 32, height: b.height + 32)
            }
            let content = InkContent(strokes: strokes.map(InkLine.init))
            let w = area?.width ?? spec.width, h = area?.height ?? spec.height
            // Your AI sees at most ~1568 px on the long side; Vision likes it bigger.
            let width = ai != nil ? Self.aiWidth(w, h) : Int(min(2400, max(800, w * 2)))
            let box = area
            guard let image = await Task.detached(priority: .utility, operation: {
                InkRenderer.render(plain, content: content, pixelWidth: width, area: box).map(InkImage.init)
            }).value else { continue }
            var text = ""
            var stamp = pageSig
            if let ai, let jpeg = InkRenderer.jpeg(image.image, quality: 0.85),
               let read = try? await ai.readPage(jpeg, mime: "image/jpeg", about: item.displayTitle) {
                text = read
            } else {
                text = await AppleEnricher.recognizeText(in: image.image, fast: fast).trimmingCharacters(in: .whitespacesAndNewlines)
                // Your AI didn't answer (offline, out of credit): Vision's reading for now, AI next time.
                if ai != nil { aiFailed = true; stamp = String(pageSig.dropLast(reader.count)) }
            }
            read += 1
            kept[spec.key] = HandwritingPages.Page(sig: stamp, text: text)
            if !text.isEmpty { parts.append(text) }
        }
        await HandwritingPages.shared.set(kept, for: itemId)
        await library.setInkText(itemId, parts.joined(separator: "\n"))
        if !aiFailed { await library.update(itemId, [signatureField: .string(sig)]) }
        return read
    }
}

/// Each sketch page's recognised text and the signature of the strokes it was read from. Local to
/// this device (Caches; rebuilt if the system clears it), never synced.
actor HandwritingPages {
    static let shared = HandwritingPages()

    struct Page: Codable, Equatable {
        var sig: String
        var text: String
    }

    private var sketches: [String: [String: Page]]?
    private var saveTask: Task<Void, Never>?

    private var url: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("trove-handwriting-pages.json")
    }

    func pages(of itemId: String) -> [String: Page] {
        load()
        return sketches?[itemId] ?? [:]
    }

    func set(_ pages: [String: Page], for itemId: String) {
        load()
        guard sketches?[itemId] != pages else { return }
        sketches?[itemId] = pages
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            await self.save()
        }
    }

    private func load() {
        guard sketches == nil else { return }
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode([String: [String: Page]].self, from: data) {
            sketches = saved
        } else {
            sketches = [:]
        }
    }

    private func save() {
        guard let sketches, let data = try? JSONEncoder().encode(sketches) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

extension Handwriting {
    /// Pixels wide for a page sent to your AI: ~1568 on the long side (what vision models read at).
    static func aiWidth(_ width: Double, _ height: Double) -> Int {
        let long = max(1, width, height)
        return max(200, Int((width * 1568 / long).rounded()))
    }

    // MARK: Files: GoodNotes, PDFs, photos of pages (your AI only)

    /// What the files were read from (attachments and their ink), so they're read again only when it changes.
    static let filesField = "aiReadSig"
    static let maxPagesPerItem = 60

    static func readable(_ a: Attachment) -> Bool {
        a.name.lowercased().hasSuffix(".goodnotes") || a.mime == "application/pdf" || a.mime.hasPrefix("image/")
    }

    /// Items whose files your AI should read: not sketches (above) and not screenshots (typed text,
    /// which Vision reads well).
    static func wantsFileRead(_ item: Item) -> Bool {
        item.kind != .sketch && !item.id.hasPrefix("screenshot-") && item.attachments.contains(where: readable)
    }

    static func fileSignature(_ item: Item, ink: String) -> String {
        item.attachments.filter(readable).map(\.id).joined(separator: ",") + "|" + ink
    }

    /// Reads a file item's handwriting with your AI, as soon as it arrives from anywhere: every page of
    /// a GoodNotes notebook, scanned PDFs (typed ones only where there's ink on them), pictures, and
    /// ink written on any of them. Returns how many pages were read.
    @discardableResult
    static func readFiles(_ itemId: String, library: Library, ai: AIClient) async -> Int {
        guard let item = await library.item(itemId), wantsFileRead(item) else { return 0 }
        let sig = fileSignature(item, ink: await library.inkSignature(itemId))
        guard item.record[filesField]?.string != sig else { return 0 }
        var parts: [String] = []
        var read = 0, failed = 0
        for att in item.attachments.prefix(3) where readable(att) {
            guard let data = try? await library.attachmentData(att) else { continue }
            if att.name.lowercased().hasSuffix(".goodnotes") {
                // The notebook as GoodNotes drew it, every layer (its ink may not be in Trove yet).
                guard let notebook = await Task.detached(priority: .utility, operation: { try? GoodNotesInk.read(data) }).value else { continue }
                for page in notebook.pages.prefix(maxPagesPerItem - read) {
                    let width = CGFloat(aiWidth(Double(page.width), Double(page.height)))
                    guard let image = await Task.detached(priority: .utility, operation: {
                        NotebookRenderer.render(page, of: notebook, width: width, scale: 1).map { InkImage(image: $0.cgImage) }
                    }).value else { continue }
                    if let text = await readImage(image.image, ai: ai, about: item.displayTitle) { if !text.isEmpty { parts.append(text) } } else { failed += 1 }
                    read += 1
                }
                continue
            }
            let name = att.name, mime = att.mime
            let specs = await Task.detached(priority: .utility, operation: { InkRenderer.pages(for: data, mime: mime, name: name) }).value
            let typed = mime == "application/pdf" && !(PDFDocument(data: data)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            for spec in specs {
                guard read < maxPagesPerItem else { break }
                let strokes = await library.strokes(on: itemId, layer: att.id, pageKey: spec.key)
                // A typed PDF's text is searchable already: only pages written on are read.
                if typed && strokes.isEmpty { continue }
                let content = InkContent(strokes: strokes.map(InkLine.init))
                let width = aiWidth(spec.width, spec.height)
                guard let image = await Task.detached(priority: .utility, operation: {
                    InkRenderer.render(spec, content: content, pixelWidth: width).map(InkImage.init)
                }).value else { continue }
                if let text = await readImage(image.image, ai: ai, about: item.displayTitle) { if !text.isEmpty { parts.append(text) } } else { failed += 1 }
                read += 1
            }
        }
        // Nothing read (offline, out of credit): try again next time rather than keep an empty result.
        if failed > 0 && parts.isEmpty { return read }
        await library.setInkText(itemId, parts.joined(separator: "\n\n"))
        await library.update(itemId, [filesField: .string(sig)])
        return read
    }

    private static func readImage(_ image: CGImage, ai: AIClient, about: String) async -> String? {
        guard let jpeg = InkRenderer.jpeg(image, quality: 0.85) else { return nil }
        return try? await ai.readPage(jpeg, mime: "image/jpeg", about: about)
    }
}

// MARK: Pages for Ask (view)

extension Handwriting {
    /// Pictures for your AI are sized by what's on them, so writing is always legible: at least
    /// about one pixel per point of the page (a GoodNotes page is ~600 points wide), never more than
    /// the 1568 px a model reads at. A page too big for that (a whiteboard, an endless sketch) is
    /// shown whole with a lettered grid over it, and the model asks for one square (`section`, like
    /// "B2"), drawn sharp. That costs only the squares it needs, not the whole board at full size.
    static let maxSide = 1568.0
    static let minPixelsPerPoint = 1.0
    /// A grid square is at most this many points across, so it can be drawn sharp.
    static let cellPoints = 1400.0

    struct PageResult: Sendable {
        var images: [Data]
        var total: Int
        var note: String
    }

    /// The grid over a page of this size (columns, rows), or nil if it's small enough to read whole.
    static func grid(width: Double, height: Double) -> (cols: Int, rows: Int)? {
        guard max(width, height) * minPixelsPerPoint > maxSide else { return nil }
        return (min(6, max(1, Int((width / cellPoints).rounded(.up)))), min(6, max(1, Int((height / cellPoints).rounded(.up)))))
    }

    /// "B2" → column 1, row 1 (0-based), inside the grid.
    static func cell(_ name: String, in grid: (cols: Int, rows: Int)) -> (col: Int, row: Int)? {
        let t = name.trimmingCharacters(in: .whitespaces).uppercased()
        guard let letter = t.first, let a = letter.asciiValue, a >= 65, a < 65 + UInt8(grid.cols),
              let row = Int(t.dropFirst()), row >= 1, row <= grid.rows else { return nil }
        return (Int(a - 65), row - 1)
    }

    /// Draws pages `first..<first + count` of an item for your AI (with the ink written on them),
    /// or one `section` of page `first`; says how many pages it has and how to look closer.
    static func pageImages(_ item: Item, library: Library, first: Int, count: Int, section: String?) async -> PageResult {
        enum Source: Sendable { case sketch(InkPageSpec), notebook(GoodNotesInk.Notebook, Int), file(Attachment, InkPageSpec) }
        var pages: [Source] = []
        if item.kind == .sketch {
            pages = InkRenderer.sketchPages(item).map { .sketch($0) }
        }
        for att in item.attachments.prefix(3) where readable(att) {
            guard let data = try? await library.attachmentData(att) else { continue }
            if att.name.lowercased().hasSuffix(".goodnotes") {
                if let book = await Task.detached(priority: .userInitiated, operation: { try? GoodNotesInk.read(data) }).value {
                    pages += book.pages.indices.map { .notebook(book, $0) }
                }
            } else {
                let name = att.name, mime = att.mime
                let specs = await Task.detached(priority: .userInitiated, operation: { InkRenderer.pages(for: data, mime: mime, name: name) }).value
                pages += specs.map { .file(att, $0) }
            }
        }

        /// One page drawn at `pixelsPerPoint` (capped), with its size in points.
        func draw(_ source: Source, pixelsPerPoint: Double) async -> (InkImage, Double, Double)? {
            switch source {
            case .sketch(let spec):
                let strokes = await library.strokes(on: item.id, pageKey: spec.key)
                var area: InkGeometry.Rect?
                if spec.infinite, let b = await library.inkBounds(on: item.id, pageKey: spec.key) {
                    area = InkGeometry.Rect(x: b.x - 16, y: b.y - 16, width: b.width + 32, height: b.height + 32)
                }
                let content = InkContent(strokes: strokes.map(InkLine.init))
                let w = area?.width ?? spec.width, h = area?.height ?? spec.height, box = area
                let px = Self.pixels(w, h, pixelsPerPoint)
                return await Task.detached(priority: .userInitiated) {
                    InkRenderer.render(spec, content: content, pixelWidth: px, area: box).map { (InkImage(image: $0), w, h) }
                }.value
            case .notebook(let book, let i):
                let page = book.pages[i]
                let px = CGFloat(Self.pixels(page.width, page.height, pixelsPerPoint))
                return await Task.detached(priority: .userInitiated) {
                    NotebookRenderer.render(page, of: book, width: px, scale: 1).map { (InkImage(image: $0.cgImage), page.width, page.height) }
                }.value
            case .file(let att, let spec):
                let strokes = await library.strokes(on: item.id, layer: att.id, pageKey: spec.key)
                let content = InkContent(strokes: strokes.map(InkLine.init))
                let px = Self.pixels(spec.width, spec.height, pixelsPerPoint)
                return await Task.detached(priority: .userInitiated) {
                    InkRenderer.render(spec, content: content, pixelWidth: px).map { (InkImage(image: $0), spec.width, spec.height) }
                }.value
            }
        }

        let total = pages.count
        guard first >= 0, first < total else { return PageResult(images: [], total: total, note: "") }

        // One square of a big page, sharp.
        if let section, !section.isEmpty {
            guard let whole = await draw(pages[first], pixelsPerPoint: 0.05) else { return PageResult(images: [], total: total, note: "It couldn't be drawn.") }
            guard let g = grid(width: whole.1, height: whole.2), let c = cell(section, in: g) else {
                return PageResult(images: [], total: total, note: "Page \(first + 1) has no section \(section): it's small enough to view whole.")
            }
            let cellW = whole.1 / Double(g.cols), cellH = whole.2 / Double(g.rows)
            // Sharp enough for the square, but the whole page drawn at that size stays under ~40 MP.
            let ppp = min(Self.maxSide / max(cellW, cellH), 2.0, (40_000_000 / max(1, whole.1 * whole.2)).squareRoot())
            guard let big = await draw(pages[first], pixelsPerPoint: ppp) else { return PageResult(images: [], total: total, note: "It couldn't be drawn.") }
            let k = Double(big.0.image.width) / whole.1
            let rect = CGRect(x: Double(c.col) * cellW * k, y: Double(c.row) * cellH * k, width: cellW * k, height: cellH * k).integral
            guard let crop = big.0.image.cropping(to: rect), let jpeg = InkRenderer.jpeg(crop, quality: 0.8) else {
                return PageResult(images: [], total: total, note: "That section couldn't be drawn.")
            }
            return PageResult(images: [jpeg], total: total, note: "Section \(section.uppercased()) of page \(first + 1), sharp.")
        }

        var images: [Data] = [], notes: [String] = []
        for i in first..<min(total, first + max(1, count)) {
            // Its size first (cheaply), then drawn as sharp as the limit allows.
            guard let probe = await draw(pages[i], pixelsPerPoint: 0.05) else { continue }
            let (w, h) = (probe.1, probe.2)
            let ppp = min(Self.maxSide / max(w, h, 1), 2.0)
            guard let shown = await draw(pages[i], pixelsPerPoint: ppp) else { continue }
            var image = shown.0.image
            if let g = grid(width: w, height: h) {
                image = Self.overlayGrid(image, cols: g.cols, rows: g.rows) ?? image
                notes.append("Page \(i + 1) is big (\(Int(w))×\(Int(h)) points), so small writing may not be legible here: it has a \(g.cols)×\(g.rows) grid (columns A–\(String(UnicodeScalar(UInt8(64 + g.cols)))), rows 1–\(g.rows)). Call view with page \(i + 1) and a section like \"B2\" to see one square sharp; look only at the squares you need.")
            }
            if let jpeg = InkRenderer.jpeg(image, quality: 0.8) { images.append(jpeg) }
        }
        return PageResult(images: images, total: total, note: notes.joined(separator: " "))
    }

    /// Pixels wide for a page of `w`×`h` points at `ppp` pixels a point, inside the model's limit.
    static func pixels(_ w: Double, _ h: Double, _ ppp: Double) -> Int {
        let scale = min(ppp, 2.0)
        return max(16, Int((w * scale).rounded()))
    }

    /// Thin lines and a letter-number label in each square, so the model can name one.
    static func overlayGrid(_ image: CGImage, cols: Int, rows: Int) -> CGImage? {
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let cw = Double(w) / Double(cols), ch = Double(h) / Double(rows)
        ctx.setStrokeColor(CGColor(red: 1, green: 0.45, blue: 0.1, alpha: 0.55))
        ctx.setLineWidth(2)
        for c in 1..<max(1, cols) {
            ctx.move(to: CGPoint(x: Double(c) * cw, y: 0)); ctx.addLine(to: CGPoint(x: Double(c) * cw, y: Double(h))); ctx.strokePath()
        }
        for r in 1..<max(1, rows) {
            ctx.move(to: CGPoint(x: 0, y: Double(r) * ch)); ctx.addLine(to: CGPoint(x: Double(w), y: Double(r) * ch)); ctx.strokePath()
        }
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, max(14, min(cw, ch) * 0.07), nil)
        for c in 0..<cols {
            for r in 0..<rows {
                let label = "\(String(UnicodeScalar(UInt8(65 + c))))\(r + 1)"
                let text = NSAttributedString(string: label, attributes: [
                    NSAttributedString.Key(kCTFontAttributeName as String): font,
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 1, green: 0.4, blue: 0.1, alpha: 0.85),
                ])
                let line = CTLineCreateWithAttributedString(text)
                // Core Graphics counts rows from the bottom; labels go in each square's top-left.
                ctx.textPosition = CGPoint(x: Double(c) * cw + 6, y: Double(h) - Double(r) * ch - CTFontGetAscent(font) - 4)
                CTLineDraw(line, ctx)
            }
        }
        return ctx.makeImage()
    }
}
