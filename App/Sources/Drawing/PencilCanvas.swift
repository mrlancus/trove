#if os(iOS)
import PencilKit
import SwiftUI
import TroveCore
import UIKit
import UIKit.UIGestureRecognizerSubclass

/// The drawing surface on iPhone and iPad. Pens are PencilKit's, so Apple Pencil gets its
/// pressure, tilt, low latency and palm rejection (a finger draws on iPhone). The eraser, lasso,
/// laser and text tools are Trove's own (`InkToolGesture` → the editor model), so they act on the
/// shared strokes exactly like the website and the Mac.
///
/// A sketch's pages sit on one canvas: down in a column, across in a row, or one at a time (flip,
/// with a page turn), like the website (`InkPageLayout`). Each page's strokes are placed at the
/// page's spot (`Slot.offset`); a new stroke belongs to the page it starts on. Paper, PDF pages
/// and pictures are drawn underneath for what's on screen only; text boxes, the lasso, the
/// selection and the laser on top. Zoom runs from 10 % to 1000 % (1 = a page point per screen
/// point) and starts fitted to the page. Holding the pen still at the end of a line snaps it into a
/// shape; tapping with two fingers undoes and with three redoes. Squeezing Apple Pencil (or
/// double-tapping it) does what the person chose in Settings → Apple Pencil: the eraser, the last
/// tool, or Trove's tool palette at the Pencil's tip.
struct PencilCanvas: UIViewRepresentable {
    let editor: InkEditorModel
    let pages: [InkPageSpec]
    let current: Int
    let layout: InkPageLayout
    let pagesRevision: Int
    let revision: Int
    let overlayRevision: Int
    let tool: InkEditorTool
    let color: String
    let width: Double
    let zoomRequest: InkZoomRequest?

    func makeCoordinator() -> Coordinator { Coordinator(editor: editor) }

    func makeUIView(context: Context) -> TroveCanvasView {
        let canvas = TroveCanvasView()
        let c = context.coordinator
        canvas.delegate = c
        canvas.backgroundColor = UIColor.systemGray5
        canvas.isOpaque = true
        canvas.overrideUserInterfaceStyle = .light // keep ink colours true on white paper
        canvas.drawingPolicy = UIDevice.current.userInterfaceIdiom == .pad ? .default : .anyInput
        canvas.showsVerticalScrollIndicator = true
        canvas.showsHorizontalScrollIndicator = true
        canvas.contentInsetAdjustmentBehavior = .never
        canvas.minimumZoomScale = InkEditorModel.minZoom
        canvas.maximumZoomScale = InkEditorModel.maxZoom
        canvas.bouncesZoom = true
        canvas.insertSubview(c.paperView, at: 0)
        canvas.addSubview(c.overlayView)
        canvas.addInteraction(UIPencilInteraction(delegate: c))
        // Apple Pencil hovering (M2 and later iPads, Pencil Pro): preview the tip and colour, or the eraser.
        let hover = UIHoverGestureRecognizer(target: c, action: #selector(Coordinator.hovered(_:)))
        hover.delegate = c
        canvas.addGestureRecognizer(hover)
        // Pencil Pro's haptics when a shape snaps or the tool changes (squeeze palette, double-tap).
        if #available(iOS 17.5, *) {
            let feedback = UICanvasFeedbackGenerator(view: canvas)
            editor.haptic = { [weak canvas] kind in
                guard let canvas else { return }
                let at = CGPoint(x: canvas.bounds.midX, y: canvas.bounds.midY)
                switch kind {
                case .snapped: feedback.alignmentOccurred(at: at)
                case .toolChanged: feedback.pathCompleted(at: at)
                }
            }
        }
        canvas.onLayout = { [weak c, weak canvas] in if let c, let canvas { c.layout(canvas) } }

        let tools = InkToolGesture()
        tools.onTouch = { [weak c, weak canvas] phase, point in if let c, let canvas { c.toolTouch(phase, at: point, in: canvas) } }
        tools.isEnabled = false
        canvas.addGestureRecognizer(tools)
        c.toolGesture = tools

        let hold = HoldWatcher(target: nil, action: nil)
        hold.cancelsTouchesInView = false
        hold.delaysTouchesBegan = false
        hold.delaysTouchesEnded = false
        hold.delegate = c
        canvas.addGestureRecognizer(hold)
        c.holdWatcher = hold

        for (fingers, action) in [(2, #selector(Coordinator.undoTap)), (3, #selector(Coordinator.redoTap))] {
            let tap = UITapGestureRecognizer(target: c, action: action)
            tap.numberOfTouchesRequired = fingers
            tap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
            tap.delegate = c
            canvas.addGestureRecognizer(tap)
        }
        // Flip mode: a sideways swipe turns the page (one finger when the Pencil draws, else two).
        for direction in [UISwipeGestureRecognizer.Direction.left, .right] {
            let swipe = UISwipeGestureRecognizer(target: c, action: #selector(Coordinator.swiped(_:)))
            swipe.direction = direction
            swipe.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
            swipe.delegate = c
            canvas.addGestureRecognizer(swipe)
            c.swipes.append(swipe)
        }
        return canvas
    }

    func updateUIView(_ canvas: TroveCanvasView, context: Context) {
        let c = context.coordinator
        c.editor = editor
        c.updating = true
        defer { c.updating = false }
        c.show(pages, current: current, layout: layout, revision: pagesRevision, in: canvas)
        c.apply(version: revision, to: canvas)
        if overlayRevision != c.shownOverlay { c.shownOverlay = overlayRevision; c.overlayView.setNeedsDisplay() }
        let pen = tool.ink != nil
        // Setting PencilKit's tool resets its state: only when it really changes.
        let toolKey = "\(tool.rawValue)|\(color)|\(width)"
        if let ink = tool.ink, toolKey != c.shownTool { c.shownTool = toolKey; canvas.tool = Self.pkTool(ink, color: color, width: width) }
        canvas.drawingGestureRecognizer.isEnabled = pen
        c.toolGesture?.isEnabled = !pen
        // Where a finger draws (iPhone), it also works the lasso and eraser; two fingers scroll.
        let fingers = canvas.drawingPolicy == .anyInput || !UIPencilInteraction.prefersPencilOnlyDrawing
        c.toolGesture?.allowedTouchTypes = fingers
            ? [NSNumber(value: UITouch.TouchType.pencil.rawValue), NSNumber(value: UITouch.TouchType.direct.rawValue)]
            : [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        canvas.panGestureRecognizer.minimumNumberOfTouches = !pen && fingers ? 2 : 1
        for s in c.swipes { s.numberOfTouchesRequired = fingers ? 2 : 1 }
        if let zoomRequest, zoomRequest.id != c.handledZoom {
            c.handledZoom = zoomRequest.id
            c.zoom(zoomRequest.kind, in: canvas)
        }
        canvas.bringSubviewToFront(c.overlayView)
    }

    static func pkTool(_ tool: InkTool, color: String, width: Double) -> PKTool {
        let type: PKInk.InkType = switch tool {
        case .pen: .pen
        case .pencil: .pencil
        case .marker: .monoline
        case .highlighter: .marker
        case .fountain: .fountainPen
        case .brush: .watercolor
        }
        return PKInkingTool(type, color: uiColor(color), width: width)
    }

    // MARK: Converting strokes

    nonisolated static func uiColor(_ hex: String) -> UIColor {
        let (r, g, b) = InkStroke.rgb(hex)
        return UIColor(red: r, green: g, blue: b, alpha: 1)
    }

    nonisolated static func hex(_ color: UIColor) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light)).getRed(&r, green: &g, blue: &b, alpha: &a)
        func byte(_ v: CGFloat) -> Int { Int((min(1, max(0, v)) * 255).rounded()) }
        return String(format: "#%02x%02x%02x", byte(r), byte(g), byte(b))
    }

    /// A Trove stroke as PencilKit's, moved to its page's spot on the canvas. Nil for one with no points.
    static func pkStroke(_ s: InkLine, offset: CGPoint) -> PKStroke? {
        let inkType: PKInk.InkType = switch s.tool {
        case .pen: .pen
        case .pencil: .pencil
        case .marker: .monoline
        case .highlighter: .marker
        case .fountain: .fountainPen
        case .brush: .watercolor
        }
        let points = s.points.compactMap { p -> PKStrokePoint? in
            guard p.x.isFinite, p.y.isFinite else { return nil }
            let w = max(0.1, s.shape != nil ? s.width : InkStroke.width(s.width, tool: s.tool, pressure: p.pressure))
            return PKStrokePoint(location: CGPoint(x: p.x + offset.x, y: p.y + offset.y), timeOffset: max(0, p.t / 1000), size: CGSize(width: w, height: w),
                                 opacity: 1, force: max(0, p.pressure * 2), azimuth: 0, altitude: .pi / 2)
        }
        guard !points.isEmpty else { return nil }
        return PKStroke(ink: PKInk(inkType, color: uiColor(s.color)), path: PKStrokePath(controlPoints: points, creationDate: Date()))
    }

    static func convert(_ s: PKStroke, offset: CGPoint) -> (tool: InkTool, color: String, width: Double, points: [InkPoint]) {
        let tool: InkTool = switch s.ink.inkType {
        case .pencil: .pencil
        case .marker: .highlighter
        case .monoline: .marker
        case .fountainPen: .fountain
        case .watercolor: .brush
        default: .pen
        }
        let raw = Array(s.path)
        let sizes = raw.map { Double(max($0.size.width, $0.size.height)) }
        let width = tool.usesPressure ? max(sizes.max() ?? 2, 0.5) : max(sizes.reduce(0, +) / Double(max(1, sizes.count)), 0.5)
        let points = zip(raw, sizes).map { p, size in
            let at = p.location.applying(s.transform)
            let pressure = tool.usesPressure ? min(1, max(0, (size / width - 0.35) / 0.65)) : 0.5
            return InkPoint(x: at.x - offset.x, y: at.y - offset.y, pressure: pressure, t: p.timeOffset * 1000)
        }
        return (tool, hex(s.ink.color), width, points)
    }

    /// PencilKit strokes have no ids, so they're matched by their points.
    static func signature(_ s: PKStroke) -> String {
        // Without copying the path: this runs for every stroke on each update.
        let path = s.path, n = path.count
        let first = n > 0 ? path[0].location : .zero, last = n > 0 ? path[n - 1].location : .zero
        return "\(n)-\(Int(first.x * 10)),\(Int(first.y * 10))-\(Int(last.x * 10)),\(Int(last.y * 10))"
    }

    // MARK: Coordinator

    /// A page's place on the canvas, in canvas points at 100 %.
    struct Slot {
        var spec: InkPageSpec
        var index: Int
        var frame: CGRect
        /// Canvas points = page points + offset.
        var offset: CGPoint { spec.infinite ? CGPoint(x: spec.origin, y: spec.origin) : frame.origin }
    }

    @MainActor
    final class Coordinator: NSObject, PKCanvasViewDelegate, UIPencilInteractionDelegate, UIGestureRecognizerDelegate {
        var editor: InkEditorModel
        /// Paper, PDF pages and pictures for what's on screen.
        let paperView = InkAreaView()
        /// Text boxes, the lasso, the selection, the eraser and the laser, over the ink.
        let overlayView = InkAreaView()
        var toolGesture: InkToolGesture?
        var holdWatcher: HoldWatcher?
        var swipes: [UISwipeGestureRecognizer] = []
        var handledZoom: UUID?
        var updating = false
        var shownOverlay = -1
        var shownTool = ""
        /// How each stroke on the canvas looked when put there (`InkLine.stamp`), so an update only
        /// replaces what changed instead of rebuilding the whole drawing (which redraws every tile).
        private var shownStamps: [String: String] = [:]
        /// Strokes whose rough line was replaced in the model (a snapped shape): redraw them.
        private var stale: Set<String> = []
        private(set) var slots: [Slot] = []
        private var layoutMode: InkPageLayout = .vertical
        private var shownSig = ""
        private var fittedWidth: CGFloat = 0
        private var zoomedByHand = false
        /// The page index this canvas last showed as current (so a jump from the page list scrolls there).
        private var shownCurrent = -1
        /// Signature → Trove stroke id for what's on the canvas.
        private var ids: [String: String] = [:]
        private var shownVersion = -1
        private var applying = false
        private var drawing = false
        /// Ink changed while the pen was down: shown once it lifts, read fresh then (an older copy
        /// kept from before would wipe the stroke just drawn).
        private var pending = false
        /// Strokes just drawn that haven't reached the model yet (it hears of them a moment later).
        private var handingOver: Set<String> = []
        /// A Trove tool's gesture stays on the page it started on.
        private var toolSlot: Slot?
        /// File pages (PDF, image) as pictures, made for pages on or near the screen.
        private var bitmaps: [String: CGImage] = [:]
        private var rendering: Set<String> = []
        static let gap: CGFloat = 24, margin: CGFloat = 24

        init(editor: InkEditorModel) {
            self.editor = editor
            super.init()
            paperView.painter = { [weak self] ctx, area, scale in self?.drawUnder(ctx, area: area, scale: scale) }
            overlayView.painter = { [weak self] ctx, area, scale in self?.drawOver(ctx, area: area, scale: scale) }
        }

        private var isEndless: Bool { slots.first?.spec.infinite ?? false }

        // MARK: Pages on the canvas

        /// Places the pages for the layout (only the current one when flipping).
        func show(_ pages: [InkPageSpec], current: Int, layout: InkPageLayout, revision: Int, in canvas: TroveCanvasView) {
            let flip = layout == .flip
            let sig = "\(revision)|\(layout.rawValue)|\(pages.map { "\($0.key):\($0.width)x\($0.height)" }.joined(separator: ","))|\(flip ? current : -1)"
            let turned = flip && layoutMode == .flip && shownCurrent >= 0 && shownCurrent != current && sig != shownSig
            let wasEndless = isEndless
            if sig != shownSig {
                let previous = shownSig
                shownSig = sig
                layoutMode = layout
                var out: [Slot] = []
                if let first = pages.first, first.infinite {
                    out = [Slot(spec: first, index: 0, frame: CGRect(x: 0, y: 0, width: first.width, height: first.height))]
                } else if flip, pages.indices.contains(current) {
                    let p = pages[current]
                    out = [Slot(spec: p, index: current, frame: CGRect(x: Self.margin, y: Self.margin, width: p.width, height: p.height))]
                } else if layout == .horizontal {
                    let tallest = pages.map(\.height).max() ?? 0
                    var x = Self.margin
                    for (i, p) in pages.enumerated() {
                        out.append(Slot(spec: p, index: i, frame: CGRect(x: x, y: Self.margin + (tallest - p.height) / 2, width: p.width, height: p.height)))
                        x += p.width + Self.gap
                    }
                } else {
                    let widest = pages.map(\.width).max() ?? 0
                    var y = Self.margin
                    for (i, p) in pages.enumerated() {
                        out.append(Slot(spec: p, index: i, frame: CGRect(x: Self.margin + (widest - p.width) / 2, y: y, width: p.width, height: p.height)))
                        y += p.height + Self.gap
                    }
                }
                slots = out
                ids = [:]
                shownStamps = [:]
                shownVersion = -1
                bitmaps = bitmaps.filter { k, _ in pages.contains { $0.key == k } }
                if previous.isEmpty || isEndless != wasEndless { fittedWidth = 0 }
                resize(canvas)
                if turned {
                    UIView.transition(with: canvas, duration: 0.38, options: [current > shownCurrent ? .transitionCurlUp : .transitionCurlDown, .allowAnimatedContent]) {}
                }
            }
            if fittedWidth == 0 || canvas.bounds.width != fittedWidth { self.layout(canvas) }
            if current != shownCurrent {
                let first = shownCurrent < 0
                shownCurrent = current
                if !flip && !isEndless, let slot = slots.first(where: { $0.index == current }), !first || current > 0 { scroll(to: slot, in: canvas, animated: !first) }
            }
        }

        /// Fits the page in view (and again on rotation), unless zoomed by hand.
        func layout(_ canvas: TroveCanvasView) {
            guard !slots.isEmpty, canvas.bounds.width > 0 else { return }
            if fittedWidth != canvas.bounds.width {
                let first = fittedWidth == 0
                fittedWidth = canvas.bounds.width
                if isEndless {
                    if first {
                        canvas.zoomScale = 1
                        let o = slots[0].offset
                        canvas.setContentOffset(CGPoint(x: o.x - 40, y: o.y - 40), animated: false)
                    }
                } else if first || !zoomedByHand {
                    canvas.zoomScale = fit(editor.fitWholePage, in: canvas)
                    if let slot = slots.first(where: { $0.index == editor.page }) ?? slots.first { scroll(to: slot, in: canvas, animated: false) }
                }
                let z = Double(canvas.zoomScale)
                DispatchQueue.main.async { [weak self] in self?.editor.zoom = z }
            }
            resize(canvas)
        }

        /// The zoom that shows the whole current page, or its width.
        private func fit(_ whole: Bool, in canvas: UIScrollView) -> CGFloat {
            guard let slot = slots.first(where: { $0.index == editor.page }) ?? slots.first else { return 1 }
            let w = max(100, canvas.bounds.width - Self.margin * 2), h = max(100, canvas.bounds.height - Self.margin * 2)
            let z = whole ? min(w / slot.frame.width, h / slot.frame.height) : w / slot.frame.width
            return min(InkEditorModel.maxZoom, max(InkEditorModel.minZoom, z))
        }

        func zoom(_ kind: InkZoomRequest.Kind, in canvas: TroveCanvasView) {
            switch kind {
            case .scale(let z):
                zoomedByHand = true
                canvas.setZoomScale(min(InkEditorModel.maxZoom, max(InkEditorModel.minZoom, z)), animated: true)
            case .wholePage, .pageWidth:
                zoomedByHand = false
                canvas.setZoomScale(fit(kind == .wholePage, in: canvas), animated: true)
                if let slot = slots.first(where: { $0.index == editor.page }) { scroll(to: slot, in: canvas, animated: true) }
            }
        }

        private func scroll(to slot: Slot, in canvas: UIScrollView, animated: Bool) {
            let z = canvas.zoomScale
            let x = layoutMode == .horizontal ? slot.frame.minX * z - Self.margin : canvas.contentOffset.x
            let y = layoutMode == .horizontal ? canvas.contentOffset.y : slot.frame.minY * z - Self.margin
            let maxX = max(-canvas.contentInset.left, canvas.contentSize.width - canvas.bounds.width + canvas.contentInset.right)
            let maxY = max(-canvas.contentInset.top, canvas.contentSize.height - canvas.bounds.height + canvas.contentInset.bottom)
            canvas.setContentOffset(CGPoint(x: min(maxX, max(-canvas.contentInset.left, x)), y: min(maxY, max(-canvas.contentInset.top, y))), animated: animated)
        }

        private func resize(_ canvas: UIScrollView) {
            guard !slots.isEmpty else { return }
            let z = canvas.zoomScale
            let box = slots.reduce(CGRect.null) { $0.union($1.frame) }
            let size = isEndless
                ? CGSize(width: box.width * z, height: box.height * z)
                : CGSize(width: (box.maxX + Self.margin) * z, height: (box.maxY + Self.margin) * z)
            if canvas.contentSize != size { canvas.contentSize = size }
            // Centre pages smaller than the view.
            let left = isEndless ? 0 : max(0, (canvas.bounds.width - size.width) / 2)
            let top = isEndless || layoutMode == .vertical ? 0 : max(0, (canvas.bounds.height - size.height) / 2)
            let inset = UIEdgeInsets(top: top, left: left, bottom: 0, right: left)
            if canvas.contentInset != inset { canvas.contentInset = inset }
            follow(canvas)
        }

        /// The paper and overlay cover what's on screen.
        private func follow(_ canvas: UIScrollView) {
            let visible = canvas.bounds
            for v in [paperView, overlayView] {
                v.frame = visible
                v.zoom = canvas.zoomScale
            }
            paperView.setNeedsDisplay()
            // The overlay is usually empty (no text boxes, lasso or eraser): then it needn't redraw.
            let z0 = max(0.01, canvas.zoomScale)
            let area = InkGeometry.Rect(x: visible.minX / z0, y: visible.minY / z0, width: visible.width / z0, height: visible.height / z0)
            if overlayHasContent(area) || overlayView.drewSomething { overlayView.setNeedsDisplay() }
            let z = canvas.zoomScale
            if isEndless, let slot = slots.first {
                editor.visibleCenter = InkPoint(x: visible.midX / z - slot.offset.x, y: visible.midY / z - slot.offset.y)
            }
            prepareBitmaps(visible: CGRect(x: visible.minX / z, y: visible.minY / z, width: visible.width / z, height: visible.height / z))
        }

        /// The page under a canvas point (at 100 %), or the nearest one.
        private func slot(at p: CGPoint) -> Slot? {
            if let hit = slots.first(where: { $0.frame.insetBy(dx: -Self.gap / 2, dy: -Self.gap / 2).contains(p) }) { return hit }
            return slots.min { a, b in distance(a.frame, p) < distance(b.frame, p) }
        }

        private func distance(_ r: CGRect, _ p: CGPoint) -> CGFloat {
            hypot(max(r.minX - p.x, 0, p.x - r.maxX), max(r.minY - p.y, 0, p.y - r.maxY))
        }

        /// The page most in view becomes the current one (new pages, pictures and pastes go there).
        private func trackCurrent(_ canvas: UIScrollView) {
            guard layoutMode != .flip, !isEndless, slots.count > 1, !updating else { return }
            let z = canvas.zoomScale
            let probe = CGPoint(x: (canvas.bounds.minX + canvas.bounds.width / 3) / z, y: (canvas.bounds.minY + canvas.bounds.height / 3) / z)
            guard let s = slot(at: probe), s.index != editor.page else { return }
            shownCurrent = s.index
            let index = s.index
            DispatchQueue.main.async { [weak self] in self?.editor.page = index }
        }

        // MARK: Drawing under and over the ink

        private func visibleSlots(_ area: InkGeometry.Rect) -> [Slot] {
            let r = CGRect(x: area.x, y: area.y, width: area.width, height: area.height)
            return slots.filter { $0.frame.intersects(r) }
        }

        private func drawUnder(_ ctx: CGContext, area: InkGeometry.Rect, scale: Double) {
            for slot in visibleSlots(area) {
                let o = slot.offset
                ctx.saveGState()
                if !slot.spec.infinite {
                    // A thin edge under the page: a blurred shadow is redrawn on every scroll frame and costs battery.
                    let edge = 1 / scale
                    ctx.setFillColor(UIColor.black.withAlphaComponent(0.08).cgColor)
                    ctx.fill(slot.frame.insetBy(dx: -edge, dy: -edge).offsetBy(dx: 0, dy: edge))
                    ctx.setFillColor(UIColor.white.cgColor)
                    ctx.fill(slot.frame)
                    ctx.clip(to: slot.frame)
                }
                ctx.translateBy(x: o.x, y: o.y)
                let local = InkGeometry.Rect(x: area.x - o.x, y: area.y - o.y, width: area.width, height: area.height)
                switch slot.spec.background {
                case .paper:
                    InkRenderer.drawBackground(slot.spec, area: local, in: ctx)
                case .pdf, .image, .goodnotes:
                    if let image = bitmaps[slot.spec.key] {
                        InkRenderer.drawImage(image, in: CGRect(x: 0, y: 0, width: slot.spec.width, height: slot.spec.height), ctx: ctx)
                    }
                }
                let c = editor.display(slot.spec.key)
                InkRenderer.drawPictures(c.elements, pictures: c.pictures, in: ctx)
                ctx.restoreGState()
            }
        }

        private func overlayHasContent(_ area: InkGeometry.Rect) -> Bool {
            visibleSlots(area).contains { slot in
                let o = editor.overlay(slot.spec.key)
                return o.eraser != nil || !o.lasers.isEmpty || !o.lasso.isEmpty || o.selection != nil || o.tape != nil || o.tip != nil
                    || editor.display(slot.spec.key).elements.contains { $0.kind == .text || $0.kind == .tape }
            }
        }

        private func drawOver(_ ctx: CGContext, area: InkGeometry.Rect, scale: Double) {
            overlayView.drewSomething = overlayHasContent(area)
            for slot in visibleSlots(area) {
                let o = slot.offset
                ctx.saveGState()
                ctx.translateBy(x: o.x, y: o.y)
                let shown = editor.display(slot.spec.key)
                InkRenderer.drawTexts(shown.elements, in: ctx)
                // Tape covers the ink (PencilKit's, underneath this view) too.
                InkRenderer.drawTapes(shown.elements, peeked: shown.peeked, in: ctx)
                InkRenderer.drawOverlay(editor.overlay(slot.spec.key), scale: scale, in: ctx)
                ctx.restoreGState()
            }
        }

        /// File pages near the screen are made into pictures (once each); far ones are let go.
        private func prepareBitmaps(visible: CGRect) {
            let near = visible.insetBy(dx: -visible.width, dy: -visible.height)
            for slot in slots {
                let key = slot.spec.key
                switch slot.spec.background {
                case .paper:
                    continue
                case .pdf, .image, .goodnotes:
                    guard slot.frame.intersects(near) else { bitmaps[key] = nil; continue }
                    guard bitmaps[key] == nil, !rendering.contains(key) else { continue }
                    rendering.insert(key)
                    let spec = slot.spec
                    let pixels = Int(min(2400, spec.width * 2.5))
                    Task { [weak self] in
                        let rendered = await Task.detached(priority: .userInitiated) { InkRenderer.render(spec, content: InkContent(), pixelWidth: pixels).map(InkImage.init) }.value
                        guard let self else { return }
                        self.rendering.remove(key)
                        if let rendered { self.bitmaps[key] = rendered.image; self.paperView.setNeedsDisplay() }
                    }
                }
            }
        }

        // MARK: Ink

        /// Shows every page's strokes, unless the canvas already has this version of them. Strokes
        /// that look the same are kept as they are; the drawing is replaced only when something differs.
        func apply(version: Int, to canvas: PKCanvasView) {
            guard version != shownVersion else { return }
            if drawing { pending = true; return }
            paperView.setNeedsDisplay()
            var want: [(id: String, stamp: String, line: InkLine, offset: CGPoint)] = []
            for slot in slots {
                for line in editor.display(slot.spec.key).strokes where !line.points.isEmpty { want.append((line.id, line.stamp, line, slot.offset)) }
            }
            let modelIds = Set(want.map(\.id))
            let current = canvas.drawing.strokes
            var onCanvas: [String: PKStroke] = [:]
            var order: [String] = []
            var kept: [PKStroke] = []
            for s in current {
                let sig = PencilCanvas.signature(s)
                guard let id = ids[sig] else { continue }
                if modelIds.contains(id) { onCanvas[id] = s; order.append(id) }
                // Just drawn and still on its way to the model: keep it.
                else if handingOver.contains(id) { kept.append(s) }
            }
            func unchanged(_ w: (id: String, stamp: String, line: InkLine, offset: CGPoint)) -> Bool {
                guard onCanvas[w.id] != nil, !stale.contains(w.id) else { return false }
                // A stroke PencilKit drew itself: it is what the model has.
                return (shownStamps[w.id] ?? w.stamp) == w.stamp
            }
            if order == want.map(\.id), kept.count == current.count - order.count, want.allSatisfy(unchanged) {
                for w in want { shownStamps[w.id] = w.stamp }
                shownVersion = version
                return
            }
            applying = true
            var pk: [PKStroke] = []
            var map: [String: String] = [:]
            var stamps: [String: String] = [:]
            for w in want {
                let stroke = unchanged(w) ? onCanvas[w.id] : PencilCanvas.pkStroke(w.line, offset: w.offset)
                guard let stroke else { continue }
                pk.append(stroke)
                map[PencilCanvas.signature(stroke)] = w.id
                stamps[w.id] = w.stamp
            }
            for s in kept {
                let sig = PencilCanvas.signature(s)
                pk.append(s)
                if let id = ids[sig] { map[sig] = id }
            }
            canvas.drawing = PKDrawing(strokes: pk)
            ids = map
            shownStamps = stamps
            stale = []
            shownVersion = version
            applying = false
        }

        func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) { drawing = true }

        func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
            drawing = false
            guard pending else { return }
            pending = false
            // After PencilKit has reported the new stroke (it does so before or after this call).
            DispatchQueue.main.async { [weak self, weak canvasView] in
                guard let self, let canvasView, !self.drawing else { return }
                self.canvasViewDrawingDidChange(canvasView)
                self.shownVersion = -1
                self.apply(version: self.editor.revision, to: canvasView)
            }
        }

        /// New strokes are added to Trove (snapped into shapes, or a scratch-out, if asked); others'
        /// changes are applied from the model, so this only ever adds.
        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            guard !applying, !slots.isEmpty else { return }
            var added: [PKStroke] = []
            for s in canvasView.drawing.strokes where ids[PencilCanvas.signature(s)] == nil { added.append(s) }
            guard !added.isEmpty else { return }
            // Trove's copies, made now; saved a moment later, once the hold watcher has seen the pen lift.
            var strokes: [(signature: String, id: String, key: String, ink: (tool: InkTool, color: String, width: Double, points: [InkPoint]))] = []
            for s in added {
                guard let start = Array(s.path).first?.location.applying(s.transform), let slot = slot(at: start) else { continue }
                strokes.append((PencilCanvas.signature(s), UUID().uuidString.lowercased(), slot.spec.key, PencilCanvas.convert(s, offset: slot.offset)))
            }
            for s in strokes { ids[s.signature] = s.id; handingOver.insert(s.id) }
            Task { @MainActor [weak self] in
                guard let self else { return }
                let held = self.holdWatcher?.takeHeld() ?? false
                // Pencil Pro's barrel roll turns the fountain pen's and brush's nib (kept as the stroke's angle).
                let roll = self.holdWatcher?.takeRoll()
                for s in strokes {
                    self.handingOver.remove(s.id)
                    let c = s.ink
                    // Snapped or scribbled out: show what was kept instead of the rough line.
                    let nib: Double? = c.tool == .fountain || c.tool == .brush ? roll.map { InkGeometry.nibAngle + $0 } : nil
                    if self.editor.addStroke(points: c.points, tool: c.tool, color: c.color, width: c.width, id: s.id, pageKey: s.key, held: held, nib: nib) {
                        self.stale.insert(s.id)
                        self.shownVersion = -1
                    }
                }
            }
        }

        func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) { zoomedByHand = true }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            resize(scrollView)
            let z = Double(scrollView.zoomScale)
            if !updating, abs(z - editor.zoom) > 0.004 { DispatchQueue.main.async { [weak self] in self?.editor.zoom = z } }
        }

        func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
            let z = Double(scale)
            DispatchQueue.main.async { [weak self] in self?.editor.zoom = z }
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            follow(scrollView)
            trackCurrent(scrollView)
        }

        // MARK: Trove's tools: eraser, lasso, laser, text

        func toolTouch(_ phase: UITouch.Phase, at point: CGPoint, in canvas: PKCanvasView) {
            let z = canvas.zoomScale
            let at = CGPoint(x: point.x / z, y: point.y / z)
            if phase == .began { toolSlot = slot(at: at) }
            guard let slot = toolSlot else { return }
            let p = InkPoint(x: at.x - slot.offset.x, y: at.y - slot.offset.y)
            switch phase {
            case .began:
                if slot.index != editor.page { shownCurrent = slot.index; editor.page = slot.index }
                editor.pointerDown(p, pageKey: slot.spec.key, scale: z)
            case .moved: editor.pointerMoved(p)
            case .ended: editor.pointerUp(); toolSlot = nil
            default: editor.pointerCancelled(); toolSlot = nil
            }
            overlayView.setNeedsDisplay()
        }

        @objc func undoTap() { editor.undo() }

        /// A hovering Pencil: its point on the page under it (nil when it leaves or touches down).
        @objc func hovered(_ g: UIHoverGestureRecognizer) {
            guard let canvas = g.view as? UIScrollView else { return }
            var near = true
            if #available(iOS 16.1, *) { near = g.zOffset < 1 }
            switch g.state {
            case .began, .changed:
                let z = canvas.zoomScale
                let p = g.location(in: canvas)
                let at = CGPoint(x: p.x / z, y: p.y / z)
                guard near, let slot = slot(at: at) else { editor.pencilHover(nil, pageKey: nil, scale: z); break }
                editor.pencilHover(InkPoint(x: at.x - slot.offset.x, y: at.y - slot.offset.y), pageKey: slot.spec.key, scale: z)
            default:
                editor.pencilHover(nil, pageKey: nil, scale: canvas.zoomScale)
            }
            overlayView.setNeedsDisplay()
        }
        @objc func redoTap() { editor.redo() }

        @objc func swiped(_ g: UISwipeGestureRecognizer) {
            guard layoutMode == .flip, let canvas = g.view as? UIScrollView else { return }
            // Only when the whole page is in view; zoomed in, a swipe scrolls.
            guard canvas.contentSize.width <= canvas.bounds.width + 2 else { return }
            let next = g.direction == .left ? editor.page + 1 : editor.page - 1
            if editor.pages.indices.contains(next) { editor.page = next }
        }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

        // MARK: Apple Pencil double-tap and squeeze

        /// What the person chose for the Pencil (Settings → Apple Pencil), like GoodNotes and Notes.
        private func perform(_ action: UIPencilPreferredAction, at location: CGPoint?, in view: UIView?) {
            switch action {
            case .switchEraser: editor.pencilTap(switchEraser: true)
            case .switchPrevious: editor.pencilTap(switchEraser: false)
            case .ignore, .runSystemShortcut: break
            default:
                // The contextual palette, the colour palette and ink attributes: Trove's palette at the tip.
                let origin = (view as? UIScrollView)?.contentOffset ?? .zero
                let size = view?.bounds.size ?? .zero
                let p = location.map { CGPoint(x: $0.x - origin.x, y: $0.y - origin.y) } ?? CGPoint(x: size.width / 2, y: size.height / 2)
                editor.palette = editor.palette == nil ? p : nil
            }
        }

        func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
            perform(UIPencilInteraction.preferredTapAction, at: tap.hoverPose?.location, in: interaction.view)
        }

        func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
            guard squeeze.phase == .ended else { return }
            perform(UIPencilInteraction.preferredSqueezeAction, at: squeeze.hoverPose?.location, in: interaction.view)
        }
    }
}

/// PencilKit's canvas, telling us when it lays out (to fit the page on rotation).
final class TroveCanvasView: PKCanvasView {
    var onLayout: (@MainActor () -> Void)?
    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
    }
}

/// A view over what's on screen of the zoomed canvas, drawing in canvas points at 100 %.
final class InkAreaView: UIView {
    var painter: ((CGContext, InkGeometry.Rect, Double) -> Void)?
    var zoom: CGFloat = 1
    /// Whether the last draw put anything on screen (an empty overlay needn't redraw while scrolling).
    var drewSomething = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let z = Double(max(0.01, zoom))
        // This view sits at frame.origin in the zoomed content; canvas points are content / zoom.
        ctx.translateBy(x: -frame.minX, y: -frame.minY)
        ctx.scaleBy(x: z, y: z)
        let area = InkGeometry.Rect(x: Double(frame.minX) / z, y: Double(frame.minY) / z, width: Double(frame.width) / z, height: Double(frame.height) / z)
        painter?(ctx, area, z)
    }
}

/// One finger or the Pencil working Trove's eraser, lasso, laser or text tool (PencilKit's drawing is off then).
final class InkToolGesture: UIGestureRecognizer {
    var onTouch: ((UITouch.Phase, CGPoint) -> Void)?
    private weak var touch: UITouch?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard touch == nil, touches.count == 1, let t = touches.first else {
            // A second finger: let the canvas scroll and zoom instead.
            if touch != nil { onTouch?(.cancelled, .zero); touch = nil; state = .cancelled } else { state = .failed }
            return
        }
        touch = t
        state = .began
        onTouch?(.began, t.location(in: view))
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let t = touch, touches.contains(t) else { return }
        for c in event.coalescedTouches(for: t) ?? [t] { onTouch?(.moved, c.location(in: view)) }
        state = .changed
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let t = touch, touches.contains(t) else { return }
        onTouch?(.ended, t.location(in: view))
        touch = nil
        state = .ended
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        guard touch != nil else { return }
        onTouch?(.cancelled, .zero)
        touch = nil
        state = .cancelled
    }

    override func reset() {
        super.reset()
        touch = nil
    }
}

/// Watches the Pencil (or finger) while PencilKit draws, to notice it held still at the end of a
/// line: that stroke becomes a clean shape. It never takes the touches itself.
final class HoldWatcher: UIGestureRecognizer {
    private var lastMove = Date()
    private var lastPoint = CGPoint.zero
    private var held = false
    /// Barrel roll (Apple Pencil Pro) seen during the last line, radians.
    private var rolls: [Double] = []

    /// The last line's average barrel roll, if the Pencil reported one (and forget it).
    func takeRoll() -> Double? {
        defer { rolls = [] }
        guard !rolls.isEmpty else { return nil }
        let points = rolls.map { InkPoint(x: 0, y: 0, angle: $0) }
        return InkOutline.meanNib(points)
    }

    private func noteRoll(_ t: UITouch) {
        if #available(iOS 17.5, *), t.type == .pencil { rolls.append(Double(t.rollAngle)) }
    }

    /// Whether the last line ended with a hold (and forget it).
    func takeHeld() -> Bool {
        defer { held = false }
        return held
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let t = touches.first else { return }
        lastMove = Date()
        lastPoint = t.location(in: view)
        held = false
        rolls = []
        noteRoll(t)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let t = touches.first else { return }
        noteRoll(t)
        let p = t.location(in: view)
        if hypot(p.x - lastPoint.x, p.y - lastPoint.y) > 3 { lastMove = Date(); lastPoint = p }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        held = Date().timeIntervalSince(lastMove) >= InkEditorModel.holdToSnap
        state = .failed
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        held = false
        state = .failed
    }
}
#endif
