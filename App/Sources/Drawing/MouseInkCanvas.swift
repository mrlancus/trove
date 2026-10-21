#if os(macOS)
import AppKit
import SwiftUI
import TroveCore

/// The drawing surface on the Mac: the mouse or trackpad draws (with pressure on Force Touch
/// trackpads and drawing tablets), pinch or ⌘-scroll zooms, and the page's paper, PDF page or
/// image sits underneath. Pens are drawn here (holding still at the end snaps a shape); the eraser,
/// lasso and text tools go to the editor model, like on the website.
struct MouseInkCanvas: NSViewRepresentable {
    let editor: InkEditorModel
    let page: InkPageSpec
    let pageIndex: Int
    let pagesRevision: Int
    let revision: Int
    let overlayRevision: Int
    let tool: InkEditorTool
    let color: String
    let width: Double
    let zoomRequest: InkZoomRequest?

    final class Coordinator {
        var handledZoom: UUID?
        var observer: NSObjectProtocol?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.allowsMagnification = true
        scroll.minMagnification = InkEditorModel.minZoom
        scroll.maxMagnification = InkEditorModel.maxZoom
        scroll.backgroundColor = NSColor.underPageBackgroundColor
        scroll.documentView = InkNSView()
        // The zoom shown bottom left follows pinching and ⌘-scrolling.
        let editor = editor
        context.coordinator.observer = NotificationCenter.default.addObserver(forName: NSScrollView.didEndLiveMagnifyNotification, object: scroll, queue: .main) { [weak scroll] _ in
            let z = Double(scroll?.magnification ?? 1)
            MainActor.assumeIsolated { editor.zoom = z }
        }
        return scroll
    }

    /// The zoom that fits the page (all of it, or its width) in the window.
    private func fit(_ whole: Bool, in scroll: NSScrollView) -> Double {
        let w = Double(scroll.contentSize.width) - 40, h = Double(scroll.contentSize.height) - 40
        let z = whole ? min(w / page.width, h / page.height) : w / page.width
        return min(InkEditorModel.maxZoom, max(InkEditorModel.minZoom, z))
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? InkNSView else { return }
        view.editor = editor
        view.tool = tool
        view.color = color
        view.width = width
        let key = "\(page.key)-\(pagesRevision)-\(page.width)x\(page.height)"
        if view.shownKey != key {
            let newPage = view.page?.key != page.key || view.page?.infinite != page.infinite
            view.show(page, key: key)
            if newPage {
                DispatchQueue.main.async {
                    if page.infinite {
                        scroll.magnification = 1
                        view.scroll(CGPoint(x: page.origin - 40, y: page.origin - 40))
                    } else {
                        scroll.magnification = fit(editor.fitWholePage, in: scroll)
                        view.scroll(.zero)
                    }
                    editor.zoom = Double(scroll.magnification)
                }
            }
        }
        if let zoomRequest, zoomRequest.id != context.coordinator.handledZoom {
            context.coordinator.handledZoom = zoomRequest.id
            let z: Double = switch zoomRequest.kind {
            case .scale(let v): min(InkEditorModel.maxZoom, max(InkEditorModel.minZoom, v))
            case .wholePage: fit(true, in: scroll)
            case .pageWidth: fit(false, in: scroll)
            }
            let editor = editor
            DispatchQueue.main.async {
                scroll.animator().magnification = z
                editor.zoom = z
            }
        }
        view.needsDisplay = true
    }
}

final class InkNSView: NSView {
    var editor: InkEditorModel?
    var tool: InkEditorTool = .pen { didSet { if tool != oldValue { window?.invalidateCursorRects(for: self) } } }
    var color = "#1c1c1e"
    var width = 2.5
    private(set) var page: InkPageSpec?
    private(set) var shownKey = ""
    private var background: CGImage?
    private var points: [InkPoint] = []
    private var started: TimeInterval = 0
    private var pressure = 0.5
    /// Hold-to-snap: when the pen last moved, and whether the line has become a clean shape.
    private var lastMove = Date()
    private var snapped = false
    private var snapTimer: Timer?
    private var drawingPen = false
    /// The pen's settings (stabiliser, pressure curve), applied as points come in so what's stored is what's shown.
    private var filter: PenFilter?
    private var lastRaw: InkPoint?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        pressureConfiguration = NSPressureConfiguration(pressureBehavior: .primaryGeneric)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private var origin: Double { page?.origin ?? 0 }
    private var scale: Double { max(0.05, Double(enclosingScrollView?.magnification ?? 1)) }

    func show(_ spec: InkPageSpec, key: String) {
        if spec.key != page?.key { points = [] }
        shownKey = key
        page = spec
        background = nil
        setFrameSize(NSSize(width: spec.width, height: spec.height))
        guard !spec.infinite else { needsDisplay = true; return }
        let pixels = Int(min(4096, spec.width * 2.5))
        Task { @MainActor [weak self] in
            let rendered = await Task.detached(priority: .userInitiated) { InkRenderer.render(spec, content: InkContent(), pixelWidth: pixels).map(InkImage.init) }.value
            guard let self, self.shownKey == key else { return }
            self.background = rendered?.image
            self.needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, let page, let editor else { return }
        ctx.saveGState()
        ctx.translateBy(x: origin, y: origin)
        if page.infinite {
            let area = InkGeometry.Rect(x: dirtyRect.minX - origin, y: dirtyRect.minY - origin, width: dirtyRect.width, height: dirtyRect.height)
            InkRenderer.drawBackground(page, area: area, in: ctx)
        } else if let background {
            InkRenderer.drawImage(background, in: CGRect(x: 0, y: 0, width: page.width, height: page.height), ctx: ctx)
        } else {
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: page.width, height: page.height))
        }
        drawInk(page, editor: editor, in: ctx)
        // What the lasso is dragging, over the rest: the cached picture of the page stays as it is while it moves.
        if let moving = editor.dragPreview(page.key) { InkRenderer.drawContent(moving, in: ctx) }
        if let ink = tool.ink, !points.isEmpty {
            let style = InkStrokeStyle(dash: editor.dash(for: tool))
            InkRenderer.draw(tool: ink, color: color, width: width, points: points, shape: snapped, style: style, in: ctx)
        }
        InkRenderer.drawOverlay(editor.overlay(page.key), scale: scale, in: ctx)
        ctx.restoreGState()
    }

    /// The finished ink on screen, kept as a picture until it changes, the zoom changes or the view
    /// scrolls: while the pen moves only the new bit of line is drawn, not every stroke again.
    private var inkCache: (key: String, rect: CGRect, image: CGImage)?

    private func drawInk(_ page: InkPageSpec, editor: InkEditorModel, in ctx: CGContext) {
        let visible = visibleRect
        let k = CGFloat(scale) * (window?.backingScaleFactor ?? 2)
        let key = "\(editor.revision)|\(shownKey)|\(scale)"
        if inkCache?.key != key || inkCache?.rect != visible {
            inkCache = nil
            let w = Int((visible.width * k).rounded(.up)), h = Int((visible.height * k).rounded(.up))
            if w > 0, h > 0, w * h <= 40_000_000,
               let bitmap = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                // The same y-down page coordinates as this (flipped) view.
                bitmap.translateBy(x: 0, y: CGFloat(h))
                bitmap.scaleBy(x: k, y: -k)
                bitmap.translateBy(x: -visible.minX + origin, y: -visible.minY + origin)
                InkRenderer.drawContent(editor.display(page.key, lifted: true), in: bitmap)
                if let image = bitmap.makeImage() { inkCache = (key, visible, image) }
            }
        }
        guard let cache = inkCache else { InkRenderer.drawContent(editor.display(page.key, lifted: true), in: ctx); return }
        InkRenderer.drawImage(cache.image, in: cache.rect.offsetBy(dx: -origin, dy: -origin), ctx: ctx)
    }

    /// Only the end of the line being drawn needs redrawing.
    private func invalidateTail() {
        let tail = points.suffix(3)
        guard let first = tail.first else { needsDisplay = true; return }
        var r = CGRect(x: first.x, y: first.y, width: 0, height: 0)
        for p in tail { r = r.union(CGRect(x: p.x, y: p.y, width: 0, height: 0)) }
        let pad = CGFloat(width * 1.5 + 6)
        setNeedsDisplay(r.offsetBy(dx: origin, dy: origin).insetBy(dx: -pad, dy: -pad))
    }

    private func location(_ event: NSEvent) -> InkPoint {
        let at = convert(event.locationInWindow, from: nil)
        return InkPoint(x: at.x - origin, y: at.y - origin)
    }

    private func pointerPressure(_ event: NSEvent) -> Double {
        if event.subtype == .tabletPoint { return Double(event.pressure) }
        return pressure
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let page, let editor else { return }
        let at = location(event)
        editor.visibleCenter = at
        guard tool.ink != nil else {
            editor.pointerDown(at, pageKey: page.key, scale: scale)
            needsDisplay = true
            return
        }
        editor.clearSelection()
        drawingPen = true
        pressure = 0.5
        started = event.timestamp
        snapped = false
        lastMove = Date()
        var f = PenFilter(editor.penSettings(tool.ink ?? .pen))
        let raw = InkPoint(x: at.x, y: at.y, pressure: pointerPressure(event), t: 0)
        points = [f.add(raw)]
        filter = f
        lastRaw = raw
        armSnap()
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let at = location(event)
        guard drawingPen else {
            editor?.pointerMoved(at)
            needsDisplay = true
            return
        }
        guard !points.isEmpty, !snapped else { return }
        let minGap = 0.6 / scale
        if let last = lastRaw, hypot(last.x - at.x, last.y - at.y) < minGap { return }
        if let last = lastRaw, hypot(last.x - at.x, last.y - at.y) * scale > 3 { lastMove = Date(); armSnap() }
        let raw = InkPoint(x: at.x, y: at.y, pressure: pointerPressure(event), t: (event.timestamp - started) * 1000)
        lastRaw = raw
        if var f = filter { points.append(f.add(raw)); filter = f } else { points.append(raw) }
        invalidateTail()
    }

    /// Holding the mouse still at the end of a line turns it into a clean shape there and then.
    private func armSnap() {
        snapTimer?.invalidate()
        snapTimer = Timer.scheduledTimer(withTimeInterval: InkEditorModel.holdToSnap, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.drawingPen, !self.snapped, self.points.count >= 3,
                      Date().timeIntervalSince(self.lastMove) >= InkEditorModel.holdToSnap * 0.9,
                      let shape = InkShapes.recognize(self.points) else { return }
                self.points = shape.points
                self.snapped = true
                self.needsDisplay = true
            }
        }
    }

    override func mouseUp(with event: NSEvent) {
        snapTimer?.invalidate()
        guard drawingPen else {
            editor?.pointerUp()
            needsDisplay = true
            return
        }
        drawingPen = false
        guard let ink = tool.ink, !points.isEmpty, let page else { return }
        if !snapped, let f = filter, let raw = lastRaw, let end = f.end(raw) { points.append(end) }
        filter = nil
        lastRaw = nil
        let finished = points
        points = []
        editor?.addStroke(points: finished, tool: ink, color: color, width: width, pageKey: page.key, held: snapped)
        snapped = false
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        if tool == .eraser { editor?.hover(location(event), scale: scale); needsDisplay = true }
    }

    /// Force Touch trackpads report how hard you press while drawing.
    override func pressureChange(with event: NSEvent) {
        if event.stage >= 1 { pressure = min(1, max(0.05, Double(event.pressure))) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited], owner: self))
    }

    override func mouseExited(with event: NSEvent) { editor?.hover(nil, scale: scale); needsDisplay = true }

    override func resetCursorRects() {
        let cursor: NSCursor = switch tool {
        case .eraser, .lasso: .arrow
        case .text: .iBeam
        default: .crosshair
        }
        addCursorRect(visibleRect, cursor: cursor)
    }

    // Delete removes what the lasso picked up.
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117, editor?.selection != nil { editor?.deleteSelection(); return }
        if event.keyCode == 53, editor?.selection != nil { editor?.clearSelection(); needsDisplay = true; return }
        super.keyDown(with: event)
    }
}
#endif
