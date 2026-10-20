#if os(iOS)
import PencilKit
import SwiftUI
import TroveCore
import UIKit

/// The drawing surface on iPhone and iPad: PencilKit, so Apple Pencil gets pressure, tilt and palm
/// rejection (and a finger draws on iPhone), over the page's paper, PDF page or image. Strokes
/// convert to and from Trove's own (PROTOCOL.md §10), so the website and the Mac see the same ink.
struct PencilCanvas: UIViewRepresentable {
    let editor: InkEditorModel
    let page: InkPageSpec
    let pageIndex: Int
    let strokes: [InkStroke]
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
        canvas.addInteraction(UIPencilInteraction(delegate: c))
        canvas.onLayout = { [weak c, weak canvas] in if let c, let canvas { c.layout(canvas) } }
        return canvas
    }

    func updateUIView(_ canvas: TroveCanvasView, context: Context) {
        let c = context.coordinator
        c.editor = editor
        c.show(pageIndex, page, key: "\(pageIndex)-\(editor.paper.rawValue)", in: canvas)
        c.apply(strokes, to: canvas)
        canvas.tool = Self.pkTool(tool, color: color, width: width)
    }

    static func pkTool(_ tool: InkEditorTool, color: String, width: Double) -> PKTool {
        switch tool {
        case .eraser: return PKEraserTool(.vector)
        case .pen: return PKInkingTool(.pen, color: uiColor(color), width: width)
        case .pencil: return PKInkingTool(.pencil, color: uiColor(color), width: width)
        case .marker: return PKInkingTool(.monoline, color: uiColor(color), width: width)
        case .highlighter: return PKInkingTool(.marker, color: uiColor(color), width: width)
        }
    }

    // MARK: Converting strokes

    static func uiColor(_ hex: String) -> UIColor {
        let (r, g, b) = InkStroke.rgb(hex)
        return UIColor(red: r, green: g, blue: b, alpha: 1)
    }

    static func hex(_ color: UIColor) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light)).getRed(&r, green: &g, blue: &b, alpha: &a)
        func byte(_ v: CGFloat) -> Int { Int((min(1, max(0, v)) * 255).rounded()) }
        return String(format: "#%02x%02x%02x", byte(r), byte(g), byte(b))
    }

    static func pkStroke(_ s: InkStroke) -> PKStroke {
        let inkType: PKInk.InkType = switch s.tool {
        case .pen: .pen
        case .pencil: .pencil
        case .marker: .monoline
        case .highlighter: .marker
        case .fountain: .fountainPen
        case .brush: .watercolor
        }
        let points = s.points.map { p in
            let w = InkStroke.width(s.width, tool: s.tool, pressure: p.pressure)
            return PKStrokePoint(location: CGPoint(x: p.x, y: p.y), timeOffset: p.t / 1000, size: CGSize(width: w, height: w),
                                 opacity: 1, force: p.pressure * 2, azimuth: 0, altitude: .pi / 2)
        }
        return PKStroke(ink: PKInk(inkType, color: uiColor(s.color)), path: PKStrokePath(controlPoints: points, creationDate: s.createdAt))
    }

    static func convert(_ s: PKStroke) -> (tool: InkTool, color: String, width: Double, points: [InkPoint]) {
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
            return InkPoint(x: at.x, y: at.y, pressure: pressure, t: p.timeOffset * 1000)
        }
        return (tool, hex(s.ink.color), width, points)
    }

    /// PencilKit strokes have no ids, so they're matched by creation time and length.
    static func signature(_ s: PKStroke) -> String {
        "\(Int((s.path.creationDate.timeIntervalSince1970 * 1000).rounded()))-\(s.path.count)"
    }

    // MARK: Coordinator

    @MainActor
    final class Coordinator: NSObject, PKCanvasViewDelegate, UIPencilInteractionDelegate {
        var editor: InkEditorModel
        let backgroundView = UIImageView()
        private var pageIndex = -1
        private var pageKey = ""
        private var page: InkPageSpec?
        private var fittedWidth: CGFloat = 0
        /// Signature → Trove stroke id for what's on the canvas.
        private var ids: [String: String] = [:]
        private var shown: [String] = []
        private var applying = false
        private var drawing = false
        private var pending: [InkStroke]?
        private var backgroundTask: Task<Void, Never>?

        init(editor: InkEditorModel) {
            self.editor = editor
            backgroundView.contentMode = .scaleToFill
            backgroundView.backgroundColor = .white
        }

        func show(_ index: Int, _ spec: InkPageSpec, key: String, in canvas: TroveCanvasView) {
            guard key != pageKey else { return }
            pageKey = key
            if index == pageIndex {
                // Same page, new paper.
                page = spec
                renderBackground(spec, width: max(canvas.bounds.width, 600))
                return
            }
            pageIndex = index
            page = spec
            fittedWidth = 0
            shown = []
            ids = [:]
            applying = true
            canvas.drawing = PKDrawing()
            applying = false
            backgroundView.image = nil
            layout(canvas)
            canvas.setContentOffset(.zero, animated: false)
            renderBackground(spec, width: max(canvas.bounds.width, 600))
        }

        /// Fits the page's width to the view (and again on rotation); zoom from there.
        func layout(_ canvas: TroveCanvasView) {
            guard let page, canvas.bounds.width > 0 else { return }
            if fittedWidth != canvas.bounds.width {
                fittedWidth = canvas.bounds.width
                let fit = canvas.bounds.width / page.width
                canvas.minimumZoomScale = fit * 0.75
                canvas.maximumZoomScale = fit * 6
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
            let inset = max(0, (canvas.bounds.width - size.width) / 2)
            canvas.contentInset = UIEdgeInsets(top: 0, left: inset, bottom: 0, right: inset)
        }

        private func renderBackground(_ spec: InkPageSpec, width: CGFloat) {
            backgroundTask?.cancel()
            let pixels = Int(min(4096, width * max(2, UITraitCollection.current.displayScale) * 1.5))
            backgroundTask = Task { [weak self] in
                let rendered = await Task.detached(priority: .userInitiated) { InkRenderer.render(spec, strokes: [], pixelWidth: pixels).map(InkImage.init) }.value
                guard !Task.isCancelled, let rendered else { return }
                self?.backgroundView.image = UIImage(cgImage: rendered.image)
            }
        }

        /// Shows the page's strokes, unless the canvas already has exactly them.
        func apply(_ strokes: [InkStroke], to canvas: PKCanvasView) {
            let wanted = strokes.map(\.id)
            guard wanted != shown else { return }
            if drawing { pending = strokes; return }
            applying = true
            let pk = strokes.map(PencilCanvas.pkStroke)
            canvas.drawing = PKDrawing(strokes: pk)
            ids = Dictionary(zip(pk.map(PencilCanvas.signature), wanted), uniquingKeysWith: { a, _ in a })
            shown = wanted
            applying = false
        }

        func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) { drawing = true }

        func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
            drawing = false
            if let pending { self.pending = nil; apply(pending, to: canvasView) }
        }

        /// New strokes are added and erased ones deleted, in Trove's records.
        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            guard !applying else { return }
            var seen: Set<String> = []
            var added: [PKStroke] = []
            for s in canvasView.drawing.strokes {
                if let id = ids[PencilCanvas.signature(s)] { seen.insert(id) } else { added.append(s) }
            }
            let removed = Set(ids.values).subtracting(seen)
            if !removed.isEmpty {
                ids = ids.filter { !removed.contains($0.value) }
                shown.removeAll { removed.contains($0) }
                editor.erase(Array(removed), on: pageIndex)
            }
            for s in added {
                let id = UUID().uuidString.lowercased()
                ids[PencilCanvas.signature(s)] = id
                shown.append(id)
                let c = PencilCanvas.convert(s)
                editor.add(points: c.points, tool: c.tool, color: c.color, width: c.width, id: id, on: pageIndex)
            }
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            if let canvas = scrollView as? PKCanvasView { resize(canvas) }
        }

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
#endif
