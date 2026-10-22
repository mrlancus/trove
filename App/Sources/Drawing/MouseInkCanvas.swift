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
    /// The text box being typed in (a text field on the page).
    var textEdit: InkTextEdit?
    /// The dark page (`InkDark`): black page, black and white ink swapped.
    var dark = false

    /// The grey around the page: fixed (not the system's appearance), darker with the dark page.
    static func outside(dark: Bool) -> NSColor {
        dark ? NSColor(srgbRed: 44 / 255.0, green: 44 / 255.0, blue: 46 / 255.0, alpha: 1)
            : NSColor(srgbRed: 217 / 255.0, green: 217 / 255.0, blue: 222 / 255.0, alpha: 1)
    }

    @MainActor
    final class Coordinator {
        var handledZoom: UUID?
        var observer: NSObjectProtocol?
        var editor: InkEditorModel?
        /// The page to fit once the window has its real size.
        var page: InkPageSpec?
        var fitPending = false
        var fittedSize: NSSize = .zero
        var zoomedByHand = false

        /// Fits the zoom when a page opens, once the scroll view has a usable size (it can be
        /// zero for a moment while the window opens: fitting then gave 10 %), and again when the
        /// window's width changes, unless zoomed by hand.
        func fitIfNeeded(_ scroll: NSScrollView) {
            guard let page, let editor else { return }
            let size = scroll.contentSize
            guard size.width >= 120, size.height >= 120 else { return }
            let resized = fittedSize != .zero && size.width != fittedSize.width
            let first = fitPending
            guard first || (resized && !zoomedByHand && !page.infinite) else { return }
            fitPending = false
            fittedSize = size
            let whole = editor.fitWholePage
            DispatchQueue.main.async { [weak scroll] in
                guard let scroll, let view = scroll.documentView as? InkNSView else { return }
                if page.infinite {
                    scroll.magnification = 1
                    view.scroll(CGPoint(x: page.origin - 40, y: page.origin - 40))
                } else {
                    scroll.magnification = MouseInkCanvas.fit(page, whole: whole, in: scroll)
                    if first { view.scroll(.zero) }
                }
                editor.zoom = Double(scroll.magnification)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = InkScrollView()
        let coordinator = context.coordinator
        scroll.onTile = { [weak scroll, weak coordinator] in
            guard let scroll, let coordinator else { return }
            coordinator.fitIfNeeded(scroll)
        }
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.allowsMagnification = true
        scroll.minMagnification = InkEditorModel.minZoom
        scroll.maxMagnification = InkEditorModel.maxZoom
        scroll.backgroundColor = Self.outside(dark: dark)
        scroll.documentView = InkNSView()
        // The zoom shown bottom left follows pinching and ⌘-scrolling.
        let editor = editor
        context.coordinator.observer = NotificationCenter.default.addObserver(forName: NSScrollView.didEndLiveMagnifyNotification, object: scroll, queue: .main) { [weak scroll, weak coordinator] _ in
            let z = Double(scroll?.magnification ?? 1)
            MainActor.assumeIsolated {
                coordinator?.zoomedByHand = true
                editor.zoom = z
            }
        }
        return scroll
    }

    /// The zoom that fits the page (all of it, or its width) in the window.
    static func fit(_ page: InkPageSpec, whole: Bool, in scroll: NSScrollView) -> Double {
        let w = max(80, Double(scroll.contentSize.width) - 40), h = max(80, Double(scroll.contentSize.height) - 40)
        let z = whole ? min(w / page.width, h / page.height) : w / page.width
        return min(InkEditorModel.maxZoom, max(InkEditorModel.minZoom, z))
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? InkNSView else { return }
        let c = context.coordinator
        c.editor = editor
        let outside = Self.outside(dark: dark)
        if scroll.backgroundColor != outside { scroll.backgroundColor = outside }
        if view.dark != dark { view.dark = dark }
        view.editor = editor
        view.tool = tool
        view.color = color
        view.width = width
        let key = "\(page.key)-\(pagesRevision)-\(page.width)x\(page.height)-\(dark)"
        if view.shownKey != key {
            let newPage = view.page?.key != page.key || view.page?.infinite != page.infinite
            view.show(page, key: key)
            c.page = page
            if newPage {
                c.fitPending = true
                c.fitIfNeeded(scroll)
            }
        }
        if let zoomRequest, zoomRequest.id != context.coordinator.handledZoom {
            context.coordinator.handledZoom = zoomRequest.id
            let z: Double = switch zoomRequest.kind {
            case .scale(let v): min(InkEditorModel.maxZoom, max(InkEditorModel.minZoom, v))
            case .wholePage: Self.fit(page, whole: true, in: scroll)
            case .pageWidth: Self.fit(page, whole: false, in: scroll)
            }
            if case .scale = zoomRequest.kind { c.zoomedByHand = true } else { c.zoomedByHand = false }
            let editor = editor
            DispatchQueue.main.async {
                scroll.animator().magnification = z
                editor.zoom = z
            }
        }
        view.syncText(textEdit)
        view.needsDisplay = true
    }
}

/// The scroll view, telling the canvas when it lays out (to fit the page once it has its size).
final class InkScrollView: NSScrollView {
    var onTile: (@MainActor () -> Void)?
    override func tile() {
        super.tile()
        onTile?()
    }
}

final class InkNSView: NSView {
    var editor: InkEditorModel?
    /// The dark page (`InkDark`): what's drawn is shown in its colours; what's stored isn't touched.
    var dark = false { didSet { if dark != oldValue { inkCache = nil; needsDisplay = true } } }
    /// Whether this page shows dark (sketch paper only).
    private var darkHere: Bool { dark && page.map(InkDark.applies(to:)) == true }
    var tool: InkEditorTool = .pen { didSet { if tool != oldValue { window?.invalidateCursorRects(for: self) } } }
    var color = "#1c1c1e"
    var width = 2.5
    private(set) var page: InkPageSpec?
    private(set) var shownKey = ""
    /// The page under the ink: a whole-page picture, and what's on screen drawn sharp once zooming settles.
    private let backdrop = InkBackdrop()
    /// The page as the backdrop draws it (dark paper on the dark page).
    private var backdropSpec: InkPageSpec?
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
    /// The ruler edge or protractor arc the line being drawn runs along.
    private var guide: InkGuideSnap?
    /// The text box being typed in, as a text field on the page.
    private var textView: NSTextView?
    private var textViewFor: String?
    private let textDelegate = InkMacTextDelegate()

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
        backdrop.reset()
        backdropSpec = nil
        setFrameSize(NSSize(width: spec.width, height: spec.height))
        guard !spec.infinite else { needsDisplay = true; return }
        let drawn = darkHere ? InkDark.spec(spec) : spec
        backdropSpec = drawn
        backdrop.changed = { [weak self] in
            guard let self, self.shownKey == key else { return }
            self.needsDisplay = true
        }
        backdrop.prepare(drawn)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, let page, let editor else { return }
        ctx.saveGState()
        ctx.translateBy(x: origin, y: origin)
        if page.infinite {
            let area = InkGeometry.Rect(x: dirtyRect.minX - origin, y: dirtyRect.minY - origin, width: dirtyRect.width, height: dirtyRect.height)
            InkRenderer.drawBackground(darkHere ? InkDark.spec(page) : page, area: area, in: ctx)
        } else if let spec = backdropSpec, backdrop.hasWhole(spec.key) {
            backdrop.draw(spec.key, size: CGSize(width: page.width, height: page.height), in: ctx)
            // What's on screen, sharp at this zoom, a moment after it settles.
            let density = CGFloat(scale) * (window?.backingScaleFactor ?? 2)
            backdrop.refine([(spec, visibleRect.offsetBy(dx: -origin, dy: -origin))], density: density)
        } else {
            ctx.setFillColor(darkHere ? NSColor.black.cgColor : NSColor.white.cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: page.width, height: page.height))
        }
        drawInk(page, editor: editor, in: ctx)
        // What the lasso is dragging, over the rest: the cached picture of the page stays as it is while it moves.
        if let moving = editor.dragPreview(page.key) { InkRenderer.drawContent(darkHere ? InkDark.content(moving) : moving, in: ctx) }
        if let ink = tool.ink, !points.isEmpty {
            let style = InkStrokeStyle(dash: editor.dash(for: tool))
            InkRenderer.draw(tool: ink, color: darkHere ? InkDark.swap(color) : color, width: width, points: points, shape: snapped, style: style, in: ctx)
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
        let key = "\(editor.revision)|\(shownKey)|\(scale)|\(darkHere)"
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
                InkRenderer.drawContent(shownContent(page, editor: editor), in: bitmap)
                if let image = bitmap.makeImage() { inkCache = (key, visible, image) }
            }
        }
        guard let cache = inkCache else { InkRenderer.drawContent(shownContent(page, editor: editor), in: ctx); return }
        InkRenderer.drawImage(cache.image, in: cache.rect.offsetBy(dx: -origin, dy: -origin), ctx: ctx)
    }

    /// The page's ink as shown: swapped black and white on the dark page.
    private func shownContent(_ page: InkPageSpec, editor: InkEditorModel) -> InkContent {
        let stored = editor.display(page.key, lifted: true)
        return darkHere ? InkDark.content(stored) : stored
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
        // On the ruler or protractor (not at an edge): move or turn it instead of drawing.
        if editor.beginGuideDrag(at, pageKey: page.key, scale: scale, pen: true) { needsDisplay = true; return }
        guide = editor.guideSnap(at, pageKey: page.key, scale: scale)
        editor.clearSelection()
        drawingPen = true
        pressure = 0.5
        started = event.timestamp
        snapped = false
        lastMove = Date()
        var f = PenFilter(editor.penSettings(tool.ink ?? .pen))
        let raw = InkPoint(x: at.x, y: at.y, pressure: pointerPressure(event), t: 0)
        points = [editor.along(guide, f.add(raw))]
        filter = f
        lastRaw = raw
        if guide == nil { armSnap() }
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
        if let last = lastRaw, hypot(last.x - at.x, last.y - at.y) * scale > 3 { lastMove = Date(); if guide == nil { armSnap() } }
        let raw = InkPoint(x: at.x, y: at.y, pressure: pointerPressure(event), t: (event.timestamp - started) * 1000)
        lastRaw = raw
        var next = raw
        if var f = filter { next = f.add(raw); filter = f }
        points.append(editor?.along(guide, next) ?? next)
        if let page { editor?.noteReading(at, pageKey: page.key) }
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
        if !snapped, let f = filter, let raw = lastRaw, let end = f.end(raw) { points.append(editor?.along(guide, end) ?? end) }
        filter = nil
        lastRaw = nil
        guide = nil
        let finished = points
        points = []
        editor?.addStroke(points: finished, tool: ink, color: color, width: width, pageKey: page.key, held: snapped)
        snapped = false
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        if tool == .eraser { editor?.hover(location(event), scale: scale); needsDisplay = true }
        if let editor, editor.protractor != nil, let page { editor.noteReading(location(event), pageKey: page.key); needsDisplay = true }
    }

    // MARK: Typing on the page

    /// Shows the text box being typed in as a text field at its place on the page (or takes it away).
    func syncText(_ edit: InkTextEdit?) {
        guard let edit, let page, edit.pageKey == page.key else {
            textView?.removeFromSuperview()
            textView = nil
            textViewFor = nil
            return
        }
        if textView == nil || textViewFor != edit.id {
            textView?.removeFromSuperview()
            let tv = NSTextView(frame: .zero)
            tv.isRichText = false
            tv.allowsUndo = true
            tv.drawsBackground = true
            tv.backgroundColor = (darkHere ? NSColor.black : NSColor.white).withAlphaComponent(0.35)
            tv.textContainerInset = .zero
            tv.textContainer?.lineFragmentPadding = 0
            tv.textContainer?.widthTracksTextView = true
            tv.isVerticallyResizable = false
            tv.string = edit.text
            tv.delegate = textDelegate
            textDelegate.changed = { [weak self] text in self?.editor?.textEdit?.text = text }
            textDelegate.escape = { [weak self] in self?.editor?.commitTextEdit() }
            addSubview(tv)
            textView = tv
            textViewFor = edit.id
            DispatchQueue.main.async { [weak self, weak tv] in if let tv { self?.window?.makeFirstResponder(tv) } }
        }
        guard let tv = textView else { return }
        if tv.string != edit.text { tv.string = edit.text }
        let size = CGFloat(edit.size)
        let ct = InkRenderer.font(size: edit.size, style: edit.style)
        let font = NSFont(name: CTFontCopyPostScriptName(ct) as String, size: size) ?? NSFont.systemFont(ofSize: size)
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = size * 1.25
        paragraph.maximumLineHeight = size * 1.25
        let colour = NSColor(cgColor: InkRenderer.cgColor(darkHere ? InkDark.swap(edit.color) : edit.color)) ?? .black
        if tv.font != font || tv.textColor != colour {
            tv.font = font
            tv.textColor = colour
            tv.defaultParagraphStyle = paragraph
            tv.typingAttributes = [.font: font, .foregroundColor: colour, .paragraphStyle: paragraph]
            if let storage = tv.textStorage {
                storage.setAttributes(tv.typingAttributes, range: NSRange(location: 0, length: storage.length))
            }
        }
        let h = max(Double(size) * 1.25, InkRenderer.textHeight(edit.text, width: edit.frame.width, size: edit.size, style: edit.style))
        // The page's points are this view's (it's scaled by the scroll view's magnification).
        let frame = NSRect(x: edit.frame.x + origin, y: edit.frame.y + origin, width: edit.frame.width, height: h + Double(size) * 0.25)
        if tv.frame != frame { tv.frame = frame }
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

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { textView?.removeFromSuperview(); textView = nil; textViewFor = nil }
    }

    // Delete removes what the lasso picked up.
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117, editor?.selection != nil { editor?.deleteSelection(); return }
        if event.keyCode == 53, editor?.selection != nil { editor?.clearSelection(); needsDisplay = true; return }
        super.keyDown(with: event)
    }
}
/// The Mac text field's typing, handed to the editor: a Return in a bulleted line continues the list,
/// and Escape closes the box.
@MainActor
final class InkMacTextDelegate: NSObject, NSTextViewDelegate {
    var changed: ((String) -> Void)?
    var escape: (() -> Void)?

    func textDidChange(_ notification: Notification) {
        guard let tv = notification.object as? NSTextView else { return }
        changed?(tv.string)
    }

    func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString text: String?) -> Bool {
        guard text == "\n", range.length == 0, let next = InkBullets.afterReturn(textView.string, at: range.location) else { return true }
        textView.string = next.text
        textView.setSelectedRange(NSRange(location: next.cursor, length: 0))
        changed?(next.text)
        return false
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        escape?()
        return true
    }
}
#endif
