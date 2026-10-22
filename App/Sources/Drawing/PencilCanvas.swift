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
    /// The sketch's dark page (`InkDark`): black pages, black and white ink swapped, a dark grey
    /// around the pages. Light grey around white pages otherwise, whatever the system's appearance.
    var dark = false
    /// The text box being typed in (a text field on the page).
    var textEdit: InkTextEdit?

    func makeCoordinator() -> Coordinator { Coordinator(editor: editor) }

    /// The canvas around the pages: a shade apart from the paper, light grey or (dark page) dark grey.
    /// Fixed colours, since the canvas itself stays in light mode to keep ink colours true.
    static func outside(dark: Bool) -> UIColor {
        if dark { return UIColor(red: 44 / 255.0, green: 44 / 255.0, blue: 46 / 255.0, alpha: 1) } // #2c2c2e
        return UIColor(red: 217 / 255.0, green: 217 / 255.0, blue: 222 / 255.0, alpha: 1) // #d9d9de
    }

    func makeUIView(context: Context) -> TroveCanvasView {
        let canvas = TroveCanvasView()
        let c = context.coordinator
        canvas.delegate = c
        // PencilKit's canvas stays clear: when it was opaque it painted its tiles in its background
        // colour over the paper underneath, so a sketch showed only grey (bits of the page flashed
        // while zoomed far out, before the tiles came). The grey round the pages is the paper view's.
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        c.paperView.backgroundColor = Self.outside(dark: dark)
        // Always light: in dark mode PencilKit would turn dark ink light by itself. The dark page swaps
        // black and white ink itself (`InkDark`), leaving every other colour as it is.
        canvas.overrideUserInterfaceStyle = .light
        canvas.drawingPolicy = UIDevice.current.userInterfaceIdiom == .pad ? .default : .anyInput
        canvas.showsVerticalScrollIndicator = true
        canvas.showsHorizontalScrollIndicator = true
        canvas.contentInsetAdjustmentBehavior = .never
        canvas.minimumZoomScale = InkEditorModel.minZoom
        canvas.maximumZoomScale = InkEditorModel.maxZoom
        canvas.bouncesZoom = true
        canvas.insertSubview(c.paperView, at: 0)
        canvas.addSubview(c.boxesView)
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
        // The ruler is Trove's own (PencilKit's only follows a line started at its edge): the Pencil put
        // down anywhere on it, or inside the protractor, draws along the nearer edge or the arc as it
        // goes. PencilKit's drawing waits for this to say no, which it does as the Pencil touches down.
        editor.nativeRuler = false
        let ruled = InkToolGesture()
        ruled.claims = { [weak c, weak canvas] touch, point in
            guard let c, let canvas, touch.type == .pencil else { return false }
            return c.ruledHit(point, in: canvas)
        }
        ruled.onTouch = { [weak c, weak canvas] phase, point in if let c, let canvas { c.ruledTouch(phase, at: point, in: canvas) } }
        canvas.addGestureRecognizer(ruled)
        canvas.drawingGestureRecognizer.require(toFail: ruled)

        // A finger on the selection (its box, corners, knob or handles) or on a guide moves that, not
        // the page; anywhere else (over ink too) it scrolls as before. Where a finger works Trove's
        // tools (iPhone), the tool gesture has it already.
        let grab = InkToolGesture()
        grab.claims = { [weak c, weak canvas] touch, point in
            guard let c, let canvas, touch.type == .direct, !c.fingersDraw(canvas) else { return false }
            return c.grabHit(point, in: canvas)
        }
        grab.onTouch = { [weak c, weak canvas] phase, point in if let c, let canvas { c.toolTouch(phase, at: point, in: canvas) } }
        canvas.addGestureRecognizer(grab)
        canvas.panGestureRecognizer.require(toFail: grab)

        // A finger tap on tape opens or covers it (the Pencil draws, lassos or lays tape there instead).
        let tapeTap = UITapGestureRecognizer(target: c, action: #selector(Coordinator.tapeTapped(_:)))
        tapeTap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        tapeTap.delegate = c.tapeFilter
        c.tapeFilter.shouldReceive = { [weak c, weak canvas] touch in
            guard let c, let canvas else { return false }
            return c.tapeAt(touch.location(in: canvas), in: canvas) != nil
        }
        c.tapeFilter.shouldBegin = { _ in true }
        canvas.addGestureRecognizer(tapeTap)

        let tools = InkToolGesture()
        // Touches in the text box being typed in are the text field's.
        tools.delegate = c.textTouches
        tools.onTouch = { [weak c, weak canvas] phase, point in if let c, let canvas { c.toolTouch(phase, at: point, in: canvas) } }
        tools.isEnabled = false
        canvas.addGestureRecognizer(tools)
        c.toolGesture = tools

        // A finger on the protractor moves it, or turns it by its knobs (while a pen is in hand; Trove's
        // tools do that themselves).
        let guidePan = UIPanGestureRecognizer(target: c, action: #selector(Coordinator.guidePanned(_:)))
        guidePan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        guidePan.maximumNumberOfTouches = 1
        guidePan.delegate = c.guideFilter
        c.guideFilter.shouldBegin = { [weak c, weak canvas] g in
            guard let c, let canvas else { return false }
            return c.guideHit(g.location(in: canvas), in: canvas)
        }
        canvas.addGestureRecognizer(guidePan)

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
        let outside = Self.outside(dark: dark)
        if c.paperView.backgroundColor != outside { c.paperView.backgroundColor = outside }
        if canvas.overrideUserInterfaceStyle != .light { canvas.overrideUserInterfaceStyle = .light }
        if c.dark != dark { c.setDark(dark) }
        c.show(pages, current: current, layout: layout, revision: pagesRevision, in: canvas)
        c.apply(version: revision, to: canvas)
        if overlayRevision != c.shownOverlay { c.shownOverlay = overlayRevision; c.overlayView.setNeedsDisplay() }
        c.refreshBoxes()
        let pen = tool.ink != nil
        // Setting PencilKit's tool resets its state: only when it really changes.
        let shownColor = c.darkInk ? InkDark.swap(color) : color
        let toolKey = "\(tool.rawValue)|\(shownColor)|\(width)"
        if let ink = tool.ink, toolKey != c.shownTool { c.shownTool = toolKey; canvas.tool = Self.pkTool(ink, color: shownColor, width: width) }
        // Only what changes is set: this runs on every stroke and lasso move, and setting a gesture's
        // touch types or turning it on again while a touch is in flight can drop that touch (a Pencil
        // tap or drag that "didn't register").
        if canvas.drawingGestureRecognizer.isEnabled != pen { canvas.drawingGestureRecognizer.isEnabled = pen }
        if let tools = c.toolGesture, tools.isEnabled == pen { tools.isEnabled = !pen }
        // Where a finger draws (iPhone), it also works the lasso and eraser; two fingers scroll.
        let fingers = canvas.drawingPolicy == .anyInput || !UIPencilInteraction.prefersPencilOnlyDrawing
        let types = fingers
            ? [NSNumber(value: UITouch.TouchType.pencil.rawValue), NSNumber(value: UITouch.TouchType.direct.rawValue)]
            : [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        if let tools = c.toolGesture, tools.allowedTouchTypes != types { tools.allowedTouchTypes = types }
        let scrollTouches = !pen && fingers ? 2 : 1
        if canvas.panGestureRecognizer.minimumNumberOfTouches != scrollTouches { canvas.panGestureRecognizer.minimumNumberOfTouches = scrollTouches }
        for s in c.swipes where s.numberOfTouchesRequired != (fingers ? 2 : 1) { s.numberOfTouchesRequired = fingers ? 2 : 1 }
        if let zoomRequest, zoomRequest.id != c.handledZoom {
            c.handledZoom = zoomRequest.id
            c.zoom(zoomRequest.kind, in: canvas)
        }
        if canvas.isRulerActive { canvas.isRulerActive = false }
        canvas.bringSubviewToFront(c.boxesView)
        canvas.bringSubviewToFront(c.overlayView)
        c.showText(textEdit, in: canvas)
    }

    static func pkTool(_ tool: InkTool, color: String, width: Double) -> PKTool {
        PKInkingTool(inkType(tool), color: uiColor(color), width: width)
    }

    /// PencilKit's ink for each pen. The ballpoint and the marker are both even (monoline): a new
    /// stroke's tool is the one in hand when it's drawn (`inkTool(for:current:)`), so each comes back as itself.
    nonisolated static func inkType(_ tool: InkTool) -> PKInk.InkType {
        switch tool {
        case .pen: .pen
        case .ballpoint: .monoline
        case .pencil: .pencil
        case .marker: .monoline
        case .highlighter: .marker
        case .fountain: .fountainPen
        case .brush: .watercolor
        }
    }

    /// The pen a PencilKit stroke was drawn with: the one in hand if its ink matches, else by its ink.
    nonisolated static func inkTool(for type: PKInk.InkType, current: InkTool?) -> InkTool {
        if let current, inkType(current) == type { return current }
        switch type {
        case .pencil: return .pencil
        case .marker: return .highlighter
        case .monoline: return .marker
        case .fountainPen: return .fountain
        case .watercolor: return .brush
        default: return .pen
        }
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
        let type = Self.inkType(s.tool)
        let points = s.points.compactMap { p -> PKStrokePoint? in
            guard p.x.isFinite, p.y.isFinite else { return nil }
            let w = min(4000, max(0.1, s.shape != nil ? s.width : InkStroke.width(s.width, tool: s.tool, pressure: p.pressure)))
            return PKStrokePoint(location: CGPoint(x: p.x + offset.x, y: p.y + offset.y), timeOffset: max(0, p.t / 1000), size: CGSize(width: w, height: w),
                                 opacity: 1, force: max(0, p.pressure * 2), azimuth: 0, altitude: .pi / 2)
        }
        guard !points.isEmpty else { return nil }
        return PKStroke(ink: PKInk(type, color: uiColor(s.color)), path: PKStrokePath(controlPoints: points, creationDate: Date()))
    }

    static func convert(_ s: PKStroke, offset: CGPoint, current: InkTool? = nil, dark: Bool = false) -> (tool: InkTool, color: String, width: Double, points: [InkPoint]) {
        let tool = Self.inkTool(for: s.ink.inkType, current: current)
        let raw = Array(s.path)
        let sizes = raw.map { Double(max($0.size.width, $0.size.height)) }
        let width = tool.usesPressure ? max(sizes.max() ?? 2, 0.5) : max(sizes.reduce(0, +) / Double(max(1, sizes.count)), 0.5)
        let points = zip(raw, sizes).map { p, size in
            let at = p.location.applying(s.transform)
            let pressure = tool.usesPressure ? min(1, max(0, (size / width - 0.35) / 0.65)) : 0.5
            return InkPoint(x: at.x - offset.x, y: at.y - offset.y, pressure: pressure, t: p.timeOffset * 1000)
        }
        // On a dark page the pen's colour is shown swapped: stored as the colour that was picked.
        let color = dark ? InkDark.swap(hex(s.ink.color)) : hex(s.ink.color)
        return (tool, color, width, points)
    }

    /// PencilKit strokes have no ids, so they're matched by their points.
    static func signature(_ s: PKStroke) -> String {
        // Without copying the path: this runs for every stroke on each update.
        let path = s.path, n = path.count
        let first = n > 0 ? path[0].location : .zero, last = n > 0 ? path[n - 1].location : .zero
        // Int(_:) stops the app on NaN, ±∞ or a huge number: those count as 0.
        func q(_ v: CGFloat) -> Int { v.isFinite ? Int(max(-1e12, min(1e12, v * 10))) : 0 }
        return "\(n)-\(q(first.x)),\(q(first.y))-\(q(last.x)),\(q(last.y))"
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
        /// Keeps touches in the text field away from Trove's tool gesture.
        let textTouches = InkGestureFilter()
        /// Lets the protractor's pan start only on the protractor.
        let guideFilter = InkGestureFilter()
        /// Lets the finger's tap on tape see only touches on tape.
        let tapeFilter = InkGestureFilter()
        /// The text box being typed in, as a text field over the page.
        private var textView: UITextView?
        private var textViewFor: String?
        private let textDelegate = InkTextViewDelegate()
        /// The font, size and colour the text field was last set to (set again only when they change: it disturbs typing).
        private var textLook = ""
        /// The page a protractor drag started on.
        private var guideSlot: Slot?
        /// Paper, PDF pages and pictures for what's on screen.
        let paperView = InkAreaView()
        /// Text boxes, the lasso, the selection, the eraser and the laser, over the ink.
        let overlayView = InkAreaView()
        /// Text boxes and tape, over the ink and under the overlay: drawn past the screen's edges like the
        /// paper and redrawn only when they change, not on every lasso or eraser move.
        let boxesView = InkAreaView()
        private var shownBoxes = ""
        private var boxesZoom: CGFloat = 0
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
        private var zoomedByHand = false
        /// The page index this canvas last showed as current (so a jump from the page list scrolls there).
        private var shownCurrent = -1
        /// Signature → Trove stroke ids for what's on the canvas, in canvas order (two strokes can look
        /// the same, say pasted twice in one place: each keeps its own id).
        private var ids: [String: [String]] = [:]
        /// The Trove id of each stroke on the canvas, in canvas order, while that's known for sure (nil
        /// after anything unexpected). PencilKit only ever appends a new pen stroke, so with this a new
        /// stroke and the update after it no longer sign every stroke (ROADMAP §3.7 item 8).
        private var canvasOrder: [String]?
        /// When PencilKit's pen last lifted: strokes it reports as new are only taken while a pen is in
        /// hand or just after (anything else is the canvas echoing a drawing set from the model).
        private var penLifted = Date.distantPast
        /// The zoom the paper was last drawn at (it's drawn past the screen's edges and kept while scrolling).
        private var paperZoom: CGFloat = 0
        /// The pictures the paper was last drawn with (where each is).
        private var shownPictures = ""
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
        /// File pages (PDF, image, GoodNotes) as pictures, made for pages on or near the screen.
        let backdrop = InkBackdrop()
        static let gap: CGFloat = 24, margin: CGFloat = 24
        /// The dark page is on (`InkDark`).
        private(set) var dark = false
        /// The size the zoom was last fitted to (zero until the view has a usable size).
        private var fittedSize: CGSize = .zero
        /// A view smaller than this is still being laid out (SwiftUI can hand over a provisional size
        /// first): fitting to it gave 10 % and left the page tiny, so the fit waits for the real size.
        /// The editor is never this small on an iPhone or iPad.
        static let usable: CGFloat = 280

        init(editor: InkEditorModel) {
            self.editor = editor
            super.init()
            paperView.painter = { [weak self] ctx, area, scale in self?.drawUnder(ctx, area: area, scale: scale) }
            overlayView.painter = { [weak self] ctx, area, scale in self?.drawOver(ctx, area: area, scale: scale) }
            boxesView.painter = { [weak self] ctx, area, scale in self?.drawBoxes(ctx, area: area) }
            editor.overlayListener = { [weak self] in self?.overlayView.setNeedsDisplay() }
            backdrop.changed = { [weak self] in self?.paperView.setNeedsDisplay() }
            textTouches.shouldReceive = { touch in !(touch.view is UITextView) }
            textDelegate.changed = { [weak self] text in
                guard let self else { return }
                self.editor.textEdit?.text = text
            }
        }

        private var isEndless: Bool { slots.first?.spec.infinite ?? false }

        /// Whether a page shows dark (paper only; PDFs and pictures keep their look).
        func isDark(_ slot: Slot) -> Bool { dark && InkDark.applies(to: slot.spec) }
        /// The pen's colour is shown swapped (the dark page is on and the pages are paper).
        var darkInk: Bool { dark && slots.contains { InkDark.applies(to: $0.spec) } }

        /// The dark page turned on or off: everything is drawn again in its colours.
        func setDark(_ on: Bool) {
            dark = on
            shownVersion = -1
            shownTool = ""
            textLook = ""
            paperZoom = 0
            paperView.setNeedsDisplay()
            overlayView.setNeedsDisplay()
            boxesView.setNeedsDisplay()
            if let tv = textView { tv.backgroundColor = Self.textFieldBackground(dark: on) }
        }

        static func textFieldBackground(dark: Bool) -> UIColor {
            (dark ? UIColor.black : UIColor.white).withAlphaComponent(0.35)
        }

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
                backdrop.keep(only: Set(pages.map(\.key)))
                if previous.isEmpty || isEndless != wasEndless { fittedSize = .zero }
                paperZoom = 0
                resize(canvas)
                if turned {
                    UIView.transition(with: canvas, duration: 0.38, options: [current > shownCurrent ? .transitionCurlUp : .transitionCurlDown, .allowAnimatedContent]) {}
                }
            }
            if needsFit(canvas.bounds.size) { self.layout(canvas) }
            if current != shownCurrent {
                let first = shownCurrent < 0
                shownCurrent = current
                if !flip && !isEndless, let slot = slots.first(where: { $0.index == current }), !first || current > 0 { scroll(to: slot, in: canvas, animated: !first) }
            }
        }

        /// Whether the zoom should be fitted again: the first time the view has a usable size, when
        /// its width changes (rotation, Split View, Stage Manager), or when the last fit was made
        /// while the view was still too short (its height comes later than its width at times).
        private func needsFit(_ size: CGSize) -> Bool {
            guard size.width >= Self.usable, size.height >= Self.usable else { return false }
            if fittedSize == .zero { return true }
            if size.width != fittedSize.width { return true }
            // The height settled after the fit (the toolbar's second row or the presentation finishing):
            // fit again when it changed by more than a quarter, unless zoomed by hand.
            return !zoomedByHand && abs(size.height - fittedSize.height) > fittedSize.height / 4
        }

        /// Fits the page in view once the view has its real size (and again on rotation), unless
        /// zoomed by hand. It opens at the top of the page it starts on.
        func layout(_ canvas: TroveCanvasView) {
            guard !slots.isEmpty else { return }
            let size = canvas.bounds.size
            if needsFit(size) {
                let first = fittedSize == .zero
                fittedSize = size
                if isEndless {
                    if first {
                        canvas.zoomScale = 1
                        let o = slots[0].offset
                        canvas.setContentOffset(CGPoint(x: o.x - 40, y: o.y - 40), animated: false)
                    }
                } else if first || !zoomedByHand {
                    canvas.zoomScale = fit(editor.fitWholePage, in: canvas)
                    // The insets centring the page depend on the zoom: set before scrolling to it.
                    resize(canvas)
                    if let slot = slots.first(where: { $0.index == editor.page }) ?? slots.first { scroll(to: slot, in: canvas, animated: false, centred: true) }
                }
                let z = Double(canvas.zoomScale)
                DispatchQueue.main.async { [weak self, weak canvas] in
                    self?.editor.zoom = z
                    if let canvas { self?.redrawAfterFit(canvas) }
                }
            }
            resize(canvas)
        }

        /// After fitting, everything is drawn for the new zoom: PencilKit's ink sometimes stayed
        /// blank until a pinch (it renders on a zoom change), so the zoom is nudged and set back.
        private func redrawAfterFit(_ canvas: TroveCanvasView) {
            let z = canvas.zoomScale
            updating = true
            canvas.setZoomScale(min(InkEditorModel.maxZoom, z * 1.001), animated: false)
            canvas.setZoomScale(z, animated: false)
            updating = false
            paperZoom = 0
            boxesZoom = 0
            resize(canvas)
            paperView.setNeedsDisplay()
            boxesView.setNeedsDisplay()
            overlayView.setNeedsDisplay()
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

        /// Scrolls the page's top (or, across, its left edge) into view. `centred` also centres the
        /// other way (after fitting the zoom, when the old offset means nothing).
        private func scroll(to slot: Slot, in canvas: UIScrollView, animated: Bool, centred: Bool = false) {
            let z = canvas.zoomScale
            let midX = (canvas.contentSize.width - canvas.bounds.width) / 2
            let midY = (canvas.contentSize.height - canvas.bounds.height) / 2
            let acrossX = centred ? midX : canvas.contentOffset.x
            let acrossY = centred ? midY : canvas.contentOffset.y
            let x = layoutMode == .horizontal ? slot.frame.minX * z - Self.margin : acrossX
            let y = layoutMode == .horizontal ? acrossY : slot.frame.minY * z - Self.margin
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

        /// The paper and overlay cover what's on screen. The paper is drawn a quarter of a screen past
        /// each edge and redrawn only when scrolling leaves that or the zoom changes (it used to redraw
        /// on every scroll frame, a big part of the battery a sketch used).
        private func follow(_ canvas: UIScrollView) {
            let visible = canvas.bounds
            if canvas.zoomScale != paperZoom {
                // Zooming: just the screen, redrawn each frame of the pinch.
                paperZoom = canvas.zoomScale
                paperView.zoom = canvas.zoomScale
                paperView.frame = visible
                paperView.setNeedsDisplay()
            } else if !paperView.frame.contains(visible) {
                paperView.frame = visible.insetBy(dx: -visible.width / 4, dy: -visible.height / 4)
                paperView.setNeedsDisplay()
            }
            overlayView.frame = visible
            overlayView.zoom = canvas.zoomScale
            // The overlay is usually empty (no lasso or eraser): then it needn't redraw.
            let z0 = max(0.01, canvas.zoomScale)
            let area = InkGeometry.Rect(x: visible.minX / z0, y: visible.minY / z0, width: visible.width / z0, height: visible.height / z0)
            if overlayHasContent(area) || overlayView.drewSomething { overlayView.setNeedsDisplay() }
            let hasBoxes = slots.contains { editor.hasBoxesOver($0.spec.key) }
            if canvas.zoomScale != boxesZoom {
                boxesZoom = canvas.zoomScale
                boxesView.zoom = canvas.zoomScale
                boxesView.frame = visible
                if hasBoxes || boxesView.drewSomething { boxesView.setNeedsDisplay() }
            } else if !boxesView.frame.contains(visible) {
                boxesView.frame = visible.insetBy(dx: -visible.width / 4, dy: -visible.height / 4)
                if hasBoxes || boxesView.drewSomething { boxesView.setNeedsDisplay() }
            }
            let z = canvas.zoomScale
            if isEndless, let slot = slots.first {
                editor.visibleCenter = InkPoint(x: visible.midX / z - slot.offset.x, y: visible.midY / z - slot.offset.y)
            }
            let density = z * max(1, canvas.traitCollection.displayScale)
            prepareBitmaps(visible: CGRect(x: visible.minX / z, y: visible.minY / z, width: visible.width / z, height: visible.height / z), density: density)
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
                let darkSlot = isDark(slot)
                if !slot.spec.infinite {
                    // A thin edge under the page: a blurred shadow is redrawn on every scroll frame and costs battery.
                    let edge = 1 / scale
                    let edgeColor = darkSlot ? UIColor.white.withAlphaComponent(0.12) : UIColor.black.withAlphaComponent(0.08)
                    ctx.setFillColor(edgeColor.cgColor)
                    ctx.fill(slot.frame.insetBy(dx: -edge, dy: -edge).offsetBy(dx: 0, dy: edge))
                    ctx.setFillColor((darkSlot ? UIColor.black : UIColor.white).cgColor)
                    ctx.fill(slot.frame)
                    ctx.clip(to: slot.frame)
                }
                ctx.translateBy(x: o.x, y: o.y)
                let local = InkGeometry.Rect(x: area.x - o.x, y: area.y - o.y, width: area.width, height: area.height)
                switch slot.spec.background {
                case .paper:
                    InkRenderer.drawBackground(darkSlot ? InkDark.spec(slot.spec) : slot.spec, area: local, in: ctx)
                case .pdf, .image, .goodnotes:
                    backdrop.draw(slot.spec.key, size: CGSize(width: slot.spec.width, height: slot.spec.height), in: ctx)
                }
                // Pictures the lasso is dragging are drawn over the ink while they move (`drawOver`).
                let c = editor.display(slot.spec.key, lifted: true)
                InkRenderer.drawPictures(c.elements, pictures: c.pictures, in: ctx)
                ctx.restoreGState()
            }
        }

        private func overlayHasContent(_ area: InkGeometry.Rect) -> Bool {
            visibleSlots(area).contains { slot in
                let o = editor.overlay(slot.spec.key)
                return o.eraser != nil || !o.lasers.isEmpty || !o.lasso.isEmpty || o.selection != nil || o.tape != nil || o.tip != nil
                    || !o.handles.isEmpty || o.preview != nil || o.protractor != nil || o.ruler != nil || editor.dragPreview(slot.spec.key) != nil
            }
        }

        /// The text boxes and tape changed (new ink version, a peek, the box being typed in, a drag
        /// starting or ending): redraw their layer.
        func refreshBoxes() {
            let edit = editor.textEdit.map { "\($0.pageKey):\($0.elementId ?? "")" } ?? ""
            let sig = "\(editor.revision)|\(edit)|\(dark)"
            guard sig != shownBoxes else { return }
            shownBoxes = sig
            boxesView.setNeedsDisplay()
        }

        private func drawBoxes(_ ctx: CGContext, area: InkGeometry.Rect) {
            var drew = false
            for slot in visibleSlots(area) where editor.hasBoxesOver(slot.spec.key) {
                drew = true
                let o = slot.offset
                ctx.saveGState()
                ctx.translateBy(x: o.x, y: o.y)
                let stored = editor.display(slot.spec.key, lifted: true)
                let shown = isDark(slot) ? InkDark.content(stored) : stored
                InkRenderer.drawTexts(shown.elements, in: ctx)
                // Tape covers the ink (PencilKit's, underneath this view) too.
                InkRenderer.drawTapes(shown.elements, peeked: shown.peeked, in: ctx)
                ctx.restoreGState()
            }
            boxesView.drewSomething = drew
        }

        private func drawOver(_ ctx: CGContext, area: InkGeometry.Rect, scale: Double) {
            overlayView.drewSomething = overlayHasContent(area)
            for slot in visibleSlots(area) {
                let o = slot.offset
                ctx.saveGState()
                ctx.translateBy(x: o.x, y: o.y)
                let darkSlot = isDark(slot)
                // Text boxes and tape are in `boxesView` underneath. What the lasso is dragging: lifted
                // off PencilKit's drawing while it moves, so a move redraws just this instead of
                // replacing the whole drawing on every frame.
                if let moving = editor.dragPreview(slot.spec.key) { InkRenderer.drawContent(darkSlot ? InkDark.content(moving) : moving, in: ctx) }
                InkRenderer.drawOverlay(editor.overlay(slot.spec.key), scale: scale, in: ctx)
                ctx.restoreGState()
            }
        }

        /// File pages near the screen get their whole-page picture (once each), and what's on screen a
        /// sharp one at the screen's resolution after a pinch or scroll settles; far ones are let go.
        private func prepareBitmaps(visible: CGRect, density: CGFloat) {
            let near = visible.insetBy(dx: -visible.width, dy: -visible.height)
            var seen: [(spec: InkPageSpec, rect: CGRect)] = []
            for slot in slots {
                switch slot.spec.background {
                case .paper:
                    continue
                case .pdf, .image, .goodnotes:
                    guard slot.frame.intersects(near) else { backdrop.drop(slot.spec.key); continue }
                    backdrop.prepare(slot.spec)
                    if slot.frame.intersects(visible) {
                        seen.append((slot.spec, visible.offsetBy(dx: -slot.offset.x, dy: -slot.offset.y)))
                    }
                }
            }
            backdrop.refine(seen, density: density)
        }

        // MARK: Ink

        /// Shows every page's strokes, unless the canvas already has this version of them. Strokes
        /// that look the same are kept as they are; the drawing is replaced only when something differs.
        func apply(version: Int, to canvas: PKCanvasView) {
            guard version != shownVersion else { return }
            if drawing { pending = true; return }
            var want: [(id: String, stamp: String, line: InkLine, offset: CGPoint)] = []
            var wanted: Set<String> = []
            var pictures = ""
            for slot in slots {
                // What the lasso is dragging is left out while it moves (the overlay draws it).
                let shown = editor.display(slot.spec.key, lifted: true)
                let darkSlot = isDark(slot)
                for line in shown.strokes where !line.points.isEmpty && wanted.insert(line.id).inserted {
                    // On a dark page the stroke is put on the canvas in its shown colour (and stamped
                    // with it, so turning the dark page on or off replaces it).
                    let drawn = darkSlot ? InkDark.line(line) : line
                    want.append((line.id, darkSlot ? line.stamp + "|dark" : line.stamp, drawn, slot.offset))
                }
                for e in shown.elements where e.kind == .image {
                    let ready = e.image.map { shown.pictures[$0.id] != nil } ?? false
                    pictures += "\(e.id)@\(e.frame.x),\(e.frame.y),\(e.frame.width),\(e.frame.height)\(ready ? "" : "?");"
                }
            }
            // The paper (with pictures, under the ink) redraws only when a picture came, went or moved.
            if pictures != shownPictures { shownPictures = pictures; paperView.setNeedsDisplay() }
            let modelIds = wanted
            let current = canvas.drawing.strokes
            var onCanvas: [String: PKStroke] = [:]
            var order: [String] = []
            var kept: [(stroke: PKStroke, id: String)] = []
            // Each stroke's id: from the known canvas order when it still fits, else by signature.
            var currentIds: [String?] = []
            if let known = canvasOrder, known.count == current.count {
                currentIds = known
            } else {
                var seen: [String: Int] = [:]
                for s in current {
                    let sig = PencilCanvas.signature(s)
                    let k = seen[sig, default: 0]
                    seen[sig] = k + 1
                    if let list = ids[sig], k < list.count { currentIds.append(list[k]) } else { currentIds.append(nil) }
                }
            }
            for (s, found) in zip(current, currentIds) {
                guard let id = found else { continue }
                if modelIds.contains(id), onCanvas[id] == nil { onCanvas[id] = s; order.append(id) }
                // Just drawn and still on its way to the model: keep it.
                else if handingOver.contains(id) { kept.append((s, id)) }
            }
            let known = currentIds.compactMap { $0 }
            canvasOrder = known.count == current.count ? known : nil
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
            var pkIds: [String] = []
            var stamps: [String: String] = [:]
            for w in want {
                let stroke = unchanged(w) ? onCanvas[w.id] : PencilCanvas.pkStroke(w.line, offset: w.offset)
                guard let stroke else { continue }
                pk.append(stroke)
                pkIds.append(w.id)
                stamps[w.id] = w.stamp
            }
            for k in kept {
                pk.append(k.stroke)
                pkIds.append(k.id)
            }
            canvas.drawing = PKDrawing(strokes: pk)
            // Matched by what the canvas now holds (not what was handed to it), so a stroke PencilKit
            // stores slightly differently is still known and never taken for a new one.
            var map: [String: [String]] = [:]
            for (s, id) in zip(canvas.drawing.strokes, pkIds) { map[PencilCanvas.signature(s), default: []].append(id) }
            ids = map
            canvasOrder = pkIds
            shownStamps = stamps
            stale = []
            shownVersion = version
            applying = false
        }

        func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) { drawing = true }

        func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
            drawing = false
            penLifted = Date()
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
            // Only PencilKit's pen adds strokes. With the lasso or eraser in hand, a stroke the canvas
            // doesn't know is an echo of a drawing set from the model: adding it would duplicate it (and
            // each copy would be added again, until the app ran out of memory).
            guard drawing || editor.tool.ink != nil || Date().timeIntervalSince(penLifted) < 2 else { return }
            var added: [PKStroke] = []
            let all = canvasView.drawing.strokes
            if let known = canvasOrder, all.count >= known.count {
                // The pen appends: what's past the known strokes is new.
                added = Array(all[known.count...])
            } else {
                canvasOrder = nil
                var seen: [String: Int] = [:]
                for s in all {
                    let sig = PencilCanvas.signature(s)
                    let k = seen[sig, default: 0]
                    seen[sig] = k + 1
                    if k >= (ids[sig]?.count ?? 0) { added.append(s) }
                }
            }
            guard !added.isEmpty else { return }
            let inHand = editor.tool.ink
            // Trove's copies, made now; saved a moment later, once the hold watcher has seen the pen lift.
            var strokes: [(signature: String, id: String, key: String, ink: (tool: InkTool, color: String, width: Double, points: [InkPoint]))] = []
            for s in added {
                guard let start = Array(s.path).first?.location.applying(s.transform), let slot = slot(at: start) else { continue }
                let ink = PencilCanvas.convert(s, offset: slot.offset, current: inHand, dark: isDark(slot))
                strokes.append((PencilCanvas.signature(s), UUID().uuidString.lowercased(), slot.spec.key, ink))
            }
            for s in strokes { ids[s.signature, default: []].append(s.id); handingOver.insert(s.id) }
            // A stroke that landed outside every page has no id: the order is no longer known.
            if strokes.count == added.count { canvasOrder?.append(contentsOf: strokes.map(\.id)) } else { canvasOrder = nil }
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
            if let canvas = scrollView as? TroveCanvasView { placeText(in: canvas) }
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

        /// Whether a finger works Trove's tools and draws (iPhone, or the Pencil-only setting off).
        func fingersDraw(_ canvas: PKCanvasView) -> Bool {
            canvas.drawingPolicy == .anyInput || !UIPencilInteraction.prefersPencilOnlyDrawing
        }

        /// A canvas point as a page point on the page under it.
        private func pagePoint(_ point: CGPoint, in canvas: PKCanvasView) -> (slot: Slot, point: InkPoint)? {
            let z = canvas.zoomScale
            let at = CGPoint(x: point.x / z, y: point.y / z)
            guard let slot = slot(at: at) else { return nil }
            return (slot, InkPoint(x: at.x - slot.offset.x, y: at.y - slot.offset.y))
        }

        /// Whether a finger at `point` takes hold of the selection or a guide (instead of scrolling).
        func grabHit(_ point: CGPoint, in canvas: PKCanvasView) -> Bool {
            guard let hit = pagePoint(point, in: canvas) else { return false }
            return editor.grabs(hit.point, pageKey: hit.slot.spec.key, scale: canvas.zoomScale)
        }

        /// Whether the Pencil at `point` is on the ruler or protractor with a pen in hand.
        func ruledHit(_ point: CGPoint, in canvas: PKCanvasView) -> Bool {
            guard editor.tool.ink != nil, let hit = pagePoint(point, in: canvas) else { return false }
            // Its knobs turn it (the protractor's pan, or the Pencil's drag below).
            if let g = editor.guideHit(hit.point, pageKey: hit.slot.spec.key, scale: canvas.zoomScale), g.turn != 0 { return true }
            return editor.guideSnap(hit.point, pageKey: hit.slot.spec.key, scale: canvas.zoomScale) != nil
        }

        /// The Pencil drawing along a guide (or turning it by a knob).
        func ruledTouch(_ phase: UITouch.Phase, at point: CGPoint, in canvas: PKCanvasView) {
            let z = canvas.zoomScale
            let at = CGPoint(x: point.x / z, y: point.y / z)
            if phase == .began { toolSlot = slot(at: at) }
            guard let slot = toolSlot else { return }
            let p = InkPoint(x: at.x - slot.offset.x, y: at.y - slot.offset.y)
            switch phase {
            case .began:
                if !editor.beginGuideDrag(p, pageKey: slot.spec.key, scale: z, pen: true) {
                    _ = editor.beginRuled(p, pageKey: slot.spec.key, scale: z)
                }
            case .moved: editor.pointerMoved(p)
            case .ended: editor.pointerUp(); toolSlot = nil
            default: editor.pointerCancelled(); toolSlot = nil
            }
            overlayView.setNeedsDisplay()
        }

        /// The tape under a point of the canvas, if any.
        func tapeAt(_ point: CGPoint, in canvas: PKCanvasView) -> (id: String, key: String)? {
            guard let hit = pagePoint(point, in: canvas), let strip = editor.tape(at: hit.point, key: hit.slot.spec.key) else { return nil }
            return (strip.id, hit.slot.spec.key)
        }

        @objc func tapeTapped(_ g: UITapGestureRecognizer) {
            guard g.state == .ended, let canvas = g.view as? PKCanvasView else { return }
            // Where a finger lassos (iPhone), its tap picks the tape instead.
            if editor.tool == .lasso, fingersDraw(canvas) { return }
            if let strip = tapeAt(g.location(in: canvas), in: canvas) { editor.togglePeek(strip.id) }
        }

        /// A hovering Pencil: its point on the page under it (nil when it leaves or touches down).
        /// Pens: PencilKit shows its own preview of the ink under a hovering Pencil, so Trove's tip
        /// isn't drawn too (that redrew the whole overlay, text boxes and all, on every hover move).
        @objc func hovered(_ g: UIHoverGestureRecognizer) {
            guard let canvas = g.view as? UIScrollView else { return }
            if editor.protractor != nil {
                // The protractor reads the angle of wherever the Pencil hovers.
                let z = canvas.zoomScale
                let raw = g.location(in: canvas)
                let at = CGPoint(x: raw.x / z, y: raw.y / z)
                let ended = g.state == .ended || g.state == .cancelled
                if let slot = slot(at: at), !ended {
                    editor.noteReading(InkPoint(x: at.x - slot.offset.x, y: at.y - slot.offset.y), pageKey: slot.spec.key)
                } else {
                    editor.noteReading(nil, pageKey: nil)
                }
            }
            guard editor.tool.ink == nil else { editor.pencilHover(nil, pageKey: nil, scale: canvas.zoomScale); return }
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
            // The overlay redraws when the model says something changed (`overlayRevision`).
        }
        @objc func redoTap() { editor.redo() }

        // MARK: The protractor (moved by a finger while a pen is in hand)

        /// Whether a touch at `point` (in the canvas) is on the protractor and should move it.
        func guideHit(_ point: CGPoint, in canvas: PKCanvasView) -> Bool {
            guard editor.tool.ink != nil else { return false }
            let z = canvas.zoomScale
            let at = CGPoint(x: point.x / z, y: point.y / z)
            guard let slot = slot(at: at) else { return false }
            return editor.guideHit(InkPoint(x: at.x - slot.offset.x, y: at.y - slot.offset.y), pageKey: slot.spec.key, scale: z) != nil
        }

        @objc func guidePanned(_ g: UIPanGestureRecognizer) {
            guard let canvas = g.view as? PKCanvasView else { return }
            let z = canvas.zoomScale
            let raw = g.location(in: canvas)
            let at = CGPoint(x: raw.x / z, y: raw.y / z)
            if g.state == .began { guideSlot = slot(at: at) }
            guard let slot = guideSlot else { return }
            let p = InkPoint(x: at.x - slot.offset.x, y: at.y - slot.offset.y)
            switch g.state {
            case .began:
                // The finger moves the protractor: it doesn't scroll, or draw where a finger draws.
                canvas.isScrollEnabled = false
                if canvas.drawingGestureRecognizer.isEnabled {
                    canvas.drawingGestureRecognizer.isEnabled = false
                    canvas.drawingGestureRecognizer.isEnabled = true
                }
                editor.beginGuideDrag(p, pageKey: slot.spec.key, scale: z, pen: false)
            case .changed:
                editor.pointerMoved(p)
            default:
                editor.pointerUp()
                canvas.isScrollEnabled = true
                guideSlot = nil
            }
            overlayView.setNeedsDisplay()
        }

        // MARK: Typing on the page

        /// Shows the text box being typed in as a text field at its place on the page (or takes it away).
        func showText(_ edit: InkTextEdit?, in canvas: TroveCanvasView) {
            guard let edit, slots.contains(where: { $0.spec.key == edit.pageKey }) else {
                if let tv = textView { tv.removeFromSuperview() }
                textView = nil
                textViewFor = nil
                return
            }
            if textView == nil || textViewFor != edit.id {
                textView?.removeFromSuperview()
                let tv = UITextView()
                tv.backgroundColor = Self.textFieldBackground(dark: dark)
                tv.layer.borderColor = UIColor.systemBlue.cgColor
                tv.layer.borderWidth = 1
                tv.textContainerInset = .zero
                tv.textContainer.lineFragmentPadding = 0
                tv.isScrollEnabled = false
                tv.delegate = textDelegate
                tv.text = edit.text
                canvas.addSubview(tv)
                textView = tv
                textViewFor = edit.id
                textLook = ""
                DispatchQueue.main.async { tv.becomeFirstResponder() }
            }
            if let tv = textView, tv.text != edit.text {
                tv.text = edit.text
                textLook = ""
            }
            placeText(in: canvas)
        }

        /// Puts the text field where its box is, at the canvas's zoom, in the box's font, size and colour.
        func placeText(in canvas: TroveCanvasView) {
            guard let tv = textView, let edit = editor.textEdit, let slot = slots.first(where: { $0.spec.key == edit.pageKey }) else { return }
            let z = canvas.zoomScale
            let size = CGFloat(edit.size) * z
            let ct = InkRenderer.font(size: Double(size), style: edit.style)
            let font = UIFont(name: CTFontCopyPostScriptName(ct) as String, size: size) ?? UIFont.systemFont(ofSize: size)
            let textColor = isDark(slot) ? InkDark.swap(edit.color) : edit.color
            let look = "\(edit.id)|\(size)|\(textColor)|\(edit.style.font.rawValue)|\(edit.style.bold)|\(edit.style.italic)"
            if look != textLook {
                textLook = look
                let paragraph = NSMutableParagraphStyle()
                paragraph.minimumLineHeight = size * 1.25
                paragraph.maximumLineHeight = size * 1.25
                let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: PencilCanvas.uiColor(textColor), .paragraphStyle: paragraph]
                tv.typingAttributes = attributes
                let all = NSRange(location: 0, length: tv.textStorage.length)
                tv.textStorage.setAttributes(attributes, range: all)
            }
            let w = CGFloat(edit.frame.width) * z
            let fit = tv.sizeThatFits(CGSize(width: w, height: .greatestFiniteMagnitude))
            let h = max(size * 1.25, fit.height)
            let left = (CGFloat(edit.frame.x) + slot.offset.x) * z, top = (CGFloat(edit.frame.y) + slot.offset.y) * z
            tv.transform = .identity
            if edit.rotate == 0 {
                tv.frame = CGRect(x: left, y: top, width: w, height: h)
            } else {
                // Turned about the box's centre, like it's drawn.
                let stored = CGFloat(edit.frame.height) * z
                tv.bounds = CGRect(x: 0, y: 0, width: w, height: max(h, stored))
                tv.center = CGPoint(x: left + w / 2, y: top + stored / 2)
                tv.transform = CGAffineTransform(rotationAngle: CGFloat(edit.rotate))
            }
            canvas.bringSubviewToFront(tv)
        }

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

/// A gesture delegate made of closures: which touches a gesture sees, and whether it may start.
@MainActor
final class InkGestureFilter: NSObject, UIGestureRecognizerDelegate {
    var shouldReceive: ((UITouch) -> Bool)?
    var shouldBegin: ((UIGestureRecognizer) -> Bool)?

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool { shouldReceive?(touch) ?? true }
    func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool { shouldBegin?(g) ?? true }
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        // Trove's tool gesture keeps its touch to itself (as without a delegate); the protractor's pan runs beside the canvas's own.
        shouldBegin != nil
    }
}

/// The text field's typing, handed to the editor; a Return in a bulleted line continues the list.
@MainActor
final class InkTextViewDelegate: NSObject, UITextViewDelegate {
    var changed: ((String) -> Void)?

    func textViewDidChange(_ textView: UITextView) { changed?(textView.text) }

    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        guard text == "\n", range.length == 0, let next = InkBullets.afterReturn(textView.text, at: range.location) else { return true }
        textView.text = next.text
        textView.selectedRange = NSRange(location: next.cursor, length: 0)
        changed?(next.text)
        return false
    }
}

/// One finger or the Pencil working Trove's eraser, lasso, laser or text tool (PencilKit's drawing is off then).
final class InkToolGesture: UIGestureRecognizer {
    var onTouch: ((UITouch.Phase, CGPoint) -> Void)?
    /// When set, the gesture takes only a touch this says yes to (asked as it touches down; no
    /// fails straight away, so gestures waiting on this one carry on at once).
    var claims: ((UITouch, CGPoint) -> Bool)?
    private weak var touch: UITouch?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if touch == nil, let claims, let t = touches.first, touches.count != 1 || !claims(t, t.location(in: view)) {
            state = .failed
            return
        }
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
