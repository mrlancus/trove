#if os(iOS)
import PencilKit
import SwiftUI
import TroveCore
import UIKit
import UIKit.UIGestureRecognizerSubclass

/// The drawing surface on iPhone and iPad. Pens are PencilKit's, so Apple Pencil gets its
/// pressure, tilt, low latency and palm rejection (a finger draws on iPhone). The eraser, lasso and
/// text tools are Trove's own (`InkToolGesture` → the editor model), so they act on the shared
/// strokes exactly like the website and the Mac. Paper, PDF pages and pictures sit underneath; text
/// boxes, the lasso and the selection are drawn on top. Holding the pen still at the end of a line
/// snaps it into a shape; tapping with two fingers undoes and with three redoes.
struct PencilCanvas: UIViewRepresentable {
    let editor: InkEditorModel
    let page: InkPageSpec
    let pagesRevision: Int
    let revision: Int
    let overlayRevision: Int
    let tool: InkEditorTool
    let color: String
    let width: Double

    func makeCoordinator() -> Coordinator { Coordinator(editor: editor) }

    func makeUIView(context: Context) -> TroveCanvasView {
        let canvas = TroveCanvasView()
        let c = context.coordinator
        canvas.delegate = c
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.overrideUserInterfaceStyle = .light // keep ink colours true on white paper
        canvas.drawingPolicy = UIDevice.current.userInterfaceIdiom == .pad ? .default : .anyInput
        canvas.showsVerticalScrollIndicator = true
        canvas.contentInsetAdjustmentBehavior = .never
        canvas.insertSubview(c.backgroundView, at: 0)
        canvas.insertSubview(c.paperView, at: 0)
        canvas.addSubview(c.overlayView)
        canvas.addInteraction(UIPencilInteraction(delegate: c))
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
            canvas.addGestureRecognizer(tap)
        }
        return canvas
    }

    func updateUIView(_ canvas: TroveCanvasView, context: Context) {
        let c = context.coordinator
        c.editor = editor
        c.show(page, key: "\(page.key)-\(pagesRevision)-\(page.width)x\(page.height)", in: canvas)
        c.apply(editor.display(page.key), version: revision, to: canvas)
        c.overlayView.setNeedsDisplay()
        let pen = tool.ink != nil
        if let ink = tool.ink { canvas.tool = Self.pkTool(ink, color: color, width: width) }
        canvas.drawingGestureRecognizer.isEnabled = pen
        c.toolGesture?.isEnabled = !pen
        // Where a finger draws (iPhone), it also works the lasso and eraser; two fingers scroll.
        let fingers = canvas.drawingPolicy == .anyInput || !UIPencilInteraction.prefersPencilOnlyDrawing
        c.toolGesture?.allowedTouchTypes = fingers
            ? [NSNumber(value: UITouch.TouchType.pencil.rawValue), NSNumber(value: UITouch.TouchType.direct.rawValue)]
            : [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        canvas.panGestureRecognizer.minimumNumberOfTouches = !pen && fingers ? 2 : 1
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

    /// A Trove stroke as PencilKit's, moved by the page's origin (the endless canvas).
    static func pkStroke(_ s: InkLine, origin: Double) -> PKStroke {
        let inkType: PKInk.InkType = switch s.tool {
        case .pen: .pen
        case .pencil: .pencil
        case .marker: .monoline
        case .highlighter: .marker
        case .fountain: .fountainPen
        case .brush: .watercolor
        }
        let points = s.points.map { p in
            let w = s.shape != nil ? s.width : InkStroke.width(s.width, tool: s.tool, pressure: p.pressure)
            return PKStrokePoint(location: CGPoint(x: p.x + origin, y: p.y + origin), timeOffset: p.t / 1000, size: CGSize(width: w, height: w),
                                 opacity: 1, force: p.pressure * 2, azimuth: 0, altitude: .pi / 2)
        }
        return PKStroke(ink: PKInk(inkType, color: uiColor(s.color)), path: PKStrokePath(controlPoints: points, creationDate: Date()))
    }

    static func convert(_ s: PKStroke, origin: Double) -> (tool: InkTool, color: String, width: Double, points: [InkPoint]) {
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
            return InkPoint(x: at.x - origin, y: at.y - origin, pressure: pressure, t: p.timeOffset * 1000)
        }
        return (tool, hex(s.ink.color), width, points)
    }

    /// PencilKit strokes have no ids, so they're matched by their points.
    static func signature(_ s: PKStroke) -> String {
        let pts = Array(s.path)
        let first = pts.first?.location ?? .zero, last = pts.last?.location ?? .zero
        return "\(pts.count)-\(Int(first.x * 10)),\(Int(first.y * 10))-\(Int(last.x * 10)),\(Int(last.y * 10))"
    }

    // MARK: Coordinator

    @MainActor
    final class Coordinator: NSObject, PKCanvasViewDelegate, UIPencilInteractionDelegate, UIGestureRecognizerDelegate {
        var editor: InkEditorModel
        /// A page's paper, PDF page or image, with its pictures (a bitmap).
        let backgroundView = UIImageView()
        /// The endless canvas's paper, drawn for what's on screen.
        let paperView = InkAreaView()
        /// Text boxes, the lasso, the selection and the eraser, over the ink.
        let overlayView = InkAreaView()
        var toolGesture: InkToolGesture?
        var holdWatcher: HoldWatcher?
        private var page: InkPageSpec?
        private var pageKey = ""
        private var fittedWidth: CGFloat = 0
        /// Signature → Trove stroke id for what's on the canvas.
        private var ids: [String: String] = [:]
        private var shownVersion = -1
        private var applying = false
        private var drawing = false
        /// Ink changed while the pen was down: show it once the pen lifts, read fresh then (an older
        /// copy kept from before would wipe the stroke just drawn).
        private var pending = false
        /// Strokes just drawn that haven't reached the model yet (it hears of them a moment later).
        private var handingOver: Set<String> = []
        private var backgroundTask: Task<Void, Never>?
        private var backgroundKey = ""

        init(editor: InkEditorModel) {
            self.editor = editor
            super.init()
            backgroundView.contentMode = .scaleToFill
            backgroundView.backgroundColor = .white
            paperView.isHidden = true
            paperView.painter = { [weak self] ctx, area, scale in self?.drawPaper(ctx, area: area, scale: scale) }
            overlayView.painter = { [weak self] ctx, _, scale in self?.drawOverlay(ctx, scale: scale) }
        }

        private var origin: Double { page?.origin ?? 0 }

        func show(_ spec: InkPageSpec, key: String, in canvas: TroveCanvasView) {
            guard key != pageKey else { refreshBackground(canvas); return }
            let samePage = page?.key == spec.key && page?.infinite == spec.infinite
            pageKey = key
            page = spec
            paperView.isHidden = !spec.infinite
            backgroundView.isHidden = spec.infinite
            if !samePage {
                fittedWidth = 0
                ids = [:]
                shownVersion = -1
                applying = true
                canvas.drawing = PKDrawing()
                applying = false
                backgroundView.image = nil
                layout(canvas)
                if spec.infinite {
                    canvas.setContentOffset(CGPoint(x: (spec.origin - 40) * canvas.zoomScale, y: (spec.origin - 40) * canvas.zoomScale), animated: false)
                } else {
                    canvas.setContentOffset(.zero, animated: false)
                }
            }
            backgroundKey = ""
            refreshBackground(canvas)
        }

        /// Fits the page's width to the view (and again on rotation); zoom from there.
        func layout(_ canvas: TroveCanvasView) {
            guard let page, canvas.bounds.width > 0 else { return }
            if fittedWidth != canvas.bounds.width {
                fittedWidth = canvas.bounds.width
                let fit = page.infinite ? 1 : canvas.bounds.width / page.width
                canvas.minimumZoomScale = page.infinite ? 0.2 : fit * 0.75
                canvas.maximumZoomScale = page.infinite ? 4 : fit * 6
                canvas.zoomScale = fit
            }
            resize(canvas)
        }

        private func resize(_ canvas: PKCanvasView) {
            guard let page else { return }
            let size = CGSize(width: page.width * canvas.zoomScale, height: page.height * canvas.zoomScale)
            if canvas.contentSize != size { canvas.contentSize = size }
            backgroundView.frame = CGRect(origin: .zero, size: size)
            // Centre a page narrower than the view.
            let inset = page.infinite ? 0 : max(0, (canvas.bounds.width - size.width) / 2)
            canvas.contentInset = UIEdgeInsets(top: 0, left: inset, bottom: 0, right: inset)
            follow(canvas)
        }

        /// The paper and overlay cover what's on screen.
        private func follow(_ canvas: UIScrollView) {
            let visible = canvas.bounds
            for v in [paperView, overlayView] {
                v.frame = visible
                v.zoom = canvas.zoomScale
                v.origin = origin
                v.setNeedsDisplay()
            }
            if let page, page.infinite {
                let z = canvas.zoomScale
                editor.visibleCenter = InkPoint(x: visible.midX / z - page.origin, y: visible.midY / z - page.origin)
            }
        }

        /// A page's bitmap: paper or file, with the pictures on it.
        private func refreshBackground(_ canvas: PKCanvasView) {
            guard let page, !page.infinite else { return }
            let pictures = editor.display(page.key).elements.filter { $0.kind == .image }
            let key = pageKey + pictures.map { "\($0.id)\($0.frame.x),\($0.frame.y),\($0.frame.width)" }.joined()
            guard key != backgroundKey else { return }
            backgroundKey = key
            backgroundTask?.cancel()
            let width = max(canvas.bounds.width, 600)
            let pixels = Int(min(4096, width * max(2, UITraitCollection.current.displayScale) * 1.5))
            let content = InkContent(elements: pictures, pictures: editor.pictures)
            backgroundTask = Task { [weak self] in
                let rendered = await Task.detached(priority: .userInitiated) { InkRenderer.render(page, content: content, pixelWidth: pixels).map(InkImage.init) }.value
                guard !Task.isCancelled, let rendered else { return }
                self?.backgroundView.image = UIImage(cgImage: rendered.image)
            }
        }

        private func drawPaper(_ ctx: CGContext, area: InkGeometry.Rect, scale: Double) {
            guard let page else { return }
            InkRenderer.drawBackground(page, area: area, in: ctx)
            let c = editor.display(page.key)
            InkRenderer.drawPictures(c.elements, pictures: c.pictures, in: ctx)
        }

        private func drawOverlay(_ ctx: CGContext, scale: Double) {
            guard let page else { return }
            InkRenderer.drawTexts(editor.display(page.key).elements, in: ctx)
            InkRenderer.drawOverlay(editor.overlay(page.key), scale: scale, in: ctx)
        }

        /// Shows the page's strokes, unless the canvas already has this version of them.
        func apply(_ content: InkContent, version: Int, to canvas: PKCanvasView) {
            refreshBackground(canvas)
            paperView.setNeedsDisplay()
            guard version != shownVersion else { return }
            if drawing { pending = true; return }
            applying = true
            // Keep what was just drawn and is still on its way to the model.
            let modelIds = Set(content.strokes.map(\.id))
            let keep = canvas.drawing.strokes.filter { s in ids[PencilCanvas.signature(s)].map { handingOver.contains($0) && !modelIds.contains($0) } ?? false }
            let kept = keep.map { (PencilCanvas.signature($0), ids[PencilCanvas.signature($0)] ?? "") }
            let pk = content.strokes.map { PencilCanvas.pkStroke($0, origin: origin) }
            canvas.drawing = PKDrawing(strokes: pk + keep)
            ids = Dictionary(zip(pk.map(PencilCanvas.signature), content.strokes.map(\.id)) + kept, uniquingKeysWith: { a, _ in a })
            shownVersion = version
            applying = false
        }

        func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) { drawing = true }

        func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
            drawing = false
            guard pending, let page else { return }
            pending = false
            // After PencilKit has reported the new stroke (it does so before or after this call),
            // so the stroke is in the model by the time the canvas is redrawn from it.
            DispatchQueue.main.async { [weak self, weak canvasView] in
                guard let self, let canvasView, !self.drawing, self.page?.key == page.key else { return }
                self.canvasViewDrawingDidChange(canvasView)
                self.shownVersion = -1
                self.apply(self.editor.display(page.key), version: self.editor.revision, to: canvasView)
            }
        }

        /// New strokes are added to Trove (snapped into shapes if asked); others' changes are applied
        /// from the model, so this only ever adds.
        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            guard !applying, let page else { return }
            var added: [PKStroke] = []
            for s in canvasView.drawing.strokes where ids[PencilCanvas.signature(s)] == nil { added.append(s) }
            guard !added.isEmpty else { return }
            let key = page.key, origin = origin
            // Trove's copies, made now; saved a moment later, once the hold watcher has seen the pen lift.
            let strokes = added.map { s in (signature: PencilCanvas.signature(s), id: UUID().uuidString.lowercased(), ink: PencilCanvas.convert(s, origin: origin)) }
            for s in strokes { ids[s.signature] = s.id; handingOver.insert(s.id) }
            Task { @MainActor [weak self] in
                guard let self else { return }
                let held = self.holdWatcher?.takeHeld() ?? false
                for s in strokes {
                    self.handingOver.remove(s.id)
                    let c = s.ink
                    if self.editor.addStroke(points: c.points, tool: c.tool, color: c.color, width: c.width, id: s.id, pageKey: key, held: held) != nil {
                        // Snapped: show the clean shape instead of the rough line.
                        self.shownVersion = -1
                    }
                }
            }
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            if let canvas = scrollView as? PKCanvasView { resize(canvas) }
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) { follow(scrollView) }

        // MARK: Trove's tools: eraser, lasso, text

        func toolTouch(_ phase: UITouch.Phase, at point: CGPoint, in canvas: PKCanvasView) {
            guard let page else { return }
            let z = canvas.zoomScale
            let p = InkPoint(x: point.x / z - page.origin, y: point.y / z - page.origin)
            switch phase {
            case .began: editor.pointerDown(p, pageKey: page.key, scale: z)
            case .moved: editor.pointerMoved(p)
            case .ended: editor.pointerUp()
            default: editor.pointerCancelled()
            }
            overlayView.setNeedsDisplay()
        }

        @objc func undoTap() { editor.undo() }
        @objc func redoTap() { editor.redo() }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

        // MARK: Apple Pencil double-tap and squeeze

        func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
            switch UIPencilInteraction.preferredTapAction {
            case .switchEraser: editor.pencilTap(switchEraser: true)
            case .switchPrevious: editor.pencilTap(switchEraser: false)
            default: break
            }
        }

        func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
            guard squeeze.phase == .ended else { return }
            switch UIPencilInteraction.preferredSqueezeAction {
            case .switchEraser: editor.pencilTap(switchEraser: true)
            case .switchPrevious: editor.pencilTap(switchEraser: false)
            default: editor.pencilTap(switchEraser: true)
            }
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

/// A view over what's on screen of a zoomed page, drawing in page points.
final class InkAreaView: UIView {
    var painter: ((CGContext, InkGeometry.Rect, Double) -> Void)?
    var zoom: CGFloat = 1
    var origin: Double = 0

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
        // This view sits at frame.origin in the zoomed content; page points are content / zoom − origin.
        ctx.translateBy(x: -frame.minX, y: -frame.minY)
        ctx.scaleBy(x: z, y: z)
        ctx.translateBy(x: origin, y: origin)
        let area = InkGeometry.Rect(x: Double(frame.minX) / z - origin, y: Double(frame.minY) / z - origin, width: Double(frame.width) / z, height: Double(frame.height) / z)
        painter?(ctx, area, z)
    }
}

/// One finger or the Pencil working Trove's eraser, lasso or text tool (PencilKit's drawing is off then).
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
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let t = touches.first else { return }
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
