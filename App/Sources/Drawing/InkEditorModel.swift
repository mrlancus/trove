import Foundation
import Observation
import SwiftUI
import TroveCore

/// What the drawing editor is open on: a sketch's own pages, or a file (PDF or image) with its ink.
struct InkTarget: Identifiable, Hashable {
    var itemId: String
    /// "" for a sketch; the attachment id for a file.
    var layer: String
    var title: String
    var startPage = 0
    var id: String { itemId + "/" + layer }
}

/// The tools in the editor's toolbar: the four inks and the stroke eraser.
enum InkEditorTool: String, CaseIterable, Identifiable {
    case pen, pencil, marker, highlighter, eraser
    var id: String { rawValue }

    var ink: InkTool? { InkTool(rawValue: rawValue) }
    var label: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .pen: "pencil.tip"
        case .pencil: "pencil"
        case .marker: "paintbrush.pointed"
        case .highlighter: "highlighter"
        case .eraser: "eraser"
        }
    }
    var defaultWidth: Double {
        switch self {
        case .pen: 2.5
        case .pencil: 2
        case .marker: 7
        case .highlighter: 22
        case .eraser: 10
        }
    }
    var defaultColor: String {
        switch self {
        case .marker: "#0a84ff"
        case .highlighter: "#ffd60a"
        default: "#1c1c1e"
        }
    }
}

/// The editor's state: pages, strokes per page, the chosen tool, colour and size, and undo.
/// Changes go straight into the library (and sync); `InkCanvas` views draw and report strokes.
@MainActor
@Observable
final class InkEditorModel {
    static let colors = ["#1c1c1e", "#8e8e93", "#0a84ff", "#ff3b30", "#34c759", "#ff9500", "#af52de", "#ffd60a"]

    let target: InkTarget
    private(set) var pages: [InkPageSpec] = []
    private(set) var strokes: [Int: [InkStroke]] = [:]
    var page = 0
    var paper: InkPaper = .blank
    var tool: InkEditorTool { didSet { UserDefaults.standard.set(tool.rawValue, forKey: "ink.tool") } }
    private(set) var previousTool: InkEditorTool = .pen
    private(set) var loaded = false
    private(set) var failed: String?
    private(set) var edited = false
    /// Bumped when strokes change, so canvases redraw.
    private(set) var revision = 0

    private struct Action {
        enum Kind { case add, erase }
        var kind: Kind
        var page: Int
        var strokes: [Saved]
        var ids: [String]
    }
    struct Saved {
        var tool: InkTool, color: String, width: Double, points: [InkPoint]
    }
    private var undoStack: [Action] = []
    private var redoStack: [Action] = []
    @ObservationIgnored private weak var app: AppModel?

    init(target: InkTarget, app: AppModel) {
        self.target = target
        self.app = app
        page = target.startPage
        tool = InkEditorTool(rawValue: UserDefaults.standard.string(forKey: "ink.tool") ?? "") ?? .pen
    }

    var isSketch: Bool { target.layer.isEmpty }
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var currentPage: InkPageSpec? { pages.indices.contains(page) ? pages[page] : nil }
    var currentStrokes: [InkStroke] { strokes[page] ?? [] }

    // MARK: Colour and size per tool

    func color(for t: InkEditorTool) -> String { UserDefaults.standard.string(forKey: "ink.color.\(t.rawValue)") ?? t.defaultColor }
    func width(for t: InkEditorTool) -> Double {
        let w = UserDefaults.standard.double(forKey: "ink.width.\(t.rawValue)")
        return w > 0 ? w : t.defaultWidth
    }
    var color: String {
        get { color(for: tool == .eraser ? .pen : tool) }
        set {
            if tool == .eraser { tool = .pen }
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
            paper = item.paper
            let size = item.sketchPageSize
            pages = Array(repeating: InkPageSpec(width: size.width, height: size.height, background: .paper(item.paper)), count: item.sketchPages)
        } else {
            guard let item = await library.item(target.itemId), let att = item.attachments.first(where: { $0.id == target.layer }),
                  let data = try? await library.attachmentData(att) else { failed = "Couldn't open the file. It may still be syncing."; return }
            let mime = att.mime
            pages = await Task.detached(priority: .userInitiated) { InkRenderer.pages(for: data, mime: mime) }.value
            if pages.isEmpty { failed = "This file can't be drawn on."; return }
        }
        page = min(max(0, page), pages.count - 1)
        await reloadStrokes()
        loaded = true
    }

    /// Picks up strokes from other devices (and our own writes).
    func reloadStrokes() async {
        guard let library = app?.library else { return }
        let all = await library.strokes(on: target.itemId, layer: target.layer)
        strokes = Dictionary(grouping: all, by: \.page)
        revision += 1
    }

    // MARK: Drawing

    /// A finished stroke from a canvas. `id` comes from canvases that track their strokes (PencilKit).
    func add(points: [InkPoint], tool: InkTool, color: String, width: Double, id: String? = nil, on page: Int? = nil) {
        guard !points.isEmpty, let library = app?.library else { return }
        let page = page ?? self.page
        let id = id ?? UUID().uuidString.lowercased()
        undoStack.append(Action(kind: .add, page: page, strokes: [Saved(tool: tool, color: color, width: width, points: points)], ids: [id]))
        redoStack.removeAll()
        edited = true
        Task {
            await library.addStroke(id: id, on: target.itemId, layer: target.layer, page: page, tool: tool, color: color, width: width, points: points)
            await reloadStrokes()
            app?.inkChanged()
        }
    }

    /// Strokes the eraser touched (or PencilKit's eraser removed).
    func erase(_ ids: [String], on page: Int? = nil) {
        guard !ids.isEmpty, let library = app?.library else { return }
        let page = page ?? self.page
        let removed = (strokes[page] ?? []).filter { ids.contains($0.id) }
        undoStack.append(Action(kind: .erase, page: page, strokes: removed.map { Saved(tool: $0.tool, color: $0.color, width: $0.width, points: $0.points) }, ids: ids))
        redoStack.removeAll()
        edited = true
        strokes[page]?.removeAll { ids.contains($0.id) }
        revision += 1
        Task {
            await library.deleteStrokes(ids)
            await reloadStrokes()
            app?.inkChanged()
        }
    }

    /// The eraser at a point (page points), for canvases that hit-test themselves.
    func eraseAt(x: Double, y: Double, radius: Double) {
        let hit = currentStrokes.filter { InkRenderer.hits($0, x: x, y: y, radius: radius) }.map(\.id)
        if !hit.isEmpty { erase(hit) }
    }

    func undo() {
        guard let popped = undoStack.popLast(), let library = app?.library else { return }
        Task {
            var action = popped
            switch action.kind {
            case .add: await library.deleteStrokes(action.ids)
            case .erase:
                var ids: [String] = []
                for s in action.strokes {
                    if let id = await library.addStroke(on: target.itemId, layer: target.layer, page: action.page, tool: s.tool, color: s.color, width: s.width, points: s.points) { ids.append(id) }
                }
                action.ids = ids
            }
            redoStack.append(action)
            edited = true
            await reloadStrokes()
            app?.inkChanged()
        }
    }

    func redo() {
        guard let popped = redoStack.popLast(), let library = app?.library else { return }
        Task {
            var action = popped
            switch action.kind {
            case .add:
                var ids: [String] = []
                for s in action.strokes {
                    if let id = await library.addStroke(on: target.itemId, layer: target.layer, page: action.page, tool: s.tool, color: s.color, width: s.width, points: s.points) { ids.append(id) }
                }
                action.ids = ids
            case .erase: await library.deleteStrokes(action.ids)
            }
            undoStack.append(action)
            edited = true
            await reloadStrokes()
            app?.inkChanged()
        }
    }

    // MARK: Sketch pages

    func addPage() {
        guard isSketch, let first = pages.first, let library = app?.library else { return }
        pages.append(InkPageSpec(width: first.width, height: first.height, background: .paper(paper)))
        page = pages.count - 1
        let count = pages.count
        Task { await library.setSketch(target.itemId, pages: count); app?.inkChanged() }
    }

    func setPaper(_ p: InkPaper) {
        guard isSketch, let library = app?.library else { return }
        paper = p
        pages = pages.map { InkPageSpec(width: $0.width, height: $0.height, background: .paper(p)) }
        revision += 1
        Task { await library.setSketch(target.itemId, paper: p); app?.inkChanged() }
    }

    /// When the editor closes: a fresh card picture for a sketch.
    func finish() async {
        guard edited, isSketch, let first = pages.first, let library = app?.library else { return }
        let ink = strokes[0] ?? []
        if let jpeg = await Task.detached(priority: .utility, operation: { InkRenderer.thumbnailJPEG(first, strokes: ink) }).value {
            try? await library.setThumbnail(target.itemId, jpeg: jpeg)
        }
        app?.inkChanged()
    }
}
