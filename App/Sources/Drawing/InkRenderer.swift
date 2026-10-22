import CoreGraphics
import CoreText
import Foundation
import ImageIO
import TroveCore
import UniformTypeIdentifiers

/// What's under the ink on a page: a sketch's paper (in the page's colour), a PDF page or an image.
enum InkBackground: Sendable {
    case paper(InkPaper, color: String?)
    case pdf(Data, page: Int)
    case image(Data)
    /// A GoodNotes page: its background and pictures (its ink and text are Trove's once edited).
    case goodnotes(GoodNotesInk.Notebook, page: Int)
}

/// A page to draw on, in page points (PROTOCOL.md §10). `key` is what strokes and elements name it
/// by (a sketch page's id, or a file page's number). An endless canvas is one big page whose page
/// points are its view points minus `origin`, so ink can go anywhere.
struct InkPageSpec: Sendable {
    var key: String
    var width: Double
    var height: Double
    var background: InkBackground
    var origin: Double = 0
    var infinite: Bool { origin != 0 }

    /// The size of the endless canvas, in points (page points run from −origin to +origin).
    static let endlessSize = 16_000.0
}

/// A stroke as drawn: from a record, or a preview (moved by the lasso, cut by the eraser).
struct InkLine: Sendable, Identifiable {
    var id: String
    var tool: InkTool
    var color: String
    var width: Double
    var points: [InkPoint]
    var shape: String?
    /// Fill, dashes, arrowheads and nib angle (PROTOCOL.md §10).
    var style = InkStrokeStyle()
    /// Picked and moved with the rest of its group ("" for none).
    var group = ""
    /// A connector's joined ends ("" when free).
    var from = ""
    var to = ""

    init(id: String, tool: InkTool, color: String, width: Double, points: [InkPoint], shape: String? = nil, style: InkStrokeStyle = InkStrokeStyle()) {
        self.id = id; self.tool = tool; self.color = color; self.width = width; self.points = points; self.shape = shape; self.style = style
    }
    init(_ s: InkStroke) {
        self.init(id: s.id, tool: s.tool, color: s.color, width: s.width, points: s.points, shape: s.shape, style: s.style)
        group = s.group
        from = s.from
        to = s.to
    }

    func transformed(_ t: InkGeometry.Transform) -> InkLine {
        var out = self
        out.width = width * t.widthScale
        out.points = points.map { t.apply($0) }
        if let nib = style.nib, t.changesAngles { out.style.nib = t.angle(nib) }
        return out
    }
    var isConnector: Bool { !from.isEmpty || !to.isEmpty }
    var bounds: InkGeometry.Rect? { InkOutline.bounds(points, width: width, arrow: style.arrow) }
    /// Changes when how the line looks does (for a canvas deciding what to redraw).
    /// Positions count to 1/20 point, so a stroke read back from storage (float32 or compact points)
    /// stamps the same as the one just drawn, and the iPad canvas doesn't replace its drawing for it.
    var stamp: String {
        let a = points.first, b = points.last
        func q(_ v: Double?) -> Int { guard let v, v.isFinite else { return 0 }; return Int((max(-1e12, min(1e12, v)) * 20).rounded()) }
        return "\(color)|\(width)|\(tool.rawValue)|\(style.fill ?? "")\(style.dash ?? "")\(style.arrow ?? "")|\(points.count)|\(q(a?.x)),\(q(a?.y))|\(q(b?.x)),\(q(b?.y))"
    }
}

/// A text box, picture or tape strip as drawn.
struct InkBox: Sendable, Identifiable {
    var id: String
    var kind: InkElement.Kind
    var frame: InkGeometry.Rect
    var text: String
    var size: Double
    var color: String
    var image: Attachment?
    /// Radians, clockwise about the box's centre.
    var rotate: Double = 0
    /// A picture mirrored left to right.
    var flip = false
    var textStyle = InkTextStyle()
    var group = ""
    /// A text highlight's pieces on a PDF, in page points (PROTOCOL.md §10).
    var pieces: [InkGeometry.Rect] = []

    init(_ e: InkElement) {
        id = e.id; kind = e.kind; frame = e.frame; text = e.text; size = e.size; color = e.color; image = e.image
        rotate = e.rotate; flip = e.flip; textStyle = e.textStyle; group = e.group
        if kind == .highlight { pieces = e.highlightPieces }
    }

    /// A library element's box, for its preview.
    init(id: String, sticker e: InkStickerElement) {
        self.id = id
        kind = InkElement.Kind(rawValue: e.kind) ?? .text
        frame = InkGeometry.Rect(x: e.x, y: e.y, width: e.w, height: e.h)
        text = e.text; size = e.size; color = e.color; image = e.image.flatMap(Attachment.init(json:))
        rotate = e.rotate; flip = e.flip; textStyle = e.textStyle
    }

    /// Moved, resized, turned or flipped with the lasso (InkEditing.transform); text grows with it.
    func transformed(_ t: InkGeometry.Transform) -> InkBox {
        var b = self
        let next = InkEditing.transform(t, InkEditing.Frame(frame, rotate: rotate, flip: flip), image: kind == .image)
        b.frame = next.rect
        b.rotate = next.rotate
        b.flip = next.flip
        if kind == .text { b.size = size * t.widthScale }
        return b
    }
    /// Its box (unturned): a text box is as tall as its wrapped lines.
    var drawnFrame: InkGeometry.Rect {
        guard kind == .text else { return frame }
        var f = frame
        f.height = InkRenderer.textHeight(text, width: frame.width, size: size, style: textStyle)
        return f
    }
    /// The box, turn and mirroring as drawn, for hit tests.
    var editFrame: InkEditing.Frame { InkEditing.Frame(drawnFrame, rotate: rotate, flip: flip) }
    /// The upright box around it as drawn (turned boxes take more room).
    var drawnBounds: InkGeometry.Rect { InkEditing.bounds(editFrame) }
    func contains(_ p: InkPoint) -> Bool { InkEditing.contains(editFrame, p) }
}

/// Ink to draw on a page: strokes, plus text boxes and pictures with their images.
struct InkContent: @unchecked Sendable {
    var strokes: [InkLine] = []
    var elements: [InkBox] = []
    var pictures: [String: CGImage] = [:]
    /// Tape strips opened on this device.
    var peeked: Set<String> = []
}

/// Draws strokes, paper, backgrounds, text boxes and pictures with Core Graphics, the same on
/// iPhone, iPad and Mac and matching web/public/core/ink.js.
enum InkRenderer {
    // MARK: Pages

    /// The pages of a PDF or an image, sized like the website's (pdf.js at scale 1, image pixels).
    static func pages(for data: Data, mime: String, name: String = "") -> [InkPageSpec] {
        if name.lowercased().hasSuffix(".goodnotes") {
            guard let notebook = try? GoodNotesInk.read(data) else { return [] }
            return pages(goodnotes: notebook)
        }
        if mime == "application/pdf" {
            guard let provider = CGDataProvider(data: data as CFData), let doc = CGPDFDocument(provider) else { return [] }
            return (0..<doc.numberOfPages).compactMap { i in
                guard let page = doc.page(at: i + 1) else { return nil }
                let box = page.getBoxRect(.cropBox)
                let turned = abs(page.rotationAngle) % 180 == 90
                return InkPageSpec(key: String(i), width: turned ? box.height : box.width, height: turned ? box.width : box.height, background: .pdf(data, page: i))
            }
        }
        guard let image = cgImage(data) else { return [] }
        return [InkPageSpec(key: "0", width: Double(image.width), height: Double(image.height), background: .image(data))]
    }

    /// A GoodNotes notebook's pages, to draw on (PROTOCOL.md §10: ink on a file, page n = its page n).
    static func pages(goodnotes notebook: GoodNotesInk.Notebook) -> [InkPageSpec] {
        notebook.pages.enumerated().map { i, page in
            InkPageSpec(key: String(i), width: page.width, height: page.height, background: .goodnotes(notebook, page: i))
        }
    }

    /// A sketch's pages as the editor and previews see them.
    static func sketchPages(_ item: Item) -> [InkPageSpec] {
        if item.isInfiniteCanvas {
            let zero = item.sketchPageList.first { $0.id == "0" }
            let side = InkPageSpec.endlessSize
            return [InkPageSpec(key: "0", width: side, height: side, background: .paper(zero?.paper ?? item.paper, color: zero?.color), origin: side / 2)]
        }
        return item.sketchPageList.map {
            let own = item.pageSize(of: $0)
            return InkPageSpec(key: $0.id, width: own.width, height: own.height, background: .paper($0.paper ?? item.paper, color: $0.color))
        }
    }

    static func cgImage(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    // MARK: Rendering

    /// A page with its ink, `pixelWidth` wide. `area` (page points) picks part of an endless canvas.
    static func render(_ page: InkPageSpec, content: InkContent, pixelWidth: Int, area: InkGeometry.Rect? = nil, background: Bool = true) -> CGImage? {
        let box = area ?? InkGeometry.Rect(x: 0, y: 0, width: page.width, height: page.height)
        let k = Double(pixelWidth) / box.width
        let pxH = Int((box.height * k).rounded())
        guard pixelWidth > 0, pxH > 0, pixelWidth * pxH < 60_000_000,
              let ctx = CGContext(data: nil, width: pixelWidth, height: pxH, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // Top-left origin in page points, like the stroke coordinates.
        ctx.translateBy(x: 0, y: CGFloat(pxH))
        ctx.scaleBy(x: k, y: -k)
        ctx.translateBy(x: -box.x, y: -box.y)
        if background { drawBackground(page, area: area, in: ctx) }
        drawContent(content, in: ctx)
        return ctx.makeImage()
    }

    /// Text highlights, pictures under the ink, strokes, then text boxes on top (PROTOCOL.md §10).
    static func drawContent(_ content: InkContent, in ctx: CGContext) {
        drawHighlights(content.elements, in: ctx)
        drawPictures(content.elements, pictures: content.pictures, in: ctx)
        draw(content.strokes, in: ctx)
        drawTexts(content.elements, in: ctx)
        drawTapes(content.elements, peeked: content.peeked, in: ctx)
    }

    /// The background, into a context set up in page points with a top-left origin.
    static func drawBackground(_ page: InkPageSpec, area: InkGeometry.Rect? = nil, in ctx: CGContext) {
        let size = CGSize(width: page.width, height: page.height)
        switch page.background {
        case .paper(let paper, let color):
            let rect = area.map { CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) }
            // An endless canvas has no cue column or summary box: Cornell paper is lined there.
            drawPaper(paper, size: size, color: color, area: page.infinite ? rect : nil, in: ctx)
        case .pdf(let data, let index):
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(origin: .zero, size: size))
            guard let provider = CGDataProvider(data: data as CFData), let doc = CGPDFDocument(provider), let pdfPage = doc.page(at: index + 1) else { return }
            ctx.saveGState()
            // PDF drawing is bottom-up: flip back for it.
            ctx.translateBy(x: 0, y: size.height)
            ctx.scaleBy(x: 1, y: -1)
            ctx.concatenate(pdfPage.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: size), rotate: 0, preserveAspectRatio: true))
            ctx.drawPDFPage(pdfPage)
            ctx.restoreGState()
        case .image(let data):
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(origin: .zero, size: size))
            guard let image = cgImage(data) else { return }
            drawImage(image, in: CGRect(origin: .zero, size: size), ctx: ctx)
        case .goodnotes(let notebook, let index):
            guard notebook.pages.indices.contains(index) else { return }
            let sheet = notebook.pages[index]
            NotebookRenderer.draw(sheet, of: notebook, layers: GoodNotesInk.backgroundLayers(sheet), size: size, in: ctx)
        }
    }

    /// Paper like core/ink.js `drawPaper`: `InkPaperShapes` on the page's colour (lighter lines on
    /// dark pages). `area` limits it to what's on screen, for the endless canvas.
    static func drawPaper(_ paper: InkPaper, size: CGSize, color: String? = nil, area: CGRect? = nil, in ctx: CGContext) {
        let x0 = area?.minX ?? 0, y0 = area?.minY ?? 0, x1 = area?.maxX ?? size.width, y1 = area?.maxY ?? size.height
        let dark = InkPage.isDark(color)
        ctx.saveGState()
        ctx.setFillColor(cgColor(color ?? "#ffffff"))
        ctx.fill(CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0))
        let shapes = InkPaperShapes.shapes(paper, width: size.width, height: size.height,
                                           area: area.map { InkGeometry.Rect(x: $0.minX, y: $0.minY, width: $0.width, height: $0.height) })
        func rgba(_ r: Double, _ g: Double, _ b: Double, _ a: Double) -> CGColor { CGColor(red: r / 255, green: g / 255, blue: b / 255, alpha: a) }
        let colours: [InkPaperShapes.Role: CGColor] = dark
            ? [.line: rgba(200, 215, 240, 0.22), .bold: rgba(200, 215, 240, 0.4), .accent: rgba(240, 150, 150, 0.5)]
            : [.line: rgba(90, 130, 200, 0.28), .bold: rgba(90, 130, 200, 0.5), .accent: rgba(220, 90, 90, 0.55)]
        ctx.setLineWidth(1)
        for role in [InkPaperShapes.Role.line, .bold, .accent] {
            var any = false
            for shape in shapes {
                switch shape {
                case .hline(let y, let a, let b, let r) where r == role:
                    ctx.move(to: CGPoint(x: a, y: y)); ctx.addLine(to: CGPoint(x: b, y: y)); any = true
                case .vline(let x, let a, let b, let r) where r == role:
                    ctx.move(to: CGPoint(x: x, y: a)); ctx.addLine(to: CGPoint(x: x, y: b)); any = true
                case .box(let x, let y, let w, let h, let r) where r == role:
                    ctx.addRect(CGRect(x: x, y: y, width: w, height: h)); any = true
                default:
                    break
                }
            }
            if any { ctx.setStrokeColor(colours[role] ?? rgba(90, 130, 200, 0.28)); ctx.strokePath() }
        }
        ctx.setFillColor(dark ? rgba(210, 220, 235, 0.4) : rgba(90, 110, 140, 0.45))
        for case .dot(let x, let y, let d) in shapes { ctx.addEllipse(in: CGRect(x: x - d, y: y - d, width: d * 2, height: d * 2)) }
        ctx.fillPath()
        ctx.restoreGState()
    }

    static func cgColor(_ hex: String, alpha: Double = 1) -> CGColor {
        let (r, g, b) = InkStroke.rgb(hex)
        return CGColor(red: r, green: g, blue: b, alpha: alpha)
    }

    /// An image the right way up in a top-left-origin context.
    static func drawImage(_ image: CGImage, in rect: CGRect, ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(origin: .zero, size: rect.size))
        ctx.restoreGState()
    }

    // MARK: Strokes

    static func draw(_ strokes: [InkLine], in ctx: CGContext) {
        for s in strokes { draw(tool: s.tool, color: s.color, width: s.width, points: s.points, shapeName: s.shape, style: s.style, in: ctx) }
    }

    /// A line being drawn or a laser line: `shape` draws it as straight pieces.
    static func draw(tool: InkTool, color: String, width: Double, points pts: [InkPoint], shape: Bool = false, style: InkStrokeStyle = InkStrokeStyle(), in ctx: CGContext) {
        draw(tool: tool, color: color, width: width, points: pts, shapeName: shape ? "polyline" : nil, style: style, in: ctx)
    }

    /// One stroke, like core/ink.js `drawStroke`: pens, pencils, fountain pens and brushes as one
    /// filled outline (`InkOutline.outline`; pencils with grain); markers, highlighters, clean shapes
    /// and dashed lines as one even line (highlighters blended under the ink). Closed shapes with a
    /// fill are filled underneath; line shapes get their arrowheads.
    static func draw(tool: InkTool, color: String, width: Double, points pts: [InkPoint], shapeName: String?, style: InkStrokeStyle, in ctx: CGContext) {
        guard let first = pts.first else { return }
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setAlpha(tool.opacity)
        if tool == .highlighter { ctx.setBlendMode(.multiply) }
        if let fill = style.fill, let shape = shapeName, InkStrokeStyle.closedShapes.contains(shape), pts.count > 2 {
            ctx.setFillColor(cgColor(fill))
            ctx.addLines(between: pts.map { CGPoint(x: $0.x, y: $0.y) })
            ctx.closePath()
            ctx.fillPath()
        }
        if let outline = InkOutline.outline(tool: tool, width: width, points: pts, shape: shapeName, style: style) {
            let path = outlinePath(outline)
            if tool == .pencil, let grain = grainImage(color) {
                ctx.saveGState()
                ctx.addPath(path)
                ctx.clip()
                // The grain repeats every 32 page points (a texel per half point), like the website.
                let tile = CGFloat(InkOutline.grainSize) * CGFloat(InkOutline.grainTexel)
                let box = path.boundingBoxOfPath
                var y = (box.minY / tile).rounded(.down) * tile
                while y < box.maxY {
                    var x = (box.minX / tile).rounded(.down) * tile
                    while x < box.maxX {
                        ctx.draw(grain, in: CGRect(x: x, y: y, width: tile, height: tile))
                        x += tile
                    }
                    y += tile
                }
                ctx.restoreGState()
            } else {
                ctx.setFillColor(cgColor(color))
                ctx.addPath(path)
                ctx.fillPath()
            }
            return
        }
        ctx.setStrokeColor(cgColor(color))
        ctx.setFillColor(cgColor(color))
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        let w = InkOutline.lineWidth(tool: tool, width: width, points: pts)
        if pts.count == 1 {
            ctx.fillEllipse(in: CGRect(x: first.x - w / 2, y: first.y - w / 2, width: w, height: w))
            return
        }
        let arrow = tool == .highlighter ? nil : style.arrow
        let heads = InkOutline.arrowHeads(tool: tool, width: width, points: pts, shape: shapeName, arrow: arrow)
        var line = pts
        if let arrow, !heads.isEmpty { line = InkOutline.trimmedForArrows(pts, width: w, arrow: arrow) }
        if let dash = style.dash { ctx.setLineDash(phase: 0, lengths: InkOutline.dashPattern(dash, width: w).map { CGFloat($0) }) }
        ctx.setLineWidth(w)
        ctx.move(to: CGPoint(x: line[0].x, y: line[0].y))
        if shapeName != nil {
            for p in line.dropFirst() { ctx.addLine(to: CGPoint(x: p.x, y: p.y)) }
        } else {
            for i in 1..<(line.count - 1) {
                let to = CGPoint(x: (line[i].x + line[i + 1].x) / 2, y: (line[i].y + line[i + 1].y) / 2)
                ctx.addQuadCurve(to: to, control: CGPoint(x: line[i].x, y: line[i].y))
            }
            ctx.addLine(to: CGPoint(x: line[line.count - 1].x, y: line[line.count - 1].y))
        }
        ctx.strokePath()
        ctx.setLineDash(phase: 0, lengths: [])
        for tri in heads where tri.count == 3 {
            ctx.addLines(between: tri.map { CGPoint(x: $0.x, y: $0.y) })
            ctx.closePath()
            ctx.fillPath()
        }
    }

    /// An outline as quadratic curves through its corners' midpoints (ink.js `traceOutline`).
    static func outlinePath(_ o: [InkPoint]) -> CGPath {
        let path = CGMutablePath()
        let n = o.count
        guard n >= 3 else { return path }
        path.move(to: CGPoint(x: (o[n - 1].x + o[0].x) / 2, y: (o[n - 1].y + o[0].y) / 2))
        for i in 0..<n {
            let b = o[(i + 1) % n]
            path.addQuadCurve(to: CGPoint(x: (o[i].x + b.x) / 2, y: (o[i].y + b.y) / 2), control: CGPoint(x: o[i].x, y: o[i].y))
        }
        path.closeSubpath()
        return path
    }

    /// The pencil's grain tile in a colour (`InkOutline.grainTile` as alpha), made once per colour.
    private static let grainCache = GrainCache()
    static func grainImage(_ color: String) -> CGImage? { grainCache.image(color) }

    /// Tape, like GoodNotes: a strip with torn ends and faint stripes; tapped open (on this device)
    /// it turns see-through so what's under it shows, and a tap covers it again.
    static func drawTape(_ f: InkGeometry.Rect, color: String, peeked: Bool, in ctx: CGContext) {
        let path = tapePath(f)
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setFillColor(cgColor(color, alpha: peeked ? 0.3 : 1))
        ctx.addPath(path)
        ctx.fillPath()
        if peeked {
            ctx.setStrokeColor(cgColor(color, alpha: 0.8))
            ctx.setLineWidth(0.75)
            ctx.addPath(path)
            ctx.strokePath()
        }
        ctx.addPath(path)
        ctx.clip()
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: peeked ? 0.04 : 0.1))
        let step = 8.0
        var x = f.x - f.height
        while x < f.x + f.width {
            ctx.move(to: CGPoint(x: x, y: f.y))
            ctx.addLine(to: CGPoint(x: x + step, y: f.y))
            ctx.addLine(to: CGPoint(x: x + step + f.height, y: f.y + f.height))
            ctx.addLine(to: CGPoint(x: x + f.height, y: f.y + f.height))
            ctx.closePath()
            x += step * 2
        }
        ctx.fillPath()
    }

    /// The strip's outline: straight sides and zigzag (torn) ends.
    static func tapePath(_ f: InkGeometry.Rect) -> CGPath {
        let p = CGMutablePath()
        let depth = min(3, f.width / 6)
        let teeth = max(2, Int((f.height / 5).rounded()))
        let tooth = f.height / Double(teeth)
        p.move(to: CGPoint(x: f.x, y: f.y))
        p.addLine(to: CGPoint(x: f.maxX, y: f.y))
        // Right end, top to bottom.
        for i in 0..<teeth {
            let y = f.y + Double(i) * tooth
            p.addLine(to: CGPoint(x: f.maxX - depth, y: y + tooth / 2))
            p.addLine(to: CGPoint(x: f.maxX, y: y + tooth))
        }
        p.addLine(to: CGPoint(x: f.x, y: f.maxY))
        // Left end, bottom to top.
        for i in 0..<teeth {
            let y = f.maxY - Double(i) * tooth
            p.addLine(to: CGPoint(x: f.x + depth, y: y - tooth / 2))
            p.addLine(to: CGPoint(x: f.x, y: y - tooth))
        }
        p.closeSubpath()
        return p
    }

    /// Text highlights on a PDF: like the highlighter (35 %, multiplied), under the ink.
    static func drawHighlights(_ elements: [InkBox], in ctx: CGContext) {
        let highlights = elements.filter { $0.kind == .highlight }
        guard !highlights.isEmpty else { return }
        ctx.saveGState()
        ctx.setBlendMode(.multiply)
        for e in highlights {
            ctx.setFillColor(cgColor(e.color, alpha: 0.35))
            for r in e.pieces { ctx.fill(CGRect(x: r.x, y: r.y, width: r.width, height: r.height)) }
        }
        ctx.restoreGState()
    }

    /// Tape strips go over everything else on a page.
    static func drawTapes(_ elements: [InkBox], peeked: Set<String> = [], in ctx: CGContext) {
        for e in elements where e.kind == .tape {
            withElementTransform(e, in: ctx) { drawTape(e.frame, color: e.color, peeked: peeked.contains(e.id), in: ctx) }
        }
    }

    /// Runs `body` with the context turned about the element's centre by its `rotate` (and a
    /// picture mirrored when it has `flip`), so `body` draws the unturned box (ink.js `withElementTransform`).
    static func withElementTransform(_ e: InkBox, in ctx: CGContext, _ body: () -> Void) {
        let mirrored = e.flip && e.kind == .image
        guard e.rotate != 0 || mirrored else { body(); return }
        let cx = CGFloat(e.frame.x + e.frame.width / 2), cy = CGFloat(e.frame.y + e.frame.height / 2)
        ctx.saveGState()
        ctx.translateBy(x: cx, y: cy)
        if e.rotate != 0 { ctx.rotate(by: CGFloat(e.rotate)) }
        if mirrored { ctx.scaleBy(x: -1, y: 1) }
        ctx.translateBy(x: -cx, y: -cy)
        body()
        ctx.restoreGState()
    }

    // MARK: Text boxes and pictures

    static func drawPictures(_ elements: [InkBox], pictures: [String: CGImage], in ctx: CGContext) {
        for e in elements where e.kind == .image {
            guard let id = e.image?.id, let image = pictures[id] else { continue }
            let f = e.frame
            withElementTransform(e, in: ctx) { drawImage(image, in: CGRect(x: f.x, y: f.y, width: f.width, height: f.height), ctx: ctx) }
        }
    }

    static func drawTexts(_ elements: [InkBox], in ctx: CGContext) {
        for e in elements where e.kind == .text {
            withElementTransform(e, in: ctx) { drawText(e.text, frame: e.frame, size: e.size, color: e.color, style: e.textStyle, in: ctx) }
        }
    }

    /// A text box's font: the system font (`sans`), or Georgia, Menlo or a rounded face, bold and
    /// italic as asked (ink.js `textFont`).
    static func font(size: Double, style: InkTextStyle) -> CTFont {
        let base: CTFont
        switch style.font {
        case .sans: base = CTFontCreateUIFontForLanguage(.system, size, nil) ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        case .serif: base = CTFontCreateWithName("Georgia" as CFString, size, nil)
        case .mono: base = CTFontCreateWithName("Menlo" as CFString, size, nil)
        case .rounded: base = CTFontCreateWithName("Arial Rounded MT Bold" as CFString, size, nil)
        }
        // kCTFontItalicTrait is 1 << 0 and kCTFontBoldTrait 1 << 1.
        var traits: UInt32 = 0
        if style.italic { traits |= 1 }
        if style.bold { traits |= 2 }
        guard traits != 0 else { return base }
        let wanted = CTFontSymbolicTraits(rawValue: traits)
        return CTFontCreateCopyWithSymbolicTraits(base, size, nil, wanted, wanted) ?? base
    }

    /// The text box's font at `size`, lines 1.25 × size apart, wrapped to the box's width (ink.js `drawTextElement`).
    static func attributed(_ text: String, size: Double, color: String, style: InkTextStyle = InkTextStyle()) -> NSAttributedString {
        let font = Self.font(size: size, style: style)
        let lineHeight = CGFloat(size * 1.25)
        // The settings point at lineHeight, so the style is made while that pointer is valid.
        let style: CTParagraphStyle = withUnsafePointer(to: lineHeight) { pointer in
            let settings = [
                CTParagraphStyleSetting(spec: .minimumLineHeight, valueSize: MemoryLayout<CGFloat>.size, value: pointer),
                CTParagraphStyleSetting(spec: .maximumLineHeight, valueSize: MemoryLayout<CGFloat>.size, value: pointer),
            ]
            return CTParagraphStyleCreate(settings, settings.count)
        }
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): cgColor(color),
            NSAttributedString.Key(kCTParagraphStyleAttributeName as String): style,
        ]
        return NSAttributedString(string: text, attributes: attributes)
    }

    /// How tall a text box is once its words wrap.
    static func textHeight(_ text: String, width: Double, size: Double, style: InkTextStyle = InkTextStyle()) -> Double {
        let setter = CTFramesetterCreateWithAttributedString(attributed(text.isEmpty ? " " : text, size: size, color: "#000000", style: style))
        let fit = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(location: 0, length: 0), nil,
                                                               CGSize(width: width, height: .greatestFiniteMagnitude), nil)
        return max(size * 1.25, Double(fit.height))
    }

    static func drawText(_ text: String, frame f: InkGeometry.Rect, size: Double, color: String, style: InkTextStyle = InkTextStyle(), in ctx: CGContext) {
        guard !text.isEmpty else { return }
        let height = textHeight(text, width: f.width, size: size, style: style) + size
        let setter = CTFramesetterCreateWithAttributedString(attributed(text, size: size, color: color, style: style))
        let path = CGPath(rect: CGRect(x: 0, y: 0, width: f.width, height: height), transform: nil)
        let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), path, nil)
        ctx.saveGState()
        // Core Text draws bottom-up: flip just for the box.
        ctx.translateBy(x: f.x, y: f.y + height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textMatrix = .identity
        CTFrameDraw(frame, ctx)
        ctx.restoreGState()
    }

    // MARK: Files

    /// A JPEG of a picture (thumbnails, PDF export).
    static func jpeg(_ image: CGImage, quality: Double = 0.82) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    /// A JPEG of a sketch's first page (or all of an endless one) for its card.
    static func thumbnailJPEG(_ page: InkPageSpec, content: InkContent, bounds: InkGeometry.Rect?) -> Data? {
        var area: InkGeometry.Rect?
        if page.infinite {
            let b = bounds ?? InkGeometry.Rect(x: 0, y: 0, width: 768, height: 1024)
            area = InkGeometry.Rect(x: b.x - 24, y: b.y - 24, width: max(200, b.width + 48), height: min(max(150, b.height + 48), max(200, b.width + 48) * 1.5))
        }
        guard let image = render(page, content: content, pixelWidth: 480, area: area) else { return nil }
        return jpeg(image)
    }

    /// The whole drawing as a PDF: vector paper, ink and text over the file's pages or pictures.
    static func pdf(pages: [(spec: InkPageSpec, content: InkContent, bounds: InkGeometry.Rect?)]) -> Data? {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else { return nil }
        var media = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let ctx = CGContext(consumer: consumer, mediaBox: &media, nil) else { return nil }
        for page in pages {
            var box = InkGeometry.Rect(x: 0, y: 0, width: page.spec.width, height: page.spec.height)
            if page.spec.infinite {
                let b = page.bounds ?? InkGeometry.Rect(x: 0, y: 0, width: 768, height: 1024)
                box = InkGeometry.Rect(x: b.x - 36, y: b.y - 36, width: b.width + 72, height: b.height + 72)
            }
            var rect = CGRect(x: 0, y: 0, width: box.width, height: box.height)
            ctx.beginPage(mediaBox: &rect)
            ctx.translateBy(x: 0, y: box.height)
            ctx.scaleBy(x: 1, y: -1)
            ctx.translateBy(x: -box.x, y: -box.y)
            drawBackground(page.spec, area: page.spec.infinite ? box : nil, in: ctx)
            drawContent(page.content, in: ctx)
            ctx.endPage()
        }
        ctx.closePDF()
        return data as Data
    }
}

struct InkImage: @unchecked Sendable {
    let image: CGImage
}

/// What's drawn over the ink while a tool works: the lasso's loop, the selection's box and corner
/// handles, the eraser's circle (ink.js draws the same on the website).
struct InkOverlay {
    var lasso: [InkPoint] = []
    var selection: InkGeometry.Rect?
    var eraser: InkPoint?
    var eraserRadius = 10.0
    /// Laser pointer lines: points, colour, width in screen points, and how faded (1 = solid).
    var lasers: [(points: [InkPoint], color: String, width: Double, alpha: Double)] = []
    /// Tape being laid.
    var tape: (frame: InkGeometry.Rect, rotate: Double, color: String)?
    /// A hovering Apple Pencil's tip: where, in the pen's colour and size.
    var tip: (point: InkPoint, color: String, width: Double)?
    /// The selection's turning handle (above its box), and the turn while it's dragged (degrees).
    var rotateHandle = false
    var turning: Double?
    /// A lone clean shape's own handles (its ends, corners or bend); `roundMiddle`: the third is a line's middle.
    var handles: [InkPoint] = []
    var roundMiddle = false
    /// A shape being dragged out with the shape tool, or reshaped by a handle.
    var preview: InkLine?
    /// The ruler and protractor (this device only), and where the pen is for the protractor's reading.
    var ruler: InkEditing.Guide?
    var protractor: InkEditing.Guide?
    var reading: InkPoint?
}

extension InkRenderer {
    /// `scale` is screen points per page point, so lines and handles keep their size on screen.
    static func drawOverlay(_ o: InkOverlay, scale: Double, in ctx: CGContext) {
        let px = CGFloat(1 / max(0.05, scale))
        let blue = CGColor(red: 10 / 255, green: 132 / 255, blue: 1, alpha: 0.95)
        ctx.saveGState()
        if o.lasso.count > 1 {
            ctx.setLineWidth(1.5 * px)
            ctx.setStrokeColor(blue)
            ctx.setFillColor(CGColor(red: 10 / 255, green: 132 / 255, blue: 1, alpha: 0.06))
            ctx.setLineDash(phase: 0, lengths: [6 * px, 5 * px])
            ctx.addLines(between: o.lasso.map { CGPoint(x: $0.x, y: $0.y) })
            ctx.closePath()
            ctx.drawPath(using: .fillStroke)
        }
        if let line = o.preview { draw([line], in: ctx) }
        if let b = o.selection {
            ctx.setLineWidth(1.5 * px)
            ctx.setStrokeColor(blue)
            ctx.setLineDash(phase: 0, lengths: [5 * px, 4 * px])
            ctx.stroke(CGRect(x: b.x, y: b.y, width: b.width, height: b.height))
            ctx.setLineDash(phase: 0, lengths: [])
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            for (x, y) in [(b.x, b.y), (b.maxX, b.y), (b.maxX, b.maxY), (b.x, b.maxY)] {
                let r = 6 * px
                let dot = CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)
                ctx.fillEllipse(in: dot)
                ctx.strokeEllipse(in: dot)
            }
            if o.rotateHandle {
                // The turning handle: a knob above the middle of the top edge.
                let knob = rotateHandle(b, scale: scale)
                let kx = CGFloat(knob.x), ky = CGFloat(knob.y)
                ctx.move(to: CGPoint(x: kx, y: CGFloat(b.y)))
                ctx.addLine(to: CGPoint(x: kx, y: ky + 7 * px))
                ctx.strokePath()
                let r = 7 * px
                let dot = CGRect(x: kx - r, y: ky - r, width: r * 2, height: r * 2)
                ctx.fillEllipse(in: dot)
                ctx.strokeEllipse(in: dot)
                if let degrees = o.turning {
                    drawLabel("\(Int(degrees.rounded()))°", at: CGPoint(x: kx, y: ky - 16 * px), size: 12 * px, color: blue, in: ctx)
                }
            }
        }
        if !o.handles.isEmpty {
            ctx.setLineDash(phase: 0, lengths: [])
            ctx.setLineWidth(1.5 * px)
            ctx.setStrokeColor(blue)
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            for (i, h) in o.handles.enumerated() {
                let r = 5 * px
                let rect = CGRect(x: CGFloat(h.x) - r, y: CGFloat(h.y) - r, width: r * 2, height: r * 2)
                if i == 2 && o.roundMiddle {
                    ctx.fillEllipse(in: rect)
                    ctx.strokeEllipse(in: rect)
                } else {
                    ctx.fill(rect)
                    ctx.stroke(rect)
                }
            }
        }
        if o.ruler != nil || o.protractor != nil { drawGuides(ruler: o.ruler, protractor: o.protractor, reading: o.reading, scale: scale, in: ctx) }
        for l in o.lasers where l.alpha > 0 { drawLaser(l.points, color: l.color, width: l.width * Double(px), alpha: l.alpha, in: ctx) }
        if let t = o.tape {
            let cx = CGFloat(t.frame.x + t.frame.width / 2), cy = CGFloat(t.frame.y + t.frame.height / 2)
            ctx.saveGState()
            ctx.translateBy(x: cx, y: cy)
            ctx.rotate(by: CGFloat(t.rotate))
            ctx.translateBy(x: -cx, y: -cy)
            drawTape(t.frame, color: t.color, peeked: false, in: ctx)
            ctx.restoreGState()
        }
        if let tip = o.tip {
            // The pen's tip, its colour and size, with a thin ring so it shows on any paper.
            let r = max(1.5 * Double(px), tip.width / 2)
            let dot = CGRect(x: tip.point.x - r, y: tip.point.y - r, width: r * 2, height: r * 2)
            ctx.setLineDash(phase: 0, lengths: [])
            ctx.setFillColor(cgColor(tip.color, alpha: 0.75))
            ctx.fillEllipse(in: dot)
            ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.9))
            ctx.setLineWidth(1 * px)
            ctx.strokeEllipse(in: dot.insetBy(dx: -px, dy: -px))
        }
        if let e = o.eraser {
            ctx.setLineDash(phase: 0, lengths: [])
            ctx.setLineWidth(1.5 * px)
            ctx.setStrokeColor(CGColor(red: 120 / 255, green: 120 / 255, blue: 128 / 255, alpha: 0.9))
            ctx.strokeEllipse(in: CGRect(x: e.x - o.eraserRadius, y: e.y - o.eraserRadius, width: o.eraserRadius * 2, height: o.eraserRadius * 2))
        }
        ctx.restoreGState()
    }
}

extension InkRenderer {
    /// The laser pointer: a wide soft glow in its colour, a brighter band, and a near-white hot core,
    /// so it reads like light on the page. `width` is in page points for the line's screen size.
    static func drawLaser(_ points: [InkPoint], color: String, width: Double, alpha: Double, in ctx: CGContext) {
        guard let first = points.first else { return }
        let path = CGMutablePath()
        path.move(to: CGPoint(x: first.x, y: first.y))
        if points.count == 1 { path.addLine(to: CGPoint(x: first.x + 0.01, y: first.y)) }
        for p in points.dropFirst() { path.addLine(to: CGPoint(x: p.x, y: p.y)) }
        let glow = cgColor(color)
        // (line width × width, colour, its alpha, blur in screen points)
        let passes: [(Double, CGColor, Double, CGFloat)] = [
            (3.2, glow, 0.22, 26),
            (1.7, glow, 0.55, 14),
            (1, glow, 1, 6),
            (0.42, CGColor(red: 1, green: 1, blue: 1, alpha: 1), 0.92, 3),
        ]
        ctx.saveGState()
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setLineDash(phase: 0, lengths: [])
        for pass in passes {
            ctx.saveGState()
            ctx.setAlpha(alpha * pass.2)
            ctx.setShadow(offset: .zero, blur: pass.3, color: glow)
            ctx.setStrokeColor(pass.1)
            ctx.setLineWidth(CGFloat(width * pass.0))
            ctx.addPath(path)
            ctx.strokePath()
            ctx.restoreGState()
        }
        ctx.restoreGState()
    }

    /// Where the selection's turning handle sits: above the middle of its top edge (26 screen points up).
    static func rotateHandle(_ b: InkGeometry.Rect, scale: Double) -> InkPoint {
        InkPoint(x: b.x + b.width / 2, y: b.y - 26 / max(0.05, scale))
    }

    /// A short label centred on a point in a top-left-origin context.
    static func drawLabel(_ text: String, at p: CGPoint, size: CGFloat, color: CGColor, in ctx: CGContext) {
        let font = CTFontCreateUIFontForLanguage(.system, size, nil) ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        ctx.saveGState()
        ctx.translateBy(x: p.x, y: p.y)
        // Core Text draws bottom-up.
        ctx.scaleBy(x: 1, y: -1)
        ctx.textMatrix = .identity
        ctx.textPosition = CGPoint(x: -CGFloat(width) / 2, y: -size * 0.35)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    /// The ruler and protractor, see-through with ticks, their angle in the middle and round knobs to
    /// turn them (web/public/drawedit.js `drawGuides`). `reading`: the pen, whose angle the protractor shows.
    static func drawGuides(ruler: InkEditing.Guide?, protractor: InkEditing.Guide?, reading: InkPoint?, scale: Double, in ctx: CGContext) {
        let px = CGFloat(1 / max(0.05, scale))
        let body = CGColor(red: 200 / 255, green: 205 / 255, blue: 215 / 255, alpha: 0.55)
        let edge = CGColor(red: 60 / 255, green: 64 / 255, blue: 72 / 255, alpha: 0.8)
        let ink = CGColor(red: 30 / 255, green: 32 / 255, blue: 36 / 255, alpha: 0.9)
        let white = CGColor(red: 1, green: 1, blue: 1, alpha: 0.9)
        ctx.saveGState()
        ctx.setLineDash(phase: 0, lengths: [])
        ctx.setLineWidth(px)
        if let g = ruler {
            let half = CGFloat(g.length / 2), w = CGFloat(g.width / 2)
            ctx.saveGState()
            ctx.translateBy(x: CGFloat(g.x), y: CGFloat(g.y))
            ctx.rotate(by: CGFloat(g.angle))
            let rect = CGRect(x: -half, y: -w, width: half * 2, height: w * 2)
            ctx.setFillColor(body)
            ctx.fill(rect)
            ctx.setStrokeColor(edge)
            ctx.stroke(rect)
            var u = -half + 8
            var i = 1
            while u < half {
                let long: CGFloat = i % 5 == 0 ? 12 : 6
                ctx.move(to: CGPoint(x: u, y: -w)); ctx.addLine(to: CGPoint(x: u, y: -w + long))
                ctx.move(to: CGPoint(x: u, y: w)); ctx.addLine(to: CGPoint(x: u, y: w - long))
                u += 8
                i += 1
            }
            ctx.strokePath()
            for side in [CGFloat(-1), 1] {
                let r = 9 * px
                let knob = CGRect(x: side * (half - CGFloat(guideKnob)) - r, y: -r, width: r * 2, height: r * 2)
                ctx.setFillColor(white)
                ctx.fillEllipse(in: knob)
                ctx.strokeEllipse(in: knob)
            }
            drawLabel("\(Int(InkEditing.degrees(g.angle).rounded()))°", at: .zero, size: 12 * px, color: ink, in: ctx)
            ctx.restoreGState()
        }
        if let g = protractor {
            let r = CGFloat(g.radius)
            ctx.saveGState()
            ctx.translateBy(x: CGFloat(g.x), y: CGFloat(g.y))
            ctx.rotate(by: CGFloat(g.angle))
            ctx.move(to: CGPoint(x: -r, y: 0))
            ctx.addArc(center: .zero, radius: r, startAngle: .pi, endAngle: .pi * 2, clockwise: false)
            ctx.closePath()
            ctx.setFillColor(body)
            ctx.setStrokeColor(edge)
            ctx.drawPath(using: .fillStroke)
            var d = 0
            while d <= 180 {
                let a = -CGFloat(d) * .pi / 180
                let long: CGFloat = d % 30 == 0 ? 16 : (d % 10 == 0 ? 10 : 5)
                ctx.move(to: CGPoint(x: r * cos(a), y: r * sin(a)))
                ctx.addLine(to: CGPoint(x: (r - long) * cos(a), y: (r - long) * sin(a)))
                d += 5
            }
            ctx.move(to: CGPoint(x: -4, y: 0)); ctx.addLine(to: CGPoint(x: 4, y: 0))
            ctx.move(to: CGPoint(x: 0, y: -4)); ctx.addLine(to: CGPoint(x: 0, y: 4))
            ctx.strokePath()
            var label = 0
            while label <= 180 {
                let a = -CGFloat(label) * .pi / 180
                drawLabel("\(label)", at: CGPoint(x: (r - 28) * cos(a), y: (r - 28) * sin(a)), size: 10 * px, color: ink, in: ctx)
                label += 30
            }
            for side in [CGFloat(-1), 1] {
                let k = 9 * px
                let knob = CGRect(x: side * (r - CGFloat(guideKnob)) - k, y: 10 - k, width: k * 2, height: k * 2)
                ctx.setFillColor(white)
                ctx.fillEllipse(in: knob)
                ctx.strokeEllipse(in: knob)
            }
            let shown = reading.map { InkEditing.protractorDegrees(g, $0) } ?? InkEditing.degrees(g.angle)
            drawLabel("\(Int(shown.rounded()))°", at: CGPoint(x: 0, y: -r * 0.45), size: 13 * px, color: ink, in: ctx)
            ctx.restoreGState()
            if let p = reading {
                // The line from the centre to the pen, whose angle is shown.
                ctx.setStrokeColor(CGColor(red: 10 / 255, green: 132 / 255, blue: 1, alpha: 0.9))
                ctx.setLineWidth(1.5 * px)
                ctx.move(to: CGPoint(x: g.x, y: g.y))
                ctx.addLine(to: CGPoint(x: p.x, y: p.y))
                ctx.strokePath()
            }
        }
        ctx.restoreGState()
    }

    /// Page points from a guide's end to its turning knob.
    static let guideKnob = 20.0

    /// A picture of some ink on a clear background (Copy as image), `scale` pixels a page point.
    static func renderSelection(_ content: InkContent, box: InkGeometry.Rect, scale: Double, whiteBackground: Bool = false) -> CGImage? {
        let w = Int((box.width * scale).rounded(.up)), h = Int((box.height * scale).rounded(.up))
        guard w > 0, h > 0, w * h < 40_000_000,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        if whiteBackground {
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
        ctx.translateBy(x: -box.x, y: -box.y)
        var c = content
        // Copied tape shows what it covers' outline only.
        c.peeked = Set(content.elements.map(\.id))
        drawContent(c, in: ctx)
        return ctx.makeImage()
    }

    /// PNG bytes of a picture.
    static func png(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }
}

/// Grain tiles per colour for pencils, made once (rendering runs on more than one thread).
final class GrainCache: @unchecked Sendable {
    private let lock = NSLock()
    private var images: [String: CGImage] = [:]

    func image(_ color: String) -> CGImage? {
        lock.lock()
        defer { lock.unlock() }
        if let hit = images[color] { return hit }
        let size = InkOutline.grainSize
        let (r, g, b) = InkStroke.rgb(color)
        var bytes = [UInt8](repeating: 0, count: size * size * 4)
        for (i, a) in InkOutline.grainTile.enumerated() {
            let alpha = Double(a) / 255
            // Premultiplied alpha.
            bytes[i * 4] = UInt8(min(255, (r * alpha * 255).rounded()))
            bytes[i * 4 + 1] = UInt8(min(255, (g * alpha * 255).rounded()))
            bytes[i * 4 + 2] = UInt8(min(255, (b * alpha * 255).rounded()))
            bytes[i * 4 + 3] = a
        }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info, provider: provider, decode: nil,
                                  shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        if images.count > 32 { images = [:] }
        images[color] = image
        return image
    }
}
