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

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.1
        scroll.maxMagnification = 6
        scroll.backgroundColor = NSColor.underPageBackgroundColor
        scroll.documentView = InkNSView()
        return scroll
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
                        let fit = max(0.25, (Double(scroll.contentSize.width) - 40) / page.width)
                        scroll.magnification = min(fit, 3)
                        view.scroll(.zero)
                    }
                }
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
        InkRenderer.drawContent(editor.display(page.key), in: ctx)
        if let ink = tool.ink, !points.isEmpty {
            InkRenderer.draw(tool: ink, color: color, width: width, points: points, shape: snapped, in: ctx)
        }
        InkRenderer.drawOverlay(editor.overlay(page.key), scale: scale, in: ctx)
        ctx.restoreGState()
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
        points = [InkPoint(x: at.x, y: at.y, pressure: pointerPressure(event), t: 0)]
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
        if let last = points.last, hypot(last.x - at.x, last.y - at.y) < minGap { return }
        if let last = points.last, hypot(last.x - at.x, last.y - at.y) * scale > 3 { lastMove = Date(); armSnap() }
        points.append(InkPoint(x: at.x, y: at.y, pressure: pointerPressure(event), t: (event.timestamp - started) * 1000))
        needsDisplay = true
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
