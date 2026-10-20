import CoreGraphics
import Foundation
import ImageIO
import TroveCore
import UniformTypeIdentifiers

/// What's under the ink on a page: a sketch's paper, a PDF page or an image.
enum InkBackground: Sendable {
    case paper(InkPaper)
    case pdf(Data, page: Int)
    case image(Data)
}

/// A page to draw on, in page points (PROTOCOL.md §10).
struct InkPageSpec: Sendable {
    var width: Double
    var height: Double
    var background: InkBackground
}

/// Draws strokes, paper and backgrounds with Core Graphics, the same on iPhone, iPad and Mac and
/// matching web/public/core/ink.js.
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
                return InkPageSpec(width: turned ? box.height : box.width, height: turned ? box.width : box.height, background: .pdf(data, page: i))
            }
        }
        guard let image = cgImage(data) else { return [] }
        return [InkPageSpec(width: Double(image.width), height: Double(image.height), background: .image(data))]
    }

    static func cgImage(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    // MARK: Rendering

    /// A page with its ink, `pixelWidth` wide.
    static func render(_ page: InkPageSpec, strokes: [InkStroke], pixelWidth: Int, background: Bool = true) -> CGImage? {
        let k = Double(pixelWidth) / page.width
        let pxH = Int((page.height * k).rounded())
        guard pixelWidth > 0, pxH > 0, pixelWidth * pxH < 60_000_000,
              let ctx = CGContext(data: nil, width: pixelWidth, height: pxH, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // Top-left origin in page points, like the stroke coordinates.
        ctx.translateBy(x: 0, y: CGFloat(pxH))
        ctx.scaleBy(x: k, y: -k)
        if background { drawBackground(page, in: ctx) }
        draw(strokes, in: ctx)
        return ctx.makeImage()
    }

    /// The background, into a context set up in page points with a top-left origin.
    static func drawBackground(_ page: InkPageSpec, in ctx: CGContext) {
        let size = CGSize(width: page.width, height: page.height)
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: size))
        switch page.background {
        case .paper(let paper): drawPaper(paper, size: size, in: ctx)
        case .pdf(let data, let index):
            guard let provider = CGDataProvider(data: data as CFData), let doc = CGPDFDocument(provider), let pdfPage = doc.page(at: index + 1) else { return }
            ctx.saveGState()
            // PDF drawing is bottom-up: flip back for it.
            ctx.translateBy(x: 0, y: size.height)
            ctx.scaleBy(x: 1, y: -1)
            ctx.concatenate(pdfPage.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: size), rotate: 0, preserveAspectRatio: true))
            ctx.drawPDFPage(pdfPage)
            ctx.restoreGState()
        case .image(let data):
            guard let image = cgImage(data) else { return }
            ctx.saveGState()
            ctx.translateBy(x: 0, y: size.height)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(image, in: CGRect(origin: .zero, size: size))
            ctx.restoreGState()
        }
    }

    static func drawPaper(_ paper: InkPaper, size: CGSize, in ctx: CGContext) {
        let s = InkPaper.spacing
        ctx.saveGState()
        ctx.setStrokeColor(CGColor(red: 90 / 255, green: 130 / 255, blue: 200 / 255, alpha: 0.28))
        ctx.setFillColor(CGColor(red: 90 / 255, green: 110 / 255, blue: 140 / 255, alpha: 0.45))
        ctx.setLineWidth(1)
        switch paper {
        case .blank: break
        case .lined:
            var y = s * 3
            while y < size.height { ctx.move(to: CGPoint(x: 0, y: y)); ctx.addLine(to: CGPoint(x: size.width, y: y)); y += s }
            ctx.strokePath()
        case .grid:
            var y = s
            while y < size.height { ctx.move(to: CGPoint(x: 0, y: y)); ctx.addLine(to: CGPoint(x: size.width, y: y)); y += s }
            var x = s
            while x < size.width { ctx.move(to: CGPoint(x: x, y: 0)); ctx.addLine(to: CGPoint(x: x, y: size.height)); x += s }
            ctx.strokePath()
        case .dotted:
            var y = s
            while y < size.height {
                var x = s
                while x < size.width { ctx.addEllipse(in: CGRect(x: x - 1.3, y: y - 1.3, width: 2.6, height: 2.6)); x += s }
                y += s
            }
            ctx.fillPath()
        }
        ctx.restoreGState()
    }

    static func cgColor(_ hex: String, alpha: Double = 1) -> CGColor {
        let (r, g, b) = InkStroke.rgb(hex)
        return CGColor(red: r, green: g, blue: b, alpha: alpha)
    }

    static func draw(_ strokes: [InkStroke], in ctx: CGContext) {
        for s in strokes { draw(tool: s.tool, color: s.color, width: s.width, points: s.points, in: ctx) }
    }

    /// One stroke, like core/ink.js: pens vary in width segment by segment; markers, highlighters
    /// and pencils are one even line (highlighters blended under the ink).
    static func draw(tool: InkTool, color: String, width: Double, points pts: [InkPoint], in ctx: CGContext) {
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
        } else if tool != .pen {
            let average = pts.map(\.pressure).reduce(0, +) / Double(pts.count)
            ctx.setLineWidth(tool == .pencil ? InkStroke.width(width, tool: tool, pressure: average) : width)
            ctx.move(to: CGPoint(x: first.x, y: first.y))
            for i in 1..<(pts.count - 1) { ctx.addQuadCurve(to: mid(pts[i], pts[i + 1]), control: CGPoint(x: pts[i].x, y: pts[i].y)) }
            ctx.addLine(to: CGPoint(x: pts[pts.count - 1].x, y: pts[pts.count - 1].y))
            ctx.strokePath()
        } else {
            for i in 0..<(pts.count - 1) {
                let a = i == 0 ? CGPoint(x: pts[0].x, y: pts[0].y) : mid(pts[i - 1], pts[i])
                let b = i == pts.count - 2 ? CGPoint(x: pts[i + 1].x, y: pts[i + 1].y) : mid(pts[i], pts[i + 1])
                ctx.setLineWidth(InkStroke.width(width, tool: tool, pressure: pts[i].pressure))
                ctx.move(to: a)
                ctx.addQuadCurve(to: b, control: CGPoint(x: pts[i].x, y: pts[i].y))
                ctx.strokePath()
            }
        }
        ctx.restoreGState()
    }

    /// True if (x, y) is within `radius` of the stroke's line (the stroke eraser).
    static func hits(_ s: InkStroke, x: Double, y: Double, radius: Double) -> Bool {
        let r = radius + s.width / 2
        let pts = s.points
        if pts.count == 1 { return hypot(pts[0].x - x, pts[0].y - y) <= r }
        for i in 0..<max(0, pts.count - 1) {
            let a = pts[i], b = pts[i + 1], dx = b.x - a.x, dy = b.y - a.y, len = dx * dx + dy * dy
            let t = len > 0 ? max(0, min(1, ((x - a.x) * dx + (y - a.y) * dy) / len)) : 0
            if hypot(a.x + t * dx - x, a.y + t * dy - y) <= r { return true }
        }
        return false
    }

    /// A JPEG of a sketch's first page for its card.
    static func thumbnailJPEG(_ page: InkPageSpec, strokes: [InkStroke]) -> Data? {
        guard let image = render(page, strokes: strokes, pixelWidth: 480) else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }
}

struct InkImage: @unchecked Sendable {
    let image: CGImage
}
