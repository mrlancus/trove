#if os(macOS)
import AppKit
import SwiftUI
import TroveCore

/// The drawing surface on the Mac: the mouse or trackpad draws (with pressure on Force Touch
/// trackpads and drawing tablets), pinch or ⌘-scroll zooms, and the page's paper, PDF page or
/// image sits underneath.
struct MouseInkCanvas: NSViewRepresentable {
    let editor: InkEditorModel
    let page: InkPageSpec
    let pageIndex: Int
    let strokes: [InkStroke]
    let tool: InkEditorTool
    let color: String
    let width: Double

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.25
        scroll.maxMagnification = 6
        scroll.backgroundColor = NSColor.underPageBackgroundColor
        scroll.documentView = InkNSView()
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? InkNSView else { return }
        view.editor = editor
        view.strokes = strokes
        view.tool = tool
        view.color = color
        view.width = width
        let key = "\(pageIndex)-\(editor.paper.rawValue)"
        if view.pageKey != key {
            let newPage = view.pageIndex != pageIndex
            view.show(page, index: pageIndex, key: key)
            guard newPage else { return }
            DispatchQueue.main.async {
                let fit = max(0.25, (Double(scroll.contentSize.width) - 40) / page.width)
                scroll.magnification = min(fit, 3)
                view.scroll(.zero)
            }
        }
        view.needsDisplay = true
    }
}

final class InkNSView: NSView {
    var editor: InkEditorModel?
    var strokes: [InkStroke] = []
    var tool: InkEditorTool = .pen
    var color = "#1c1c1e"
    var width = 2.5
    private(set) var pageIndex = -1
    private(set) var pageKey = ""
    private var page: InkPageSpec?
    /// Strokes just drawn, shown until the editor's copy of them arrives.
    private var pending: [(id: String, tool: InkTool, color: String, width: Double, points: [InkPoint])] = []
    private var background: CGImage?
    private var points: [InkPoint] = []
    private var started: TimeInterval = 0
    private var pressure = 0.5
    private var eraserAt: CGPoint?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        pressureConfiguration = NSPressureConfiguration(pressureBehavior: .primaryGeneric)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ spec: InkPageSpec, index: Int, key: String) {
        if index != pageIndex { points = []; pending = [] }
        pageIndex = index
        pageKey = key
        page = spec
        background = nil
        setFrameSize(NSSize(width: spec.width, height: spec.height))
        let pixels = Int(min(4096, spec.width * 2.5))
        Task { @MainActor [weak self] in
            let rendered = await Task.detached(priority: .userInitiated) { InkRenderer.render(spec, strokes: [], pixelWidth: pixels).map(InkImage.init) }.value
            guard let self, self.pageIndex == index else { return }
            self.background = rendered?.image
            self.needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, let page else { return }
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(bounds)
        if let background {
            ctx.saveGState()
            ctx.translateBy(x: 0, y: page.height)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(background, in: CGRect(x: 0, y: 0, width: page.width, height: page.height))
            ctx.restoreGState()
        }
        InkRenderer.draw(strokes, in: ctx)
        let have = Set(strokes.map(\.id))
        pending.removeAll { have.contains($0.id) }
        for p in pending { InkRenderer.draw(tool: p.tool, color: p.color, width: p.width, points: p.points, in: ctx) }
        if let ink = tool.ink, !points.isEmpty { InkRenderer.draw(tool: ink, color: color, width: width, points: points, in: ctx) }
        if tool == .eraser, let at = eraserAt {
            ctx.setStrokeColor(NSColor.secondaryLabelColor.cgColor)
            ctx.setLineWidth(1)
            let r = eraserRadius
            ctx.strokeEllipse(in: CGRect(x: at.x - r, y: at.y - r, width: r * 2, height: r * 2))
        }
    }

    private var eraserRadius: Double { 9 / max(0.1, enclosingScrollView?.magnification ?? 1) }

    private func location(_ event: NSEvent) -> CGPoint { convert(event.locationInWindow, from: nil) }

    private func pointerPressure(_ event: NSEvent) -> Double {
        if event.subtype == .tabletPoint { return Double(event.pressure) }
        return pressure
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let at = location(event)
        if tool == .eraser {
            eraserAt = at
            editor?.eraseAt(x: at.x, y: at.y, radius: eraserRadius)
            needsDisplay = true
            return
        }
        pressure = 0.5
        started = event.timestamp
        points = [InkPoint(x: at.x, y: at.y, pressure: pointerPressure(event), t: 0)]
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let at = location(event)
        if tool == .eraser {
            eraserAt = at
            editor?.eraseAt(x: at.x, y: at.y, radius: eraserRadius)
            needsDisplay = true
            return
        }
        guard !points.isEmpty else { return }
        let minGap = 0.6 / max(0.1, enclosingScrollView?.magnification ?? 1)
        if let last = points.last, hypot(last.x - at.x, last.y - at.y) < minGap { return }
        points.append(InkPoint(x: at.x, y: at.y, pressure: pointerPressure(event), t: (event.timestamp - started) * 1000))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if tool == .eraser { eraserAt = nil; needsDisplay = true; return }
        guard let ink = tool.ink, !points.isEmpty else { return }
        let finished = points
        let id = UUID().uuidString.lowercased()
        points = []
        pending.append((id, ink, color, width, finished))
        editor?.add(points: finished, tool: ink, color: color, width: width, id: id, on: pageIndex)
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        if tool == .eraser { eraserAt = location(event); needsDisplay = true }
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

    override func mouseExited(with event: NSEvent) { eraserAt = nil; needsDisplay = true }

    override func resetCursorRects() { addCursorRect(bounds, cursor: tool == .eraser ? .arrow : .crosshair) }
}
#endif
