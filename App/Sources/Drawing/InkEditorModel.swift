import CoreGraphics
import Foundation
import Observation
import SwiftUI
import TroveCore

/// What the drawing editor is open on: a sketch's own pages, or a file (PDF or image) with its ink.
struct InkTarget: Identifiable, Hashable, Codable {
    var itemId: String
    /// "" for a sketch; the attachment id for a file.
    var layer: String
    var title: String
    var startPage = 0
    var id: String { itemId + "/" + layer }
}

/// The tools in the editor's toolbar, like the website's (web/public/draw.js).
enum InkEditorTool: String, CaseIterable, Identifiable {
    case pen, pencil, fountain, brush, marker, highlighter, eraser, lasso, text
    var id: String { rawValue }

    var ink: InkTool? { InkTool(rawValue: rawValue) }
    var label: String {
        switch self {
        case .pen: "Pen"
        case .pencil: "Pencil"
        case .fountain: "Fountain pen"
        case .brush: "Brush pen"
        case .marker: "Marker"
        case .highlighter: "Highlighter"
        case .eraser: "Eraser"
        case .lasso: "Lasso"
        case .text: "Text"
        }
    }
    var symbol: String {
        switch self {
        case .pen: "pencil.tip"
        case .pencil: "pencil"
        case .fountain: "signature"
        case .brush: "paintbrush"
        case .marker: "paintbrush.pointed"
        case .highlighter: "highlighter"
        case .eraser: "eraser"
        case .lasso: "lasso"
        case .text: "character.textbox"
        }
    }
    var defaultWidth: Double {
        switch self {
        case .pen: 2.5
        case .pencil: 2
        case .fountain: 4
        case .brush: 8
        case .marker: 7
        case .highlighter: 22
        case .eraser: 10
        case .lasso: 1
        case .text: 20
        }
    }
    var defaultColor: String {
        switch self {
        case .marker: "#0a84ff"
        case .highlighter: "#ffd60a"
        case .fountain: "#1c3d8f"
        default: "#1c1c1e"
        }
    }
    /// Pens and text have a colour; pens, text and the eraser a size.
    var hasColor: Bool { ink != nil || self == .text }
    var hasSize: Bool { hasColor || self == .eraser }
}

enum InkEraserMode: String, CaseIterable, Identifiable {
    case stroke, partial
    var id: String { rawValue }
    var label: String { self == .stroke ? "Whole strokes" : "Partial" }
}

/// What the lasso picked up on a page.
struct InkSelection: Equatable {
    var pageKey: String
    var strokes: Set<String>
    var elements: Set<String>
    var count: Int { strokes.count + elements.count }
}

/// A text box being typed in (a sheet in the editor).
struct InkTextEdit: Identifiable {
    var id = UUID().uuidString
    var elementId: String?
    var pageKey: String
    var frame: InkGeometry.Rect
    var text: String
    var size: Double
    var color: String
}

/// What the lasso copied, for pasting into this or another drawing.
struct InkClipboard {
    var lines: [InkLine]
    var boxes: [InkBox]
}

/// The editor's state: pages, the ink on each, the tool, the lasso's selection, and undo. Changes go
/// straight into the library (and sync). The canvases draw `display(_:)` and report what the pen,
/// mouse or finger did; the eraser, lasso and text tools are worked out here, the same on every
/// platform and like the website.
@MainActor
@Observable
final class InkEditorModel {
    static let colors = ["#1c1c1e", "#8e8e93", "#0a84ff", "#ff3b30", "#34c759", "#ff9500", "#af52de", "#ffd60a"]
    static var clipboard: InkClipboard?
    static let holdToSnap: TimeInterval = 0.55

    let target: InkTarget
    private(set) var pages: [InkPageSpec] = []
    private(set) var content: [String: InkContent] = [:]
    private(set) var pictures: [String: CGImage] = [:]
    var page = 0
    var tool: InkEditorTool { didSet { UserDefaults.standard.set(tool.rawValue, forKey: "ink.tool"); if tool != .lasso { clearSelection() } } }
    var eraserMode: InkEraserMode { didSet { UserDefaults.standard.set(eraserMode.rawValue, forKey: "ink.eraserMode") } }
    var highlighterOnly: Bool { didSet { UserDefaults.standard.set(highlighterOnly, forKey: "ink.highlighterOnly") } }
    var shapeMode: Bool { didSet { UserDefaults.standard.set(shapeMode, forKey: "ink.shapes") } }
    private(set) var previousTool: InkEditorTool = .pen
    private(set) var loaded = false
    private(set) var failed: String?
    private(set) var edited = false
    /// Bumped whenever the ink drawn changes, so canvases redraw it.
    private(set) var revision = 0
    /// Bumped when only what's drawn over the ink changes: the lasso's loop, the selection, the eraser's circle.
    private(set) var overlayRevision = 0
    /// Bumped when the pages change (added, moved, new paper).
    private(set) var pagesRevision = 0

    var selection: InkSelection? { didSet { overlayRevision += 1 } }
    private(set) var dragTransform: InkGeometry.Transform?
    private(set) var lassoPath: [InkPoint] = []
    private(set) var eraserAt: InkPoint?
    private(set) var eraserRadius = 10.0
    private(set) var erasePreview: [String: [[InkPoint]]] = [:]
    var textEdit: InkTextEdit?
    var showPages = false
    var exportedPDF: Data?
    var exporting = false
    /// Where new pictures go on an endless canvas (the middle of what's on screen), in page points.
    @ObservationIgnored var visibleCenter = InkPoint(x: 384, y: 400)

    private struct Ref { var id: String; var kind: String }
    private struct Action {
        var add: [Ref] = []
        var remove: [Ref] = []
        var before: [(ref: Ref, fields: [String: JSONValue])] = []
        var after: [(ref: Ref, fields: [String: JSONValue])] = []
    }
    private var undoStack: [Action] = []
    private var redoStack: [Action] = []

    private enum Gesture {
        case erase(key: String, last: InkPoint, removed: Set<String>)
        case partial(key: String, last: InkPoint)
        case lasso(key: String)
        case drag(key: String, start: InkPoint, corner: Int?, box: InkGeometry.Rect)
    }
    private var gesture: Gesture?
    @ObservationIgnored private weak var app: AppModel?
    private var pagesSig = ""

    init(target: InkTarget, app: AppModel) {
        self.target = target
        self.app = app
        page = target.startPage
        let d = UserDefaults.standard
        tool = InkEditorTool(rawValue: d.string(forKey: "ink.tool") ?? "") ?? .pen
        eraserMode = InkEraserMode(rawValue: d.string(forKey: "ink.eraserMode") ?? "") ?? .stroke
        highlighterOnly = d.bool(forKey: "ink.highlighterOnly")
        shapeMode = d.bool(forKey: "ink.shapes")
    }

    var isSketch: Bool { target.layer.isEmpty }
    var isInfinite: Bool { pages.first?.infinite ?? false }
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var currentPage: InkPageSpec? { pages.indices.contains(page) ? pages[page] : nil }
    var currentKey: String { currentPage?.key ?? "0" }

    // MARK: Colour and size per tool

    func color(for t: InkEditorTool) -> String { UserDefaults.standard.string(forKey: "ink.color.\(t.rawValue)") ?? t.defaultColor }
    func width(for t: InkEditorTool) -> Double {
        let w = UserDefaults.standard.double(forKey: "ink.width.\(t.rawValue)")
        return w > 0 ? w : t.defaultWidth
    }
    var color: String {
        get { color(for: tool.hasColor ? tool : .pen) }
        set {
            if let selection, tool == .lasso, selection.count > 0 { recolourSelection(newValue); return }
            if !tool.hasColor { tool = .pen }
            UserDefaults.standard.set(newValue, forKey: "ink.color.\(tool.rawValue)")
            revision += 1
        }
    }
    var width: Double {
        get { width(for: tool) }
        set { UserDefaults.standard.set(newValue, forKey: "ink.width.\(tool.rawValue)"); revision += 1 }
    }

    func select(_ t: InkEditorTool) {
        if t != tool { previousTool = tool }
        tool = t
    }

    /// Apple Pencil double-tap: the eraser and back, or the previous tool.
    func pencilTap(switchEraser: Bool) {
        if switchEraser { select(tool == .eraser ? previousTool : .eraser) } else { select(previousTool) }
    }

    // MARK: Loading

    func load() async {
        guard let app, let library = app.library else { return }
        if isSketch {
            guard let item = await library.item(target.itemId) else { failed = "This sketch isn't here any more."; return }
            pages = InkRenderer.sketchPages(item)
            pagesSig = Self.signature(item)
        } else {
            guard let item = await library.item(target.itemId), let att = item.attachments.first(where: { $0.id == target.layer }),
                  let data = try? await library.attachmentData(att) else { failed = "Couldn't open the file. It may still be syncing."; return }
            let mime = att.mime
            pages = await Task.detached(priority: .userInitiated) { InkRenderer.pages(for: data, mime: mime) }.value
            if pages.isEmpty { failed = "This file can't be drawn on."; return }
        }
        page = min(max(0, page), pages.count - 1)
        await reloadInk()
        loaded = true
    }

    private static func signature(_ item: Item) -> String {
        "\(item.sketchPageList.map { "\($0.id):\($0.paper?.rawValue ?? ""):\($0.color ?? "")" }.joined(separator: ","))|\(item.paper.rawValue)|\(item.isInfiniteCanvas)"
    }

    /// Picks up ink and pages from other devices (and our own writes).
    func reloadInk() async {
        guard let library = app?.library else { return }
        if isSketch, let item = await library.item(target.itemId) {
            let sig = Self.signature(item)
            if sig != pagesSig {
                let key = currentKey
                pagesSig = sig
                pages = InkRenderer.sketchPages(item)
                page = pages.firstIndex { $0.key == key } ?? min(page, max(0, pages.count - 1))
                pagesRevision += 1
            }
        }
        let strokes = await library.strokes(on: target.itemId, layer: target.layer)
        let elements = await library.elements(on: target.itemId, layer: target.layer)
        var next: [String: InkContent] = [:]
        for s in strokes { next[s.pageKey, default: InkContent()].strokes.append(InkLine(s)) }
        for e in elements { next[e.pageKey, default: InkContent()].elements.append(InkBox(e)) }
        content = next
        for e in elements where e.kind == .image {
            guard let att = e.image, pictures[att.id] == nil, let data = try? await library.attachmentData(att) else { continue }
            if let image = await Task.detached(priority: .userInitiated, operation: { InkRenderer.cgImage(data).map(InkImage.init) }).value {
                pictures[att.id] = image.image
            }
        }
        if let selection {
            let have = Set((content[selection.pageKey]?.strokes ?? []).map(\.id)), boxes = Set((content[selection.pageKey]?.elements ?? []).map(\.id))
            let kept = InkSelection(pageKey: selection.pageKey, strokes: selection.strokes.intersection(have), elements: selection.elements.intersection(boxes))
            self.selection = kept.count > 0 ? kept : nil
        }
        revision += 1
    }

    /// What to draw on a page: its ink with the lasso's move and the eraser's cuts shown as they happen.
    func display(_ key: String) -> InkContent {
        var c = content[key] ?? InkContent()
        c.pictures = pictures
        if !erasePreview.isEmpty {
            c.strokes = c.strokes.flatMap { line -> [InkLine] in
                guard let pieces = erasePreview[line.id] else { return [line] }
                return pieces.enumerated().map { i, pts in InkLine(id: "\(line.id)#\(i)", tool: line.tool, color: line.color, width: line.width, points: pts, shape: line.shape) }
            }
        }
        if let t = dragTransform, let sel = selection, sel.pageKey == key {
            c.strokes = c.strokes.map { sel.strokes.contains($0.id) ? $0.transformed(t) : $0 }
            c.elements = c.elements.map { sel.elements.contains($0.id) ? $0.transformed(t) : $0 }
        }
        return c
    }

    /// The lasso, selection and eraser over a page.
    func overlay(_ key: String) -> InkOverlay {
        var o = InkOverlay(eraser: eraserAt, eraserRadius: eraserRadius)
        if case .lasso(let k)? = gesture, k == key { o.lasso = lassoPath }
        if selection?.pageKey == key { o.selection = selectionBox() }
        return o
    }

    // MARK: Pens

    /// A finished pen stroke from a canvas. Shape mode, or holding still at the end (`held`), turns
    /// it into a clean shape; the result says so, so a canvas showing the rough line can redraw.
    @discardableResult
    func addStroke(points: [InkPoint], tool: InkTool, color: String, width: Double, id: String? = nil, pageKey: String? = nil, held: Bool = false) -> InkShapes.Result? {
        guard !points.isEmpty, let library = app?.library else { return nil }
        let snapped = shapeMode || held ? InkShapes.recognize(points) : nil
        let pts = snapped?.points ?? points
        let shape = snapped?.shape.rawValue
        let key = pageKey ?? currentKey
        let id = id ?? UUID().uuidString.lowercased()
        content[key, default: InkContent()].strokes.append(InkLine(id: id, tool: tool, color: color, width: width, points: pts, shape: shape))
        revision += 1
        record(Action(add: [Ref(id: id, kind: "stroke")]))
        let itemId = target.itemId, layer = target.layer
        Task {
            await library.addStroke(id: id, on: itemId, layer: layer, pageKey: key, tool: tool, color: color, width: width, points: pts, shape: shape)
            await reloadInk()
            app?.inkChanged()
        }
        return snapped
    }

    /// Strokes PencilKit's own eraser removed (not used while Trove's eraser is on, but kept in step).
    func removeStrokes(_ ids: [String], pageKey: String? = nil) {
        guard !ids.isEmpty, let library = app?.library else { return }
        let key = pageKey ?? currentKey
        content[key]?.strokes.removeAll { ids.contains($0.id) }
        revision += 1
        record(Action(remove: ids.map { Ref(id: $0, kind: "stroke") }))
        Task {
            await library.deleteStrokes(ids)
            await reloadInk()
            app?.inkChanged()
        }
    }

    // MARK: The eraser, lasso and text (pointer events in page points)

    /// `scale` is screen points per page point, so handles and the eraser keep their size on screen.
    func pointerDown(_ p: InkPoint, pageKey key: String, scale: Double) {
        let s = max(0.05, scale)
        switch tool {
        case .text:
            if let box = textBox(at: p, key: key) { beginText(box, key: key) } else { newText(at: p, key: key) }
        case .lasso:
            if let sel = selection, sel.pageKey == key, let box = selectionBox() {
                let r = 14 / s
                let corner = corners(box).firstIndex { hypot($0.x - p.x, $0.y - p.y) <= r }
                if corner != nil || (p.x >= box.x && p.x <= box.maxX && p.y >= box.y && p.y <= box.maxY) {
                    gesture = .drag(key: key, start: p, corner: corner, box: box)
                    return
                }
            }
            selection = nil
            lassoPath = [p]
            gesture = .lasso(key: key)
            overlayRevision += 1
        case .eraser:
            eraserRadius = (width(for: .eraser) / 2 + 4) / s
            eraserAt = p
            if eraserMode == .partial { gesture = .partial(key: key, last: p) } else { gesture = .erase(key: key, last: p, removed: []) }
            eraseTo(p)
        default:
            break
        }
    }

    func pointerMoved(_ p: InkPoint) {
        switch gesture {
        case .erase, .partial:
            eraseTo(p)
        case .lasso:
            lassoPath.append(p)
            overlayRevision += 1
        case .drag(_, let start, let corner, let box):
            if let corner {
                // Resize from the opposite corner, keeping the proportions.
                let c = corners(box), o = c[(corner + 2) % 4], h = c[corner]
                let sx = (p.x - o.x) / (h.x - o.x == 0 ? 1 : h.x - o.x), sy = (p.y - o.y) / (h.y - o.y == 0 ? 1 : h.y - o.y)
                let k = max(0.05, (sx + sy) / 2)
                dragTransform = InkGeometry.Transform(sx: k, sy: k, ox: o.x, oy: o.y)
            } else {
                dragTransform = .move(p.x - start.x, p.y - start.y)
            }
            revision += 1
        case nil:
            break
        }
    }

    func pointerUp() {
        let g = gesture
        gesture = nil
        switch g {
        case .erase(_, _, let removed):
            eraserAt = nil
            if !removed.isEmpty { record(Action(remove: removed.map { Ref(id: $0, kind: "stroke") })) }
            overlayRevision += 1
        case .partial:
            eraserAt = nil
            commitPartialErase()
        case .lasso(let key):
            finishLasso(key)
        case .drag:
            commitDrag()
        case nil:
            break
        }
    }

    func pointerCancelled() {
        switch gesture {
        case .partial: erasePreview = [:]
        case .drag: dragTransform = nil
        case .lasso: lassoPath = []
        default: break
        }
        if case .erase(_, _, let removed) = gesture, !removed.isEmpty { record(Action(remove: removed.map { Ref(id: $0, kind: "stroke") })) }
        gesture = nil
        eraserAt = nil
        revision += 1
        overlayRevision += 1
    }

    /// The eraser's circle under a hovering pen or mouse.
    func hover(_ p: InkPoint?, scale: Double) {
        guard tool == .eraser, gesture == nil else { if eraserAt != nil && gesture == nil { eraserAt = nil; overlayRevision += 1 }; return }
        eraserRadius = (width(for: .eraser) / 2 + 4) / max(0.05, scale)
        eraserAt = p
        overlayRevision += 1
    }

    private func eraseTo(_ p: InkPoint) {
        eraserAt = p
        let only: Set<InkTool>? = highlighterOnly ? [.highlighter] : nil
        switch gesture {
        case .erase(let key, let last, var removed):
            let path = [last, p]
            let gone = (content[key]?.strokes ?? []).filter { line in
                (only == nil || only!.contains(line.tool)) && InkGeometry.erase(line.points, along: path, radius: eraserRadius + line.width / 2) != nil
            }.map(\.id)
            if !gone.isEmpty, let library = app?.library {
                content[key]?.strokes.removeAll { gone.contains($0.id) }
                removed.formUnion(gone)
                Task { await library.deleteStrokes(gone); app?.inkChanged() }
            }
            gesture = .erase(key: key, last: p, removed: removed)
        case .partial(let key, let last):
            let path = [last, p]
            for line in content[key]?.strokes ?? [] where only == nil || only!.contains(line.tool) {
                let current = erasePreview[line.id] ?? [line.points]
                var changed = false
                let next = current.flatMap { piece -> [[InkPoint]] in
                    guard let cut = InkGeometry.erase(piece, along: path, radius: eraserRadius + line.width / 2) else { return [piece] }
                    changed = true
                    return cut
                }
                if changed { erasePreview[line.id] = next }
            }
            gesture = .partial(key: key, last: p)
        default:
            break
        }
        edited = true
        revision += 1
        overlayRevision += 1
    }

    /// The partial eraser lifts: each stroke it cut becomes its pieces, in its place.
    private func commitPartialErase() {
        let preview = erasePreview
        guard !preview.isEmpty, let library = app?.library else { erasePreview = [:]; revision += 1; return }
        Task {
            var action = Action()
            for (id, pieces) in preview {
                let added = await library.replaceStroke(id, with: pieces)
                action.remove.append(Ref(id: id, kind: "stroke"))
                action.add += added.map { Ref(id: $0, kind: "stroke") }
            }
            record(action)
            await reloadInk()
            erasePreview = [:]
            revision += 1
            app?.inkChanged()
        }
    }

    private func finishLasso(_ key: String) {
        let loop = lassoPath
        lassoPath = []
        guard loop.count >= 3 else { overlayRevision += 1; return }
        let c = content[key] ?? InkContent()
        let strokes = c.strokes.filter { InkGeometry.lassoSelects($0.points, lasso: loop) }.map(\.id)
        let boxes = c.elements.filter { InkGeometry.lassoSelects($0.drawnFrame, lasso: loop) }.map(\.id)
        let picked = InkSelection(pageKey: key, strokes: Set(strokes), elements: Set(boxes))
        selection = picked.count > 0 ? picked : nil
    }

    /// The box around the selection, moved by the drag in progress.
    func selectionBox() -> InkGeometry.Rect? {
        guard let sel = selection else { return nil }
        let c = content[sel.pageKey] ?? InkContent()
        var box: InkGeometry.Rect?
        for line in c.strokes where sel.strokes.contains(line.id) { box = InkGeometry.union(box, line.bounds) }
        for b in c.elements where sel.elements.contains(b.id) { box = InkGeometry.union(box, b.drawnFrame) }
        if let box, let t = dragTransform { return t.apply(box) }
        return box
    }

    func corners(_ b: InkGeometry.Rect) -> [InkPoint] {
        [InkPoint(x: b.x, y: b.y), InkPoint(x: b.maxX, y: b.y), InkPoint(x: b.maxX, y: b.maxY), InkPoint(x: b.x, y: b.maxY)]
    }

    private static let strokeFields = ["points", "width", "color"], elementFields = ["x", "y", "w", "h", "size", "color", "text"]

    /// Fields the lasso changes, read before and after, so undo can put them back.
    private func snapshot(_ sel: InkSelection) async -> [(ref: Ref, fields: [String: JSONValue])] {
        guard let library = app?.library else { return [] }
        var out: [(ref: Ref, fields: [String: JSONValue])] = []
        for id in sel.strokes { out.append((Ref(id: id, kind: "stroke"), await library.inkFields(id, Self.strokeFields))) }
        for id in sel.elements { out.append((Ref(id: id, kind: "element"), await library.inkFields(id, Self.elementFields))) }
        return out
    }

    private func commitDrag() {
        guard let t = dragTransform, let sel = selection, let library = app?.library else { dragTransform = nil; revision += 1; return }
        // Show it where it landed straight away.
        content[sel.pageKey]?.strokes = (content[sel.pageKey]?.strokes ?? []).map { sel.strokes.contains($0.id) ? $0.transformed(t) : $0 }
        content[sel.pageKey]?.elements = (content[sel.pageKey]?.elements ?? []).map { sel.elements.contains($0.id) ? $0.transformed(t) : $0 }
        dragTransform = nil
        revision += 1
        Task {
            let before = await snapshot(sel)
            await library.transformStrokes(Array(sel.strokes), by: t)
            await library.transformElements(Array(sel.elements), by: t)
            record(Action(before: before, after: await snapshot(sel)))
            await reloadInk()
            app?.inkChanged()
        }
    }

    // MARK: The selection

    func recolourSelection(_ color: String) {
        guard let sel = selection, let library = app?.library else { return }
        Task {
            let before = await snapshot(sel)
            await library.transformStrokes(Array(sel.strokes), color: color)
            for id in sel.elements { await library.updateElement(id, color: color) }
            record(Action(before: before, after: await snapshot(sel)))
            await reloadInk()
            app?.inkChanged()
        }
    }

    func duplicateSelection() {
        guard let sel = selection, let library = app?.library else { return }
        let itemId = target.itemId, layer = target.layer
        Task {
            let ids = await library.duplicateInk(strokes: Array(sel.strokes), elements: Array(sel.elements), to: itemId, layer: layer, pageKey: sel.pageKey)
            await reloadInk()
            selectIds(ids, key: sel.pageKey)
            record(Action(add: ids.map { Ref(id: $0, kind: kind(of: $0, key: sel.pageKey)) }))
            app?.inkChanged()
        }
    }

    private func kind(of id: String, key: String) -> String {
        content[key]?.elements.contains { $0.id == id } == true ? "element" : "stroke"
    }

    private func selectIds(_ ids: [String], key: String) {
        let c = content[key] ?? InkContent()
        let set = Set(ids)
        if tool != .lasso { tool = .lasso }
        let picked = InkSelection(pageKey: key, strokes: Set(c.strokes.map(\.id)).intersection(set), elements: Set(c.elements.map(\.id)).intersection(set))
        selection = picked.count > 0 ? picked : nil
    }

    func copySelection() {
        guard let sel = selection else { return }
        let c = content[sel.pageKey] ?? InkContent()
        Self.clipboard = InkClipboard(lines: c.strokes.filter { sel.strokes.contains($0.id) }, boxes: c.elements.filter { sel.elements.contains($0.id) })
        revision += 1
    }

    func deleteSelection() {
        guard let sel = selection, let library = app?.library else { return }
        content[sel.pageKey]?.strokes.removeAll { sel.strokes.contains($0.id) }
        content[sel.pageKey]?.elements.removeAll { sel.elements.contains($0.id) }
        selection = nil
        record(Action(remove: sel.strokes.map { Ref(id: $0, kind: "stroke") } + sel.elements.map { Ref(id: $0, kind: "element") }))
        Task {
            await library.deleteStrokes(Array(sel.strokes))
            await library.deleteElements(Array(sel.elements))
            await reloadInk()
            app?.inkChanged()
        }
    }

    func cutSelection() { copySelection(); deleteSelection() }

    func selectAll() {
        let c = content[currentKey] ?? InkContent()
        selectIds(c.strokes.map(\.id) + c.elements.map(\.id), key: currentKey)
    }

    func clearSelection() {
        guard selection != nil || dragTransform != nil else { return }
        selection = nil
        dragTransform = nil
    }

    /// Pastes what the lasso copied onto the page in view, a little down and right.
    func paste() {
        guard let clip = Self.clipboard, let library = app?.library else { return }
        let itemId = target.itemId, layer = target.layer, key = currentKey
        let t = InkGeometry.Transform.move(20, 20)
        Task {
            var ids: [String] = []
            for l in clip.lines {
                if let id = await library.addStroke(on: itemId, layer: layer, pageKey: key, tool: l.tool, color: l.color, width: l.width,
                                                    points: l.points.map { t.apply($0) }, shape: l.shape) { ids.append(id) }
            }
            for b in clip.boxes {
                ids.append(await library.addElement(on: itemId, layer: layer, pageKey: key, kind: b.kind, frame: t.apply(b.frame), text: b.text,
                                                    size: b.size, color: b.color, image: b.image))
            }
            await reloadInk()
            selectIds(ids, key: key)
            record(Action(add: ids.map { Ref(id: $0, kind: kind(of: $0, key: key)) }))
            app?.inkChanged()
        }
    }

    var canPaste: Bool { Self.clipboard != nil }

    // MARK: Text boxes

    private func textBox(at p: InkPoint, key: String) -> InkBox? {
        (content[key]?.elements ?? []).reversed().first { b in
            let f = b.drawnFrame
            return b.kind == .text && p.x >= f.x && p.x <= f.maxX && p.y >= f.y && p.y <= f.maxY
        }
    }

    private func newText(at p: InkPoint, key: String) {
        let size = width(for: .text)
        let pageWidth = currentPage.map { $0.infinite ? 0 : $0.width } ?? 0
        let w = pageWidth > 0 ? max(120, min(360, pageWidth - p.x - 16)) : 320
        textEdit = InkTextEdit(elementId: nil, pageKey: key, frame: InkGeometry.Rect(x: p.x, y: p.y - size * 0.6, width: w, height: size * 1.25),
                               text: "", size: size, color: color(for: .text))
    }

    private func beginText(_ box: InkBox, key: String) {
        textEdit = InkTextEdit(elementId: box.id, pageKey: key, frame: box.frame, text: box.text, size: box.size, color: box.color)
    }

    /// The text sheet's Done: a new box, a changed one, or (emptied) none.
    func commitText(_ edit: InkTextEdit) {
        textEdit = nil
        guard let library = app?.library else { return }
        let text = edit.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let itemId = target.itemId, layer = target.layer
        var frame = edit.frame
        frame.height = InkRenderer.textHeight(text, width: frame.width, size: edit.size)
        Task {
            if let id = edit.elementId {
                let sel = InkSelection(pageKey: edit.pageKey, strokes: [], elements: [id])
                if text.isEmpty {
                    await library.deleteElements([id])
                    record(Action(remove: [Ref(id: id, kind: "element")]))
                } else {
                    let before = await snapshot(sel)
                    await library.updateElement(id, frame: frame, text: text, size: edit.size, color: edit.color)
                    record(Action(before: before, after: await snapshot(sel)))
                }
            } else if !text.isEmpty {
                let id = await library.addElement(on: itemId, layer: layer, pageKey: edit.pageKey, kind: .text, frame: frame, text: text,
                                                  size: edit.size, color: edit.color)
                record(Action(add: [Ref(id: id, kind: "element")]))
            }
            await reloadInk()
            app?.inkChanged()
        }
    }

    // MARK: Pictures

    func insertPicture(_ data: Data, mime: String) {
        guard let library = app?.library, let image = InkRenderer.cgImage(data), let spec = currentPage else { return }
        let key = spec.key
        let area: InkGeometry.Rect = spec.infinite
            ? InkGeometry.Rect(x: visibleCenter.x - 300, y: visibleCenter.y - 300, width: 600, height: 600)
            : InkGeometry.Rect(x: 0, y: 0, width: spec.width, height: spec.height)
        let w = min(Double(image.width), area.width * 0.6), h = w * Double(image.height) / Double(max(1, image.width))
        let frame = InkGeometry.Rect(x: area.x + (area.width - w) / 2, y: area.y + max(16, (area.height - h) / 3), width: w, height: h)
        let itemId = target.itemId, layer = target.layer
        Task {
            guard let id = try? await library.addPicture(data, mime: mime, on: itemId, layer: layer, pageKey: key, frame: frame) else { return }
            record(Action(add: [Ref(id: id, kind: "element")]))
            await reloadInk()
            selectIds([id], key: key)
            app?.inkChanged()
        }
    }

    // MARK: Undo

    private func record(_ action: Action) {
        undoStack.append(action)
        redoStack.removeAll()
        edited = true
    }

    private func apply(_ a: Action, forward: Bool) async {
        guard let library = app?.library else { return }
        await library.setInk((forward ? a.remove : a.add).map { (id: $0.id, kind: $0.kind) }, alive: false)
        await library.setInk((forward ? a.add : a.remove).map { (id: $0.id, kind: $0.kind) }, alive: true)
        for change in forward ? a.after : a.before { await library.setInkFields(change.ref.id, kind: change.ref.kind, change.fields) }
        edited = true
        selection = nil
        await reloadInk()
        app?.inkChanged()
    }

    func undo() {
        guard let action = undoStack.popLast() else { return }
        redoStack.append(action)
        Task { await apply(action, forward: false) }
    }

    func redo() {
        guard let action = redoStack.popLast() else { return }
        undoStack.append(action)
        Task { await apply(action, forward: true) }
    }

    // MARK: Pages

    private func pagesChanged(focus: String? = nil) async {
        await reloadInk()
        if let focus, let i = pages.firstIndex(where: { $0.key == focus }) { page = i }
        edited = true
        app?.inkChanged()
    }

    func addPage(after: String? = nil) {
        guard isSketch, let library = app?.library else { return }
        let itemId = target.itemId, after = after ?? pages.last?.key
        Task {
            let id = await library.addPage(to: itemId, after: after)
            await pagesChanged(focus: id)
        }
    }

    func duplicatePage(_ key: String) {
        guard isSketch, let library = app?.library else { return }
        let itemId = target.itemId
        Task { await pagesChanged(focus: await library.duplicatePage(key, of: itemId)) }
    }

    func movePage(_ key: String, to index: Int) {
        guard isSketch, let library = app?.library else { return }
        let itemId = target.itemId
        Task {
            await library.movePage(key, of: itemId, to: index)
            await pagesChanged(focus: key)
        }
    }

    func deletePage(_ key: String) {
        guard isSketch, pages.count > 1, let library = app?.library else { return }
        let itemId = target.itemId
        // Undo doesn't reach across a deleted page.
        undoStack.removeAll()
        redoStack.removeAll()
        Task {
            await library.deletePage(key, of: itemId)
            await pagesChanged()
        }
    }

    func setPage(_ key: String, paper: InkPaper? = nil, color: String? = nil) {
        guard isSketch, let library = app?.library else { return }
        let itemId = target.itemId
        Task {
            await library.setPage(key, of: itemId, paper: paper, color: color)
            await pagesChanged()
        }
    }

    /// One paper for every page.
    func setPaper(_ p: InkPaper) {
        guard isSketch, let library = app?.library else { return }
        let itemId = target.itemId, keys = pages.map(\.key)
        Task {
            await library.setSketch(itemId, paper: p)
            for key in keys { await library.setPage(key, of: itemId, paper: p) }
            await pagesChanged()
        }
    }

    var paper: InkPaper {
        if case .paper(let p, _)? = currentPage?.background { return p }
        return .blank
    }

    func setInfinite(_ on: Bool) {
        guard isSketch, let library = app?.library else { return }
        let itemId = target.itemId
        clearSelection()
        Task {
            await library.setSketchCanvas(itemId, infinite: on)
            page = 0
            await pagesChanged(focus: "0")
        }
    }

    // MARK: Export, thumbnails, handwriting

    /// Every page as a PDF (vector ink and text over the paper, PDF pages or pictures).
    func exportPDF() {
        guard let library = app?.library else { return }
        exporting = true
        let specs = pages, itemId = target.itemId, layer = target.layer, all = specs.map { display($0.key) }
        Task {
            var input: [(spec: InkPageSpec, content: InkContent, bounds: InkGeometry.Rect?)] = []
            for (spec, c) in zip(specs, all) {
                let bounds = spec.infinite ? await library.inkBounds(on: itemId, layer: layer, pageKey: spec.key) : nil
                input.append((spec, c, bounds))
            }
            let pages = input
            exportedPDF = await Task.detached(priority: .userInitiated) { InkRenderer.pdf(pages: pages) }.value
            exporting = false
        }
    }

    /// When the editor closes: a fresh card picture for a sketch, and its handwriting read for search.
    func finish() async {
        guard edited, isSketch, let first = pages.first, let library = app?.library else { return }
        edited = false // once: Done and closing the window both land here
        let c = display(first.key)
        let bounds = first.infinite ? await library.inkBounds(on: target.itemId, pageKey: first.key) : nil
        if let jpeg = await Task.detached(priority: .utility, operation: { InkRenderer.thumbnailJPEG(first, content: c, bounds: bounds) }).value {
            try? await library.setThumbnail(target.itemId, jpeg: jpeg)
        }
        await Handwriting.read(target.itemId, library: library)
        app?.inkChanged()
    }
}
