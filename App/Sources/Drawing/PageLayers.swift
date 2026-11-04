#if os(iOS)
@preconcurrency import QuartzCore
import TroveCore
import UIKit

// The iPad canvas's own layers (docs/plans/sketch-2-plan.md S2): paper, PDF and picture pages,
// pictures, text boxes and tape. They used to be repainted on the CPU on every frame of a pinch and
// in big chunks while panning. Now each is a Core Animation layer at 100 % inside a host whose
// transform is the zoom: pinching and panning change one property and the GPU does the rest.
//
// - Paper is `CAShapeLayer`s from `InkPaperShapes`: vector, sharp at every zoom, never repainted.
// - PDF and picture pages show their whole-page picture plus the sharp part `InkBackdrop` renders
//   (at twice the screen's density, during the gesture as well as after it).
// - Pictures are layers holding the image itself (as sharp as the picture can be at any zoom).
// - Text boxes and tape are one small layer each, drawn at 4× the zoom so a pinch stays sharp.

/// A view in the scroll view's content holding layers in 100 % page coordinates, scaled by the zoom.
final class InkZoomHost: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isOpaque = false
        backgroundColor = .clear
        layer.anchorPoint = .zero
        layer.position = .zero
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Sizes the host to the content at 100 % and scales it to `zoom` (no animation, no repaint).
    func set(size: CGSize, zoom: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if layer.bounds.size != size { layer.bounds = CGRect(origin: .zero, size: size) }
        layer.position = .zero
        let t = CATransform3DMakeScale(zoom, zoom, 1)
        if !CATransform3DEqualToTransform(layer.transform, t) { layer.transform = t }
        CATransaction.commit()
    }
}

/// One page under the ink: its paper (or PDF/picture page) and its pictures.
final class InkPageLayer: CALayer {
    private let paper = CALayer()
    private var shapes: [CAShapeLayer] = []
    private let whole = CALayer()
    private let detail = CALayer()
    /// The PDF, picture or GoodNotes page drawn sharp in tiles at whatever zoom it's shown at.
    private let tiles = InkTiledPageLayer()
    private var tilesSig = ""
    private let picturesLayer = CALayer()
    private var pictureLayers: [String: CALayer] = [:]
    /// What the paper was last built from (spec, colour, dark, and the area for an endless canvas).
    private var paperSig = ""
    private var paperArea: CGRect?
    private var shownWhole: CGImage?
    private var shownDetail: CGImage?
    private var shownPictures: [String: CGImage] = [:]

    override init() {
        super.init()
        for l in [paper, whole, detail, tiles, picturesLayer] {
            l.actions = Self.noActions
            addSublayer(l)
        }
        actions = Self.noActions
        whole.contentsGravity = .resize
        detail.contentsGravity = .resize
        whole.magnificationFilter = .linear
        detail.magnificationFilter = .linear
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError("not used") }

    /// No implicit animations: the layers follow the model at once.
    static var noActions: [String: CAAction] {
        ["position": NSNull(), "bounds": NSNull(), "contents": NSNull(), "frame": NSNull(),
                                                 "transform": NSNull(), "hidden": NSNull(), "path": NSNull(), "lineWidth": NSNull(),
                                                 "backgroundColor": NSNull(), "sublayers": NSNull(), "opacity": NSNull(),
                                                 "shadowPath": NSNull(), "shadowOpacity": NSNull(), "contentsScale": NSNull()]
    }

    /// Places the page at `frame` (canvas points at 100 %) and builds its paper. `area`: what's
    /// near the screen, in the page's own points (an endless canvas builds its paper only there).
    func show(_ spec: InkPageSpec, frame: CGRect, dark: Bool, area: CGRect, zoom: CGFloat, screen: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        if self.frame != frame { self.frame = frame }
        let bounds = CGRect(origin: .zero, size: frame.size)
        let drawn = dark ? InkDark.spec(spec) : spec
        switch drawn.background {
        case .paper(let kind, let color):
            whole.isHidden = true
            detail.isHidden = true
            tiles.isHidden = true
            paper.isHidden = false
            backgroundColor = InkRenderer.cgColor(color ?? "#ffffff")
            setEdge(spec.infinite ? nil : (InkPage.isDark(color) ? UIColor.white.withAlphaComponent(0.12) : UIColor.black.withAlphaComponent(0.08)), bounds: bounds)
            // Lines in page points: 1 pt, but never thinner than a pixel on screen (zoomed far out).
            let width = max(1, 1 / max(0.05, zoom * screen))
            let sig = "\(spec.key)|\(kind.rawValue)|\(color ?? "")|\(dark)|\(spec.width)x\(spec.height)"
            let needsArea = spec.infinite && !(paperArea?.contains(area) ?? false)
            if sig != paperSig || needsArea {
                paperSig = sig
                // An endless canvas's paper covers a screen's worth round what's shown.
                let built = spec.infinite ? area.insetBy(dx: -area.width / 2, dy: -area.height / 2) : nil
                paperArea = built
                buildPaper(kind, size: frame.size, dark: InkPage.isDark(color), infinite: spec.infinite, area: built, offset: spec.infinite ? spec.origin : 0)
            }
            for s in shapes where s.fillColor == nil && s.lineWidth != width { s.lineWidth = width }
        case .pdf, .image, .goodnotes:
            paper.isHidden = true
            setEdge(UIColor.black.withAlphaComponent(0.08), bounds: bounds)
            backgroundColor = UIColor.white.cgColor
            whole.isHidden = false
            whole.frame = bounds
            paperSig = ""
            // Sharp tiles over the whole page's quick picture: only the tiles on screen are drawn, in the
            // background and several at once, and kept, so zooming back is instant (no redraw of the page).
            tiles.isHidden = false
            if tiles.frame != bounds { tiles.frame = bounds }
            tiles.contentsScale = screen
            let sig = "\(spec.key)|\(dark)|\(spec.width)x\(spec.height)"
            if sig != tilesSig {
                tilesSig = sig
                tiles.page = InkTiledPageLayer.Page(drawn)
                tiles.setNeedsDisplay()
            }
        }
        // Pictures are in page points; an endless canvas's page points start at −origin.
        let shift = spec.infinite ? CGFloat(spec.origin) : 0
        picturesLayer.frame = CGRect(x: shift, y: shift, width: frame.width, height: frame.height)
    }


    /// A thin edge under the page: a hard shadow with a given path (no blur, no offscreen pass).
    private func setEdge(_ colour: UIColor?, bounds: CGRect) {
        guard let colour else { shadowOpacity = 0; return }
        shadowColor = colour.withAlphaComponent(1).cgColor
        var alpha: CGFloat = 0
        colour.getWhite(nil, alpha: &alpha)
        shadowOpacity = Float(alpha)
        shadowRadius = 0
        shadowOffset = CGSize(width: 0, height: 0.75)
        let path = CGPath(rect: bounds.insetBy(dx: -0.5, dy: -0.5), transform: nil)
        if shadowPath != path { shadowPath = path }
    }

    /// Paper as vector layers: one per line role, and one for dots.
    private func buildPaper(_ kind: InkPaper, size: CGSize, dark: Bool, infinite: Bool, area: CGRect?, offset: Double) {
        shapes.forEach { $0.removeFromSuperlayer() }
        shapes = []
        paper.frame = CGRect(origin: .zero, size: size)
        // An endless canvas: shapes in page points (−origin … +origin), shown at +origin.
        let local = area.map { InkGeometry.Rect(x: $0.minX, y: $0.minY, width: $0.width, height: $0.height) }
        let found = InkPaperShapes.shapes(kind, width: size.width, height: size.height, area: infinite ? local : nil)
        func rgba(_ r: Double, _ g: Double, _ b: Double, _ a: Double) -> CGColor { CGColor(red: r / 255, green: g / 255, blue: b / 255, alpha: a) }
        let colours: [InkPaperShapes.Role: CGColor] = dark
            ? [.line: rgba(200, 215, 240, 0.22), .bold: rgba(200, 215, 240, 0.4), .accent: rgba(240, 150, 150, 0.5)]
            : [.line: rgba(90, 130, 200, 0.28), .bold: rgba(90, 130, 200, 0.5), .accent: rgba(220, 90, 90, 0.55)]
        let shift = CGFloat(infinite ? offset : 0)
        for role in [InkPaperShapes.Role.line, .bold, .accent] {
            let path = CGMutablePath()
            var any = false
            for shape in found {
                switch shape {
                case .hline(let y, let a, let b, let r) where r == role:
                    path.move(to: CGPoint(x: a + shift, y: y + shift)); path.addLine(to: CGPoint(x: b + shift, y: y + shift)); any = true
                case .vline(let x, let a, let b, let r) where r == role:
                    path.move(to: CGPoint(x: x + shift, y: a + shift)); path.addLine(to: CGPoint(x: x + shift, y: b + shift)); any = true
                case .box(let x, let y, let w, let h, let r) where r == role:
                    path.addRect(CGRect(x: x + shift, y: y + shift, width: w, height: h)); any = true
                default:
                    break
                }
            }
            guard any else { continue }
            let l = CAShapeLayer()
            l.actions = Self.noActions
            l.path = path
            l.fillColor = nil
            l.strokeColor = colours[role]
            l.lineWidth = 1
            paper.addSublayer(l)
            shapes.append(l)
        }
        let dots = CGMutablePath()
        var anyDot = false
        for case .dot(let x, let y, let d) in found {
            dots.addEllipse(in: CGRect(x: x - d + shift, y: y - d + shift, width: d * 2, height: d * 2))
            anyDot = true
        }
        if anyDot {
            let l = CAShapeLayer()
            l.actions = Self.noActions
            l.path = dots
            l.fillColor = dark ? rgba(210, 220, 235, 0.4) : rgba(90, 110, 140, 0.45)
            l.strokeColor = nil
            paper.addSublayer(l)
            shapes.append(l)
        }
    }

    /// The PDF or picture page's whole picture and sharp part.
    func showBackdrop(whole image: CGImage?, piece: InkBackdrop.Piece?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        if shownWhole !== image { shownWhole = image; whole.contents = image }
        if let piece {
            detail.isHidden = false
            detail.frame = piece.rect
            if shownDetail !== piece.image { shownDetail = piece.image; detail.contents = piece.image }
        } else if shownDetail != nil {
            detail.isHidden = true
            detail.contents = nil
            shownDetail = nil
        }
    }

    /// The page's pictures, each a layer holding its image (turned and mirrored as the element is).
    func showPictures(_ elements: [InkBox], pictures: [String: CGImage], offset: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        var seen: Set<String> = []
        for e in elements where e.kind == .image {
            guard let id = e.image?.id, let image = pictures[id] else { continue }
            seen.insert(e.id)
            let l = pictureLayers[e.id] ?? {
                let n = CALayer()
                n.actions = Self.noActions
                n.contentsGravity = .resize
                n.magnificationFilter = .linear
                n.minificationFilter = .trilinear
                picturesLayer.addSublayer(n)
                pictureLayers[e.id] = n
                return n
            }()
            let f = e.frame
            l.transform = CATransform3DIdentity
            l.bounds = CGRect(x: 0, y: 0, width: f.width, height: f.height)
            l.position = CGPoint(x: f.x + f.width / 2, y: f.y + f.height / 2)
            var t = CGAffineTransform(rotationAngle: CGFloat(e.rotate))
            if e.flip { t = t.scaledBy(x: -1, y: 1) }
            l.setAffineTransform(t)
            if shownPictures[e.id] !== image { shownPictures[e.id] = image; l.contents = image }
        }
        for (id, l) in pictureLayers where !seen.contains(id) {
            l.removeFromSuperlayer()
            pictureLayers[id] = nil
            shownPictures[id] = nil
        }
    }
}

/// Text boxes and tape over the ink: one small layer per element, drawn by `InkRenderer` at a
/// resolution with headroom (4× the zoom), so pinching never repaints them; redrawn after a zoom
/// only when it goes past that headroom.
final class InkElementLayer: CALayer {
    var box: InkBox?
    var peeked = false
    /// What it was last drawn from.
    var sig = ""

    override init() {
        super.init()
        actions = InkPageLayer.noActions
        needsDisplayOnBoundsChange = false
        isOpaque = false
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(in ctx: CGContext) {
        guard let box else { return }
        ctx.translateBy(x: -frame.minX, y: -frame.minY)
        switch box.kind {
        case .tape: InkRenderer.drawTapes([box], peeked: peeked ? [box.id] : [], in: ctx)
        default: InkRenderer.drawTexts([box], in: ctx)
        }
    }

    /// The scale to draw at for `zoom`: the screen's, times the zoom rounded up to a power of two,
    /// times 4 of headroom, but no more than 3 million pixels for the layer.
    static func scale(zoom: CGFloat, screen: CGFloat, size: CGSize) -> CGFloat {
        let level = pow(2, ceil(log2(max(0.125, zoom))))
        var s = screen * level * 4
        let pixels = size.width * size.height * s * s
        if pixels > 3_000_000 { s *= sqrt(3_000_000 / pixels) }
        return max(screen * 0.5, s)
    }
}

/// The page's text boxes and tape, as element layers, above the ink.
final class InkElementsLayer: CALayer {
    private var layers: [String: InkElementLayer] = [:]

    override init() {
        super.init()
        actions = InkPageLayer.noActions
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError("not used") }

    /// `zoom`: what to draw for; `near`: whether the page is on or near the screen (far pages draw
    /// at the screen's scale only, to save memory).
    func show(_ elements: [InkBox], peeked: Set<String>, frame: CGRect, zoom: CGFloat, near: Bool, screen: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        if self.frame != frame { self.frame = frame }
        var seen: Set<String> = []
        for e in elements where e.kind == .text || e.kind == .tape {
            seen.insert(e.id)
            let l = layers[e.id] ?? {
                let n = InkElementLayer()
                addSublayer(n)
                layers[e.id] = n
                return n
            }()
            // Room for a turned box and the tape's torn edges.
            let b = e.drawnBounds
            let rect = CGRect(x: b.x, y: b.y, width: b.width, height: b.height).insetBy(dx: -4, dy: -4)
            let sig = "\(e.kind)|\(e.frame.x),\(e.frame.y),\(e.frame.width),\(e.frame.height)|\(e.rotate)|\(e.text)|\(e.size)|\(e.color)|\(e.textStyle)|\(peeked.contains(e.id))"
            let scale = near ? InkElementLayer.scale(zoom: zoom, screen: screen, size: rect.size) : screen
            if l.frame != rect { l.frame = rect }
            if sig != l.sig || l.contentsScale != scale {
                l.sig = sig
                l.box = e
                l.peeked = peeked.contains(e.id)
                l.contentsScale = scale
                l.setNeedsDisplay()
            }
        }
        for (id, l) in layers where !seen.contains(id) {
            l.removeFromSuperlayer()
            layers[id] = nil
        }
    }
}
#endif


/// A PDF, picture or GoodNotes page drawn in 512-pixel tiles by Core Animation (as PDF readers do):
/// at each zoom only the tiles on screen are drawn, on background threads and several at once, at the
/// zoom's own resolution, and kept for zooming back. No fade: a tile appears the moment it's ready, over
/// the page's quick whole picture.
final class InkTiledPageLayer: CATiledLayer {
    /// What a tile draws: the page, with its PDF page opened once (drawing a `CGPDFPage` from several
    /// threads is safe; parsing the document per tile would not be quick).
    final class Page: @unchecked Sendable {
        let spec: InkPageSpec
        let pdf: CGPDFPage?
        init(_ spec: InkPageSpec) {
            self.spec = spec
            if case .pdf(let data, let index) = spec.background, let provider = CGDataProvider(data: data as CFData),
               let doc = CGPDFDocument(provider) {
                pdf = doc.page(at: index + 1)
            } else {
                pdf = nil
            }
        }
    }

    private let lock = NSLock()
    private var _page: Page?
    var page: Page? {
        get { lock.lock(); defer { lock.unlock() }; return _page }
        set { lock.lock(); _page = newValue; lock.unlock() }
    }

    override class func fadeDuration() -> CFTimeInterval { 0 }

    override init() {
        super.init()
        actions = InkPageLayer.noActions
        tileSize = CGSize(width: 512, height: 512)
        // From 1/8 to 16 times: Trove zooms 10 %–1000 %.
        levelsOfDetail = 8
        levelsOfDetailBias = 4
        isOpaque = false
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(in ctx: CGContext) {
        guard let page else { return }
        let spec = page.spec
        // The context is in page points with a top-left origin, clipped to this tile.
        let tile = ctx.boundingBoxOfClipPath
        if let pdf = page.pdf {
            let size = CGSize(width: spec.width, height: spec.height)
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(tile)
            ctx.saveGState()
            ctx.translateBy(x: 0, y: size.height)
            ctx.scaleBy(x: 1, y: -1)
            ctx.concatenate(pdf.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: size), rotate: 0, preserveAspectRatio: true))
            ctx.drawPDFPage(pdf)
            ctx.restoreGState()
        } else {
            InkRenderer.drawBackground(spec, area: InkGeometry.Rect(x: tile.minX, y: tile.minY, width: tile.width, height: tile.height), in: ctx)
        }
    }
}
