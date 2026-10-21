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

    init(id: String, tool: InkTool, color: String, width: Double, points: [InkPoint], shape: String? = nil) {
        self.id = id; self.tool = tool; self.color = color; self.width = width; self.points = points; self.shape = shape
    }
    init(_ s: InkStroke) { self.init(id: s.id, tool: s.tool, color: s.color, width: s.width, points: s.points, shape: s.shape) }

    func transformed(_ t: InkGeometry.Transform) -> InkLine {
        InkLine(id: id, tool: tool, color: color, width: width * t.widthScale, points: points.map { t.apply($0) }, shape: shape)
    }
    var bounds: InkGeometry.Rect? { InkGeometry.bounds(points, pad: width / 2) }
    /// Changes when how the line looks does (for a canvas deciding what to redraw).
    var stamp: String {
        let a = points.first, b = points.last
        return "\(color)|\(width)|\(tool.rawValue)|\(points.count)|\(a?.x ?? 0),\(a?.y ?? 0)|\(b?.x ?? 0),\(b?.y ?? 0)"
    }
}

/// A text box or picture as drawn.
struct InkBox: Sendable, Identifiable {
    var id: String
    var kind: InkElement.Kind
    var frame: InkGeometry.Rect
    var text: String
    var size: Double
    var color: String
    var image: Attachment?

    init(_ e: InkElement) { id = e.id; kind = e.kind; frame = e.frame; text = e.text; size = e.size; color = e.color; image = e.image }

    func transformed(_ t: InkGeometry.Transform) -> InkBox {
        var b = self
        b.frame = t.apply(frame)
        if kind == .text { b.size = size * t.widthScale }
        return b
    }
    /// Its box as drawn: a text box is as tall as its wrapped lines.
    var drawnFrame: InkGeometry.Rect {
        guard kind == .text else { return frame }
        var f = frame
        f.height = InkRenderer.textHeight(text, width: frame.width, size: size)
        return f
    }
}

/// Ink to draw on a page: strokes, plus text boxes and pictures with their images.
struct InkContent: @unchecked Sendable {
    var strokes: [InkLine] = []
    var elements: [InkBox] = []
    var pictures: [String: CGImage] = [:]
}

/// Draws strokes, paper, backgrounds, text boxes and pictures with Core Graphics, the same on
/// iPhone, iPad and Mac and matching web/public/core/ink.js.
enum InkRenderer {
    // MARK: Pages

    /// The pages of a PDF or an image, sized like the website's (pdf.js at scale 1, image pixels).
    static func pages(for data: Data, mime: String) -> [InkPageSpec] {
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

    /// Pictures under the ink, strokes, then text boxes on top (PROTOCOL.md §10).
    static func drawContent(_ content: InkContent, in ctx: CGContext) {
        drawPictures(content.elements, pictures: content.pictures, in: ctx)
        draw(content.strokes, in: ctx)
        drawTexts(content.elements, in: ctx)
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
        for s in strokes { draw(tool: s.tool, color: s.color, width: s.width, points: s.points, shape: s.shape != nil, in: ctx) }
    }

    /// One stroke, like core/ink.js: pens, fountain pens and brushes vary in width segment by
    /// segment; markers, highlighters, pencils and clean shapes are one even line (highlighters
    /// blended under the ink).
    static func draw(tool: InkTool, color: String, width: Double, points pts: [InkPoint], shape: Bool = false, in ctx: CGContext) {
        guard let first = pts.first else { return }
        ctx.saveGState()
        ctx.setAlpha(tool.opacity)
        ctx.setStrokeColor(cgColor(color))
        ctx.setFillColor(cgColor(color))
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        if tool == .highlighter { ctx.setBlendMode(.multiply) }
        func mid(_ a: InkPoint, _ b: InkPoint) -> CGPoint { CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }
        if pts.count == 1 {
            let r = InkStroke.width(width, tool: tool, pressure: first.pressure) / 2
            ctx.fillEllipse(in: CGRect(x: first.x - r, y: first.y - r, width: r * 2, height: r * 2))
        } else if !tool.usesPressure || tool == .pencil || shape {
            let average = pts.map(\.pressure).reduce(0, +) / Double(pts.count)
            ctx.setLineWidth(tool == .pencil || shape ? InkStroke.width(width, tool: tool, pressure: average) : width)
            ctx.move(to: CGPoint(x: first.x, y: first.y))
            if shape {
                for p in pts.dropFirst() { ctx.addLine(to: CGPoint(x: p.x, y: p.y)) }
            } else {
                for i in 1..<(pts.count - 1) { ctx.addQuadCurve(to: mid(pts[i], pts[i + 1]), control: CGPoint(x: pts[i].x, y: pts[i].y)) }
                ctx.addLine(to: CGPoint(x: pts[pts.count - 1].x, y: pts[pts.count - 1].y))
            }
            ctx.strokePath()
        } else {
            for i in 0..<(pts.count - 1) {
                let a = i == 0 ? CGPoint(x: pts[0].x, y: pts[0].y) : mid(pts[i - 1], pts[i])
                let b = i == pts.count - 2 ? CGPoint(x: pts[i + 1].x, y: pts[i + 1].y) : mid(pts[i], pts[i + 1])
                ctx.setLineWidth(pointWidth(tool: tool, width: width, points: pts, index: i))
                ctx.move(to: a)
                ctx.addQuadCurve(to: b, control: CGPoint(x: pts[i].x, y: pts[i].y))
                ctx.strokePath()
            }
        }
        ctx.restoreGState()
    }

    /// A pen's width at its i-th point (ink.js `pointWidth`).
    static func pointWidth(tool: InkTool, width: Double, points pts: [InkPoint], index i: Int) -> Double {
        let p = pts[i]
        switch tool {
        case .fountain:
            let q = pts[min(pts.count - 1, i + 1)], o = pts[max(0, i - 1)]
            return InkGeometry.fountainWidth(width, pressure: p.pressure, dx: q.x - o.x, dy: q.y - o.y)
        case .brush:
            return InkStroke.width(width, tool: tool, pressure: p.pressure) * InkGeometry.brushTaper(index: i, count: pts.count)
        default:
            return InkStroke.width(width, tool: tool, pressure: p.pressure)
        }
    }


    // MARK: Text boxes and pictures

    static func drawPictures(_ elements: [InkBox], pictures: [String: CGImage], in ctx: CGContext) {
        for e in elements where e.kind == .image {
            guard let id = e.image?.id, let image = pictures[id] else { continue }
            let f = e.frame
            drawImage(image, in: CGRect(x: f.x, y: f.y, width: f.width, height: f.height), ctx: ctx)
        }
    }

    static func drawTexts(_ elements: [InkBox], in ctx: CGContext) {
        for e in elements where e.kind == .text { drawText(e.text, frame: e.frame, size: e.size, color: e.color, in: ctx) }
    }

    /// The system font at `size`, lines 1.25 × size apart, wrapped to the box's width (ink.js `drawTextElement`).
    static func attributed(_ text: String, size: Double, color: String) -> NSAttributedString {
        let font = CTFontCreateUIFontForLanguage(.system, size, nil) ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
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
    static func textHeight(_ text: String, width: Double, size: Double) -> Double {
        let setter = CTFramesetterCreateWithAttributedString(attributed(text.isEmpty ? " " : text, size: size, color: "#000000"))
        let fit = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(location: 0, length: 0), nil,
                                                               CGSize(width: width, height: .greatestFiniteMagnitude), nil)
        return max(size * 1.25, Double(fit.height))
    }

    static func drawText(_ text: String, frame f: InkGeometry.Rect, size: Double, color: String, in ctx: CGContext) {
        guard !text.isEmpty else { return }
        let height = textHeight(text, width: f.width, size: size) + size
        let setter = CTFramesetterCreateWithAttributedString(attributed(text, size: size, color: color))
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
        }
        for l in o.lasers where l.alpha > 0 {
            ctx.saveGState()
            ctx.setAlpha(l.alpha)
            ctx.setShadow(offset: .zero, blur: 10, color: cgColor(l.color))
            draw(tool: .marker, color: l.color, width: l.width * Double(px) * 1.5, points: l.points, in: ctx)
            ctx.restoreGState()
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
