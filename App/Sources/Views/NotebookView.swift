import CoreGraphics
import CoreText
import ImageIO
import SwiftUI
import TroveCore

/// A GoodNotes notebook drawn from its own data (`GoodNotesInk`): each page's PDF or image
/// background, then its ink, shapes, typed text and pictures in GoodNotes' order. The website does
/// the same in web/public/viewer.js.
struct GoodNotesView: View {
    let data: Data
    let name: String
    @State private var notebook: GoodNotesInk.Notebook?
    @State private var failed = false

    var body: some View {
        Group {
            if let notebook {
                NotebookView(notebook: notebook, name: name)
            } else if failed, let preview = FilePreview.goodnotes(data) {
                GoodNotesPreview(preview: preview)
            } else if failed {
                Label("Couldn't read this notebook.", systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
            } else {
                ProgressView("Opening notebook…").frame(maxWidth: .infinity, minHeight: 120)
            }
        }
        .task(id: data.count) {
            let data = data
            let read = await Task.detached(priority: .userInitiated) { try? GoodNotesInk.read(data) }.value
            if let read, !read.pages.isEmpty { notebook = read } else { failed = true }
        }
    }
}

struct NotebookView: View {
    let notebook: GoodNotesInk.Notebook
    let name: String
    @State private var reading: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("GoodNotes notebook · \(notebook.pages.count) page\(notebook.pages.count == 1 ? "" : "s")", systemImage: "pencil.and.scribble")
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                let unread = notebook.pages.reduce(0) { $0 + $1.unread }
                if unread > 0 {
                    Text("· \(unread) stroke\(unread == 1 ? "" : "s") couldn't be read")
                        .font(.caption).foregroundStyle(.secondary)
                        .help("Trove couldn't read some of this notebook's ink. Send the notebook (or a copy with one such stroke) to get it fixed.")
                }
                Spacer()
                Button { reading = 0 } label: { Label("Read", systemImage: "arrow.up.left.and.arrow.down.right") }
                    .buttonStyle(.bordered).controlSize(.small)
            }
            LazyVStack(spacing: 12) {
                ForEach(Array(notebook.pages.enumerated()), id: \.offset) { index, page in
                    NotebookPageView(notebook: notebook, page: page)
                        .onTapGesture { reading = index }
                }
            }
        }
        .padding(12)
        .card(cornerRadius: 14)
        .sheet(item: Binding(get: { reading.map(ReaderPage.init) }, set: { reading = $0?.index })) { start in
            NotebookReader(notebook: notebook, name: name, start: start.index)
        }
    }

    struct ReaderPage: Identifiable { let index: Int; var id: Int { index } }
}

/// One page, drawn from its vectors in tiles at the size it shows (sharp at any zoom, no work while still).
struct NotebookPageView: View {
    let notebook: GoodNotesInk.Notebook
    let page: GoodNotesInk.Page

    var body: some View {
        let (notebook, page) = (notebook, page)
        InkTiledPage(token: "\(page.width)x\(page.height)-\(page.layers.count)") { ctx, size in
            let k = size.width / max(1, page.width)
            ctx.scaleBy(x: k, y: k)
            NotebookRenderer.draw(page, of: notebook, layers: page.layers, size: CGSize(width: page.width, height: page.height), in: ctx)
        }
        .aspectRatio(page.width / page.height, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
        .accessibilityLabel("Notebook page")
    }
}

/// The notebook full size: scroll through the pages, pinch or use the buttons to zoom.
struct NotebookReader: View {
    let notebook: GoodNotesInk.Notebook
    let name: String
    let start: Int
    @Environment(\.dismiss) private var dismiss
    @State private var zoom: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                ScrollViewReader { proxy in
                    ScrollView([.vertical, .horizontal]) {
                        LazyVStack(spacing: 16) {
                            ForEach(Array(notebook.pages.enumerated()), id: \.offset) { index, page in
                                NotebookPageView(notebook: notebook, page: page)
                                    .frame(width: max(200, (geo.size.width - 24) * zoom))
                                    .id(index)
                            }
                        }
                        .padding(12)
                        // While pinching the drawn pages just scale; they're drawn sharp at the new size when it ends.
                        .scaleEffect(pinch, anchor: .top)
                    }
                    .onAppear { proxy.scrollTo(start, anchor: .top) }
                }
                .gesture(MagnifyGesture().updating($pinch) { value, state, _ in state = value.magnification }
                    .onEnded { value in zoom = min(5, max(0.5, zoom * value.magnification)) })
            }
            .background(Color.gray.opacity(0.15))
            .navigationTitle(name)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItemGroup {
                    Button { zoom = max(0.5, zoom / 1.25) } label: { Label("Zoom out", systemImage: "minus.magnifyingglass") }
                    Button { zoom = min(5, zoom * 1.25) } label: { Label("Zoom in", systemImage: "plus.magnifyingglass") }
                }
            }
        }
        .sheetSize(width: 900, height: 1000)
    }
}

struct RenderedPage: @unchecked Sendable {
    let cgImage: CGImage
    let scale: CGFloat
}

/// Draws a notebook page with Core Graphics (the same on iPhone, iPad and Mac).
enum NotebookRenderer {
    static func render(_ page: GoodNotesInk.Page, of notebook: GoodNotesInk.Notebook, width: CGFloat, scale: CGFloat) -> RenderedPage? {
        let k = width / page.width
        // A big whiteboard would need more pixels than is sensible: draw it softer rather than not at all.
        let scale = min(scale, CGFloat((58_000_000 / max(1, Double(width * width) * page.height / page.width)).squareRoot()))
        let pxW = Int((width * scale).rounded()), pxH = Int((page.height * k * scale).rounded())
        guard pxW > 0, pxH > 0, pxW * pxH <= 60_000_000,
              let ctx = CGContext(data: nil, width: pxW, height: pxH, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let px = k * scale // device pixels per point
        let size = CGSize(width: page.width, height: page.height)
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: pxW, height: pxH))
        ctx.interpolationQuality = .high

        // Background, in Core Graphics' own (bottom-left) coordinates.
        ctx.saveGState()
        ctx.scaleBy(x: px, y: px)
        if let bg = page.background, let file = notebook.attachments[bg.attachment] {
            if file.mime == "application/pdf", let provider = CGDataProvider(data: file.data as CFData), let doc = CGPDFDocument(provider),
               let pdfPage = doc.page(at: min(max(1, bg.page), doc.numberOfPages)) {
                let box = pdfPage.getBoxRect(.cropBox)
                ctx.scaleBy(x: size.width / max(box.width, 1), y: size.height / max(box.height, 1))
                ctx.translateBy(x: -box.minX, y: -box.minY)
                ctx.drawPDFPage(pdfPage)
            } else if file.mime.hasPrefix("image/"), let image = cgImage(file.data) {
                ctx.draw(image, in: CGRect(origin: .zero, size: size))
            }
        }
        ctx.restoreGState()

        // Everything else in GoodNotes units, top-left origin.
        ctx.translateBy(x: 0, y: CGFloat(pxH))
        ctx.scaleBy(x: px * GoodNotesInk.scale, y: -px * GoodNotesInk.scale)
        for layer in page.layers {
            switch layer {
            case .ink(let stroke): draw(stroke, in: ctx)
            case .image(let picture):
                guard let file = notebook.attachments[picture.attachment], let image = cgImage(file.data) else { continue }
                ctx.saveGState()
                ctx.translateBy(x: picture.x, y: picture.y + picture.h)
                ctx.scaleBy(x: 1, y: -1)
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: picture.w, height: picture.h))
                ctx.restoreGState()
            case .text(let box): draw(box, in: ctx, pageHeight: page.height / GoodNotesInk.scale)
            }
        }
        guard let image = ctx.makeImage() else { return nil }
        return RenderedPage(cgImage: image, scale: scale)
    }

    static func cgImage(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// A page into a context set up in points with a top-left origin (the drawing editor's), with
    /// only `layers` on its background: what's left once Trove holds the ink and text.
    static func draw(_ page: GoodNotesInk.Page, of notebook: GoodNotesInk.Notebook, layers: [GoodNotesInk.Layer], size: CGSize, in ctx: CGContext) {
        ctx.saveGState()
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: size))
        if let bg = page.background, let file = notebook.attachments[bg.attachment] {
            if file.mime == "application/pdf", let provider = CGDataProvider(data: file.data as CFData), let doc = CGPDFDocument(provider),
               let pdfPage = doc.page(at: min(max(1, bg.page), doc.numberOfPages)) {
                ctx.saveGState()
                // PDF drawing is bottom-up: flip back for it.
                ctx.translateBy(x: 0, y: size.height)
                ctx.scaleBy(x: 1, y: -1)
                let box = pdfPage.getBoxRect(.cropBox)
                ctx.scaleBy(x: size.width / max(box.width, 1), y: size.height / max(box.height, 1))
                ctx.translateBy(x: -box.minX, y: -box.minY)
                ctx.drawPDFPage(pdfPage)
                ctx.restoreGState()
            } else if file.mime.hasPrefix("image/"), let image = cgImage(file.data) {
                InkRenderer.drawImage(image, in: CGRect(origin: .zero, size: size), ctx: ctx)
            }
        }
        // GoodNotes units from here, still top-left.
        ctx.scaleBy(x: GoodNotesInk.scale, y: GoodNotesInk.scale)
        for layer in layers {
            switch layer {
            case .ink(let stroke): draw(stroke, in: ctx)
            case .image(let picture):
                guard let file = notebook.attachments[picture.attachment], let image = cgImage(file.data) else { continue }
                ctx.saveGState()
                ctx.translateBy(x: picture.x, y: picture.y + picture.h)
                ctx.scaleBy(x: 1, y: -1)
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: picture.w, height: picture.h))
                ctx.restoreGState()
            case .text(let box): draw(box, in: ctx, pageHeight: page.height / GoodNotesInk.scale)
            }
        }
        ctx.restoreGState()
    }

    static func color(_ rgb: [Double], _ alpha: Double) -> CGColor {
        CGColor(red: rgb.count > 0 ? rgb[0] : 0, green: rgb.count > 1 ? rgb[1] : 0, blue: rgb.count > 2 ? rgb[2] : 0, alpha: alpha)
    }

    /// A smooth line through the points (quadratic curves between midpoints), straight for shapes.
    static func path(_ run: [GoodNotesInk.Point], straight: Bool) -> CGPath {
        let path = CGMutablePath()
        guard let first = run.first else { return path }
        path.move(to: CGPoint(x: first.x, y: first.y))
        if run.count == 1 { path.addLine(to: CGPoint(x: first.x + 0.01, y: first.y)); return path }
        if straight {
            for p in run.dropFirst() { path.addLine(to: CGPoint(x: p.x, y: p.y)) }
            return path
        }
        for i in 1..<(run.count - 1) {
            let mid = CGPoint(x: (run[i].x + run[i + 1].x) / 2, y: (run[i].y + run[i + 1].y) / 2)
            path.addQuadCurve(to: mid, control: CGPoint(x: run[i].x, y: run[i].y))
        }
        path.addLine(to: CGPoint(x: run[run.count - 1].x, y: run[run.count - 1].y))
        return path
    }

    static func draw(_ stroke: GoodNotesInk.Stroke, in ctx: CGContext) {
        ctx.saveGState()
        if stroke.isFill {
            ctx.setFillColor(color(stroke.rgb, stroke.alpha))
            for run in stroke.runs {
                ctx.addPath(path(run, straight: true))
                ctx.closePath()
                ctx.fillPath()
            }
            ctx.restoreGState()
            return
        }
        ctx.setStrokeColor(color(stroke.rgb, stroke.opacity))
        ctx.setLineWidth(stroke.lineWidth)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        if stroke.isHighlighter { ctx.setBlendMode(.multiply) }
        for run in stroke.runs {
            ctx.addPath(path(run, straight: stroke.isShape))
            ctx.strokePath()
        }
        ctx.restoreGState()
    }

    /// Typed text, wrapped to its box by Core Text (which draws bottom-up, so flip back for it).
    static func draw(_ box: GoodNotesInk.TextBox, in ctx: CGContext, pageHeight: Double) {
        let text = NSMutableAttributedString()
        for run in box.runs {
            let name = run.bold ? "HelveticaNeue-Bold" : run.italic ? "HelveticaNeue-Italic" : "HelveticaNeue"
            let font = CTFontCreateWithName(name as CFString, run.size, nil)
            text.append(NSAttributedString(string: run.text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): color(run.rgb, 1),
            ]))
        }
        let height = max(box.h, pageHeight - box.y)
        ctx.saveGState()
        ctx.translateBy(x: box.x, y: box.y + height)
        ctx.scaleBy(x: 1, y: -1)
        let framesetter = CTFramesetterCreateWithAttributedString(text)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0),
                                             CGPath(rect: CGRect(x: 0, y: 0, width: max(box.w, 40), height: height), transform: nil), nil)
        CTFrameDraw(frame, ctx)
        ctx.restoreGState()
    }
}
