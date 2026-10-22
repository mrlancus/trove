import CoreGraphics
import Foundation
import Observation
import SwiftUI
import TroveCore
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#else
import AppKit
#endif

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
    case pen, ballpoint, pencil, fountain, brush, marker, highlighter, eraser, lasso, shape, text, laser, tape
    var id: String { rawValue }

    var ink: InkTool? { InkTool(rawValue: rawValue) }
    var label: String {
        switch self {
        case .pen: "Pen"
        case .ballpoint: "Ballpoint"
        case .pencil: "Pencil"
        case .fountain: "Fountain pen"
        case .brush: "Brush pen"
        case .marker: "Marker"
        case .highlighter: "Highlighter"
        case .eraser: "Eraser"
        case .lasso: "Lasso"
        case .shape: "Shape"
        case .text: "Text"
        case .laser: "Laser pointer"
        case .tape: "Tape"
        }
    }
    var symbol: String {
        switch self {
        case .pen: "pencil.tip"
        case .ballpoint: "pencil.line"
        case .pencil: "pencil"
        case .fountain: "signature"
        case .brush: "paintbrush"
        case .marker: "paintbrush.pointed"
        case .highlighter: "highlighter"
        case .eraser: "eraser"
        case .lasso: "lasso"
        case .shape: "square.on.circle"
        case .text: "character.textbox"
        case .laser: "cursorarrow.rays"
        case .tape: "bandage"
        }
    }
    var defaultWidth: Double {
        switch self {
        case .pen: 2.5
        case .ballpoint: 2
        case .pencil: 2
        case .fountain: 4
        case .brush: 8
        case .marker: 7
        case .highlighter: 22
        case .eraser: 10
        case .lasso: 1
        case .shape: 3
        case .text: 20
        case .laser: 6
        case .tape: 24
        }
    }
    var defaultColor: String {
        switch self {
        case .laser: "#ff3b30"
        case .tape: "#f2c94c"
        case .marker: "#0a84ff"
        case .highlighter: "#ffd60a"
        case .fountain: "#1c3d8f"
        default: "#1c1c1e"
        }
    }
    /// Pens and text have a colour; pens, text and the eraser a size.
    var hasColor: Bool { ink != nil || self == .text || self == .laser || self == .tape || self == .shape }
    var hasSize: Bool { hasColor || self == .eraser }
}

/// What Apple Pencil Pro's haptics mark.
enum InkHaptic { case snapped, toolChanged }

enum InkEraserMode: String, CaseIterable, Identifiable {
    case stroke, partial, precise
    var id: String { rawValue }
    var label: String {
        switch self {
        case .stroke: "Strokes"
        case .partial: "Partial"
        case .precise: "Precise"
        }
    }
}

/// How a sketch's pages show (like the website's): down in a column, across in a row, or one at a
/// time with a page turn.
enum InkPageLayout: String, CaseIterable, Identifiable {
    case vertical, horizontal, flip
    var id: String { rawValue }
    var label: String {
        switch self {
        case .vertical: "Scroll down"
        case .horizontal: "Scroll sideways"
        case .flip: "Flip pages"
        }
    }
}

/// A zoom asked for from the zoom menu; the canvas carries it out once (by `id`).
struct InkZoomRequest: Equatable {
    enum Kind: Equatable { case scale(Double), wholePage, pageWidth }
    var id = UUID()
    var kind: Kind
}

/// What the lasso picked up on a page.
struct InkSelection: Equatable {
    var pageKey: String
    var strokes: Set<String>
    var elements: Set<String>
    var count: Int { strokes.count + elements.count }
}

/// A text box being typed in, on the page.
struct InkTextEdit: Identifiable {
    var id = UUID().uuidString
    var elementId: String?
    var pageKey: String
    var frame: InkGeometry.Rect
    var text: String
    var size: Double
    var color: String
    var style = InkTextStyle()
    /// A turned box is typed in turned (radians).
    var rotate = 0.0
}

/// What the shape tool draws: a clean shape filling the box dragged, a line, an arrow or a connector
/// (a line joined to the shapes at its ends that follows them; PROTOCOL.md §10).
enum InkShapeKind: String, CaseIterable, Identifiable {
    case line, arrow, connector, rectangle, ellipse, circle, triangle, diamond, star, heart, bubble
    var id: String { rawValue }
    var label: String {
        switch self {
        case .line: "Line"
        case .arrow: "Arrow"
        case .connector: "Connector"
        case .rectangle: "Rectangle"
        case .ellipse: "Ellipse"
        case .circle: "Circle"
        case .triangle: "Triangle"
        case .diamond: "Diamond"
        case .star: "Star"
        case .heart: "Heart"
        case .bubble: "Speech bubble"
        }
    }
    var symbol: String {
        switch self {
        case .line: "line.diagonal"
        case .arrow: "arrow.up.right"
        case .connector: "point.3.connected.trianglepath.dotted"
        case .rectangle: "rectangle"
        case .ellipse: "oval"
        case .circle: "circle"
        case .triangle: "triangle"
        case .diamond: "diamond"
        case .star: "star"
        case .heart: "heart"
        case .bubble: "bubble.left"
        }
    }
}

/// What the lasso picks: everything, or only ink, text boxes, or pictures (and tape).
enum InkLassoKinds: String, CaseIterable, Identifiable {
    case all, ink, text, pictures
    var id: String { rawValue }
    var label: String {
        switch self {
        case .all: "Everything"
        case .ink: "Ink"
        case .text: "Text"
        case .pictures: "Pictures"
        }
    }
    var picksInk: Bool { self == .all || self == .ink }
    func picks(_ kind: InkElement.Kind) -> Bool {
        switch self {
        case .all: true
        case .ink: false
        case .text: kind == .text
        case .pictures: kind != .text
        }
    }
}

/// The ruler or the protractor.
enum InkGuideKind { case ruler, protractor }

/// Where a pen put down on a guide draws: along a ruler edge (−1 top, 1 bottom) or the protractor's arc.
enum InkGuideSnap: Equatable { case ruler(Int), arc }

/// Ask AI on a lasso selection: a picture of it goes to the relay's cloud AI, or (with Apple
/// Intelligence) the handwriting read off it goes to the on-device model.
enum InkAIAction: String, CaseIterable, Identifiable {
    case summarise, explain, solve, flashcards
    var id: String { rawValue }
    var label: String {
        switch self {
        case .summarise: "Summarise"
        case .explain: "Explain"
        case .solve: "Solve the maths"
        case .flashcards: "Make flashcards"
        }
    }
    var symbol: String {
        switch self {
        case .summarise: "text.alignleft"
        case .explain: "lightbulb"
        case .solve: "function"
        case .flashcards: "rectangle.on.rectangle.angled"
        }
    }
    /// The task for the on-device model, which gets the handwriting as text.
    var instruction: String {
        switch self {
        case .summarise: "This is handwriting read off a page. Summarise it in a few sentences."
        case .explain: "This is handwriting read off a page. Explain it simply, as to a student."
        case .solve: "This is handwriting read off a page. Solve the maths in it, showing the steps."
        case .flashcards: "Make study flashcards."
        }
    }
}

/// What Ask AI answered, to show and save.
struct InkAIResult: Identifiable {
    var id = UUID()
    var action: InkAIAction
    var result: NoteAI.Result
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
    static let tapeColors = ["#f2c94c", "#9ad0f5", "#f5a3b8", "#a8dba8", "#c7b8f5", "#b0b0b5"]
    static let highlighterColors = ["#ffd60a", "#34c759", "#64d2ff", "#ff6fa8", "#ff9f0a", "#bf5af2"]
    /// The drawing settings every device follows (`settings.ink`): pen feel, favourites, your colours.
    private(set) var inkSettings = InkSettings()
    /// Tape strips opened on this device.
    private(set) var peeked: Set<String> = []
    /// Recently used colours (this device).
    private(set) var recentColors: [String] = UserDefaults.standard.stringArray(forKey: "ink.recentColors") ?? []
    /// Dashes or dots for a pen (this device).
    func dash(for t: InkEditorTool) -> String? { _ = styleRevision; return UserDefaults.standard.string(forKey: "ink.dash.\(t.rawValue)") }
    func setDash(_ dash: String?, for t: InkEditorTool) { UserDefaults.standard.set(dash, forKey: "ink.dash.\(t.rawValue)"); styleRevision += 1 }
    /// Arrowheads on straight lines: "end", "both" or nil.
    var arrow: String? {
        get { _ = styleRevision; return UserDefaults.standard.string(forKey: "ink.arrow") }
        set { UserDefaults.standard.set(newValue, forKey: "ink.arrow"); styleRevision += 1 }
    }
    /// The colour closed shapes are filled with, or nil.
    var fill: String? {
        get { _ = styleRevision; return UserDefaults.standard.string(forKey: "ink.fill") }
        set { UserDefaults.standard.set(newValue, forKey: "ink.fill"); styleRevision += 1 }
    }
    /// Haptics on Apple Pencil Pro (snapping a shape, switching tools); set by the iPad canvas.
    @ObservationIgnored var haptic: ((_ kind: InkHaptic) -> Void)?
    static var clipboard: InkClipboard?
    static let holdToSnap: TimeInterval = 0.55

    let target: InkTarget
    private(set) var pages: [InkPageSpec] = []
    private(set) var content: [String: InkContent] = [:]
    private(set) var pictures: [String: CGImage] = [:]
    var page = 0 {
        // A new page sends what's waiting as soon as the push batching allows (ROADMAP §3.7 item 2).
        didSet { if oldValue != page, loaded { app?.sketchPageChanged() } }
    }
    var tool: InkEditorTool {
        didSet {
            UserDefaults.standard.set(tool.rawValue, forKey: "ink.tool")
            if tool != .lasso { clearSelection() }
            if tool != .text { commitTextEdit() }
        }
    }
    /// What the shape tool draws.
    var shapeKind: InkShapeKind { didSet { UserDefaults.standard.set(shapeKind.rawValue, forKey: "ink.shapeKind") } }
    /// What the lasso picks.
    var lassoKinds: InkLassoKinds { didSet { UserDefaults.standard.set(lassoKinds.rawValue, forKey: "ink.lassoKinds") } }
    /// The font, bold and italic of the next text box.
    var textStyle: InkTextStyle {
        didSet {
            let d = UserDefaults.standard
            d.set(textStyle.font.rawValue, forKey: "ink.textFont")
            d.set(textStyle.bold, forKey: "ink.textBold")
            d.set(textStyle.italic, forKey: "ink.textItalic")
        }
    }
    /// The ruler and protractor (this device only, never synced), on page `guidesKey`.
    var ruler: InkEditing.Guide?
    var protractor: InkEditing.Guide?
    private(set) var guidesKey: String?
    /// Where the pen or pointer is, for the protractor's angle reading.
    private(set) var protractorReading: InkPoint?
    /// The iPad uses PencilKit's own ruler (it draws along it as you write), so Trove's isn't drawn there.
    @ObservationIgnored var nativeRuler = false
    /// A clean shape being reshaped by one of its handles (lifted off the page meanwhile).
    private(set) var shapeEdit: (key: String, line: InkLine)?
    /// A shape being dragged out with the shape tool.
    private(set) var shapeDraft: (key: String, line: InkLine)?
    /// The turn (degrees) while the selection's turning handle is dragged.
    private(set) var turning: Double?
    /// Ask AI's answer, shown in a sheet; `aiBusy` while it works.
    var aiResult: InkAIResult?
    private(set) var aiBusy = false
    /// The elements library (saved and built-in), loaded when it's opened.
    private(set) var stickers: [InkSticker] = []
    var eraserMode: InkEraserMode { didSet { UserDefaults.standard.set(eraserMode.rawValue, forKey: "ink.eraserMode") } }
    var highlighterOnly: Bool { didSet { UserDefaults.standard.set(highlighterOnly, forKey: "ink.highlighterOnly") } }
    var shapeMode: Bool { didSet { UserDefaults.standard.set(shapeMode, forKey: "ink.shapes") } }
    /// Scratching back and forth over strokes deletes them (off unless turned on).
    var scribbleToErase: Bool { didSet { UserDefaults.standard.set(scribbleToErase, forKey: "ink.scribble") } }
    var layout: InkPageLayout { didSet { UserDefaults.standard.set(layout.rawValue, forKey: "ink.layout") } }
    /// Zoom when a drawing opens: the whole page (true) or its width.
    var fitWholePage: Bool { didSet { UserDefaults.standard.set(!fitWholePage, forKey: "ink.fitWidth") } }
    /// The sketch shown dark on this device: black pages, black and white ink swapped (`InkDark`).
    /// Display only; light unless turned on, whatever the system's appearance.
    var darkPage: Bool { didSet { UserDefaults.standard.set(darkPage, forKey: "ink.darkPage") } }
    /// Screen points per page point, as the canvas shows it (1 = 100 %).
    var zoom = 1.0
    var zoomRequest: InkZoomRequest?
    /// Where Apple Pencil's squeeze opened the tool palette, in the canvas's on-screen coordinates.
    var palette: CGPoint?
    static let minZoom = 0.1, maxZoom = 10.0
    private(set) var previousTool: InkEditorTool = .pen
    private(set) var loaded = false
    private(set) var failed: String?
    private(set) var edited = false
    /// Bumped whenever the ink drawn changes, so canvases redraw it.
    private(set) var revision = 0
    /// Bumped when only what's drawn over the ink changes: the lasso's loop, the selection, the eraser's circle.
    private(set) var overlayRevision = 0
    /// The iPad/iPhone canvas redraws its overlay itself when told here, so a lasso or eraser move (or a
    /// hovering Pencil) no longer goes through SwiftUI, which re-evaluated the editor on every move
    /// (ROADMAP §3.7 item 11). Without one (the Mac), `overlayRevision` is bumped as before.
    @ObservationIgnored var overlayListener: (@MainActor () -> Void)?

    func overlayChanged() {
        if let overlayListener { overlayListener() } else { overlayRevision += 1 }
    }
    /// Bumped when the pages change (added, moved, new paper).
    private(set) var pagesRevision = 0
    /// Bumped when a tool's colour or size changes (they're kept in UserDefaults, which isn't observed).
    private(set) var styleRevision = 0

    var selection: InkSelection? {
        didSet {
            overlayChanged()
            // A selection dropped mid-drag puts what was lifted back on the page.
            if dragTransform != nil { revision += 1 }
        }
    }
    /// The lasso's move or resize while it's being dragged. The selection is lifted off its page
    /// meanwhile (`display(_:lifted:)` leaves it out, `dragPreview(_:)` has it), so each move redraws
    /// only what's moving: `revision` changes when the drag starts and ends, `overlayRevision` as it moves.
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
        case laser(key: String)
        case drag(key: String, start: InkPoint, corner: Int?, box: InkGeometry.Rect)
        case tape(key: String, start: InkPoint, end: InkPoint)
        case turn(key: String, centre: InkPoint, start: InkPoint)
        case handle(key: String, id: String, index: Int)
        case shape(key: String, start: InkPoint, end: InkPoint, from: String)
        case guide(kind: InkGuideKind, turn: Int, start: InkPoint, origin: InkEditing.Guide, grab: Double)
    }
    private var gesture: Gesture?
    /// Strokes drawn here that the library hasn't stored yet, and ones erased here it hasn't
    /// deleted yet. A reload that lands in between keeps them as drawn, so nothing flickers away.
    @ObservationIgnored private var unsavedStrokes: [String: (key: String, line: InkLine)] = [:]
    @ObservationIgnored private var unsavedDeletes: Set<String> = []
    @ObservationIgnored private weak var app: AppModel?
    private var pagesSig = ""
    /// The item's ink as last loaded (count and newest change), so a reload with nothing new is skipped.
    @ObservationIgnored private var inkSig = ""
    /// Decoded strokes by id and version: a reload decodes only what changed.
    @ObservationIgnored private var lineCache: [String: (hlc: String, line: InkLine)] = [:]
    /// The lasso's writes, one after another: a second drag starting before the first is stored
    /// would otherwise read (for undo) and reload positions half-way between the two.
    @ObservationIgnored private var lassoWrites: Task<Void, Never>?

    init(target: InkTarget, app: AppModel) {
        self.target = target
        self.app = app
        page = target.startPage
        let d = UserDefaults.standard
        tool = InkEditorTool(rawValue: d.string(forKey: "ink.tool") ?? "") ?? .pen
        eraserMode = InkEraserMode(rawValue: d.string(forKey: "ink.eraserMode") ?? "") ?? .stroke
        highlighterOnly = d.bool(forKey: "ink.highlighterOnly")
        shapeMode = d.bool(forKey: "ink.shapes")
        scribbleToErase = d.bool(forKey: "ink.scribble")
        layout = InkPageLayout(rawValue: d.string(forKey: "ink.layout") ?? "") ?? .vertical
        fitWholePage = !d.bool(forKey: "ink.fitWidth")
        darkPage = d.bool(forKey: "ink.darkPage")
        shapeKind = InkShapeKind(rawValue: d.string(forKey: "ink.shapeKind") ?? "") ?? .rectangle
        lassoKinds = InkLassoKinds(rawValue: d.string(forKey: "ink.lassoKinds") ?? "") ?? .all
        textStyle = InkTextStyle(font: InkTextStyle.Font(rawValue: d.string(forKey: "ink.textFont") ?? "") ?? .sans,
                                 bold: d.bool(forKey: "ink.textBold"), italic: d.bool(forKey: "ink.textItalic"))
    }

    func requestZoom(_ kind: InkZoomRequest.Kind) { zoomRequest = InkZoomRequest(kind: kind) }

    var isSketch: Bool { target.layer.isEmpty }
    var isInfinite: Bool { pages.first?.infinite ?? false }
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var currentPage: InkPageSpec? { pages.indices.contains(page) ? pages[page] : nil }
    var currentKey: String { currentPage?.key ?? "0" }

    // MARK: Colour and size per tool

    func color(for t: InkEditorTool) -> String {
        _ = styleRevision
        return UserDefaults.standard.string(forKey: "ink.color.\(t.rawValue)") ?? t.defaultColor
    }
    func width(for t: InkEditorTool) -> Double {
        _ = styleRevision
        let w = UserDefaults.standard.double(forKey: "ink.width.\(widthKey(t))")
        return w > 0 ? w : (widthKey(t) == "eraserPrecise" ? 3 : t.defaultWidth)
    }
    /// The precise eraser keeps its own, small size.
    func widthKey(_ t: InkEditorTool) -> String { t == .eraser && eraserMode == .precise ? "eraserPrecise" : t.rawValue }
    var color: String {
        get { color(for: tool.hasColor ? tool : .pen) }
        set {
            if let selection, tool == .lasso, selection.count > 0 { recolourSelection(newValue); return }
            if !tool.hasColor { tool = .pen }
            if tool == .text { textEdit?.color = newValue }
            UserDefaults.standard.set(newValue, forKey: "ink.color.\(tool.rawValue)")
            recentColors = Array(([newValue] + recentColors.filter { $0 != newValue }).prefix(8))
            UserDefaults.standard.set(recentColors, forKey: "ink.recentColors")
            styleRevision += 1
        }
    }
    var width: Double {
        get { width(for: tool) }
        set {
            UserDefaults.standard.set(newValue, forKey: "ink.width.\(widthKey(tool))")
            if tool == .text { textEdit?.size = newValue }
            styleRevision += 1
        }
    }

    func select(_ t: InkEditorTool) {
        if t != tool { previousTool = tool; haptic?(.toolChanged) }
        tool = t
    }

    // MARK: Favourites, your colours, pen feel (settings.ink, on every device)

    func reloadSettings() async {
        guard let library = app?.library else { return }
        let next = await library.inkSettings()
        if next != inkSettings { inkSettings = next }
    }

    /// One tap: the favourite's tool, colour and size.
    func use(_ f: InkFavourite) {
        guard let t = InkEditorTool(rawValue: f.tool.rawValue) else { return }
        UserDefaults.standard.set(f.color, forKey: "ink.color.\(t.rawValue)")
        UserDefaults.standard.set(f.width, forKey: "ink.width.\(t.rawValue)")
        styleRevision += 1
        select(t)
    }

    func isCurrent(_ f: InkFavourite) -> Bool { tool.rawValue == f.tool.rawValue && color(for: tool) == f.color && width(for: tool) == f.width }

    /// Keeps the pen, colour and size as a favourite (up to 10).
    func saveFavourite() {
        guard let ink = tool.ink, let library = app?.library else { return }
        let f = InkFavourite(tool: ink, color: color(for: tool), width: width(for: tool))
        let list = Array((inkSettings.favourites.filter { $0 != f } + [f]).suffix(InkSettings.maxFavourites))
        inkSettings.favourites = list
        Task { await library.setInkFavourites(list); app?.inkChanged() }
    }

    func removeFavourite(_ f: InkFavourite) {
        guard let library = app?.library else { return }
        let list = inkSettings.favourites.filter { $0 != f }
        inkSettings.favourites = list
        Task { await library.setInkFavourites(list); app?.inkChanged() }
    }

    // MARK: Preset colours and sizes (settings.ink, on every device), like GoodNotes

    /// The highlighter and tape have their own preset colours; every other tool shares one row.
    static func colorGroup(_ t: InkEditorTool) -> String { t == .highlighter ? "highlighter" : t == .tape ? "tape" : "ink" }

    /// A tool's preset colours: yours, else the built-in ones (with the colours you kept before presets).
    func presetColors(for t: InkEditorTool) -> [String] {
        let group = Self.colorGroup(t)
        if let mine = inkSettings.colors[group] { return mine }
        switch group {
        case "tape": return Self.tapeColors
        case "highlighter": return Self.highlighterColors
        default:
            var out = Self.colors
            for c in inkSettings.palette where !out.contains(c) { out.append(c) }
            return out
        }
    }

    func setPresetColors(_ list: [String], for t: InkEditorTool) {
        guard let library = app?.library else { return }
        let group = Self.colorGroup(t)
        var clean: [String] = []
        for c in list.map({ $0.lowercased() }) where InkSettings.isHex(c) && !clean.contains(c) { clean.append(c) }
        let kept = Array(clean.prefix(InkSettings.maxPalette))
        inkSettings.colors[group] = kept
        Task { await library.setInkColors(group, kept); app?.inkChanged() }
    }

    /// The + button: a new preset colour at the end of the chosen tool's row, and it's picked.
    func addPresetColor(_ c: String) {
        let t = tool.hasColor ? tool : .pen
        var list = presetColors(for: t).filter { $0 != c.lowercased() }
        list.append(c.lowercased())
        setPresetColors(list, for: t)
        color = c.lowercased()
    }

    /// A preset colour edited in place (and picked).
    func replacePresetColor(at i: Int, with c: String) {
        let t = tool.hasColor ? tool : .pen
        var list = presetColors(for: t)
        guard list.indices.contains(i) else { return }
        list[i] = c.lowercased()
        setPresetColors(list, for: t)
        color = c.lowercased()
    }

    func removePresetColor(at i: Int) {
        let t = tool.hasColor ? tool : .pen
        var list = presetColors(for: t)
        guard list.indices.contains(i), list.count > 1 else { return }
        list.remove(at: i)
        setPresetColors(list, for: t)
    }

    /// The built-in three sizes (thin, medium, thick) for a tool.
    static func defaultSizes(_ t: InkEditorTool, precise: Bool) -> [Double] {
        if t == .eraser && precise { return [1, 3, 6] }
        let d = t.defaultWidth
        return [d * 0.5, d, d * 2].map { ($0 * 2).rounded() / 2 }
    }

    /// The chosen tool's three preset sizes: yours, else the built-in ones.
    var presetSizes: [Double] {
        inkSettings.sizes[widthKey(tool)] ?? Self.defaultSizes(tool, precise: eraserMode == .precise)
    }

    /// A preset size set for good (and picked).
    func setPresetSize(_ i: Int, to w: Double) {
        guard let library = app?.library else { return }
        var list = presetSizes
        guard list.indices.contains(i), w > 0, w <= 200 else { return }
        list[i] = w
        let key = widthKey(tool)
        inkSettings.sizes[key] = list
        width = w
        Task { await library.setInkSizes(key, list); app?.inkChanged() }
    }

    func penSettings(_ t: InkTool) -> PenSettings { inkSettings.pen(t) }

    func setPenSettings(_ settings: PenSettings, for t: InkTool) {
        guard let library = app?.library else { return }
        inkSettings.pens[t] = settings
        Task { await library.setPenSettings(t, settings); app?.inkChanged() }
    }

    func setCompactPoints(_ on: Bool) {
        guard let library = app?.library else { return }
        inkSettings.compactPoints = on
        Task { await library.setCompactPoints(on); app?.inkChanged() }
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
            let mime = att.mime, name = att.name
            if name.lowercased().hasSuffix(".goodnotes") {
                // The first time: the notebook's ink and text become Trove's, so every tool works on them.
                guard let notebook = await Task.detached(priority: .userInitiated, operation: { try? GoodNotesInk.read(data) }).value,
                      !notebook.pages.isEmpty else { failed = "Couldn't read this notebook."; return }
                if !item.goodnotesInk.contains(att.id) {
                    let editable = await Task.detached(priority: .userInitiated) { notebook.pages.map(GoodNotesInk.editableInk) }.value
                    await library.importGoodNotesInk(item.id, attachment: att.id, pages: editable)
                    app.inkChanged(now: true)
                }
                pages = InkRenderer.pages(goodnotes: notebook)
            } else {
                pages = await Task.detached(priority: .userInitiated) { InkRenderer.pages(for: data, mime: mime, name: name) }.value
            }
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
        await reloadSettings()
        let sig = await library.inkSignature(target.itemId)
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
        // Nothing new since the last load (our own writes are already shown as made).
        if sig == inkSig, loaded { return }
        inkSig = sig
        let signpost = Perf.begin("Reload ink")
        defer { Perf.end("Reload ink", signpost) }
        app?.power.count { $0.inkReloads += 1 }
        let strokes = await library.strokes(on: target.itemId, layer: target.layer)
        let elements = await library.elements(on: target.itemId, layer: target.layer)
        var next: [String: InkContent] = [:]
        let stored = Set(strokes.map(\.id))
        for id in unsavedStrokes.keys where stored.contains(id) { unsavedStrokes[id] = nil }
        var cache: [String: (hlc: String, line: InkLine)] = [:]
        for s in strokes where !unsavedDeletes.contains(s.id) {
            let hlc = s.record.updatedHLC
            let line = lineCache[s.id].flatMap { $0.hlc == hlc ? $0.line : nil } ?? InkLine(s)
            cache[s.id] = (hlc, line)
            next[s.pageKey, default: InkContent()].strokes.append(line)
        }
        lineCache = cache
        for (_, s) in unsavedStrokes.sorted(by: { $0.key < $1.key }) where !unsavedDeletes.contains(s.line.id) {
            next[s.key, default: InkContent()].strokes.append(s.line)
        }
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
    /// `lifted`: without what the lasso is dragging (a canvas draws that from `dragPreview(_:)` over the
    /// rest, so a drag doesn't redraw, or on iPad rebuild, the whole page on every move).
    func display(_ key: String, lifted: Bool = false) -> InkContent {
        var c = content[key] ?? InkContent()
        c.pictures = pictures
        c.peeked = peeked
        if !erasePreview.isEmpty {
            c.strokes = c.strokes.flatMap { line -> [InkLine] in
                guard let pieces = erasePreview[line.id] else { return [line] }
                return pieces.enumerated().map { i, pts in
                    InkLine(id: "\(line.id)#\(i)", tool: line.tool, color: line.color, width: line.width, points: pts, style: InkStrokeStyle(dash: line.style.dash, nib: line.style.nib))
                }
            }
        }
        // The box being typed in shows in its text field instead.
        if let edit = textEdit, let id = edit.elementId, edit.pageKey == key { c.elements.removeAll { $0.id == id } }
        if let edit = shapeEdit, edit.key == key {
            if lifted { c.strokes.removeAll { $0.id == edit.line.id } } else { c.strokes = c.strokes.map { $0.id == edit.line.id ? edit.line : $0 } }
        }
        if let t = dragTransform, let sel = selection, sel.pageKey == key {
            if lifted {
                c.strokes.removeAll { sel.strokes.contains($0.id) }
                c.elements.removeAll { sel.elements.contains($0.id) }
            } else {
                c.strokes = c.strokes.map { sel.strokes.contains($0.id) ? $0.transformed(t) : $0 }
                c.elements = c.elements.map { sel.elements.contains($0.id) ? $0.transformed(t) : $0 }
            }
        }
        return c
    }

    /// What the lasso is dragging on a page, where it is now (nil when nothing is being dragged there).
    func dragPreview(_ key: String) -> InkContent? {
        guard let t = dragTransform, let sel = selection, sel.pageKey == key, let c = content[key] else { return nil }
        var out = InkContent()
        out.strokes = c.strokes.filter { sel.strokes.contains($0.id) }.map { $0.transformed(t) }
        out.elements = c.elements.filter { sel.elements.contains($0.id) }.map { $0.transformed(t) }
        out.pictures = pictures
        out.peeked = peeked
        return out
    }

    /// Whether a page has text boxes or tape (drawn over the ink, so the overlay has something to show).
    func hasBoxesOver(_ key: String) -> Bool {
        (content[key]?.elements ?? []).contains { $0.kind == .text || $0.kind == .tape }
    }

    /// The lasso, selection and eraser over a page.
    func overlay(_ key: String) -> InkOverlay {
        var o = InkOverlay(eraser: eraserAt, eraserRadius: eraserRadius)
        let now = Date()
        o.lasers = lasers.filter { $0.key == key }.map { l in
            (points: l.points, color: l.color, width: l.width, alpha: l.ended.map { max(0, 1 - now.timeIntervalSince($0) / Self.laserFade) } ?? 1)
        }
        if case .lasso(let k)? = gesture, k == key { o.lasso = lassoPath }
        if selection?.pageKey == key {
            o.selection = selectionBox()
            o.rotateHandle = shapeEdit == nil
            o.turning = turning
            if dragTransform == nil, shapeEdit == nil, let line = singleShape() {
                o.handles = InkEditing.shapeHandles(shape: line.shape, points: line.points)
                o.roundMiddle = line.shape == "line" || line.shape == "curve"
            }
        }
        if let d = shapeDraft, d.key == key { o.preview = d.line }
        if let e = shapeEdit, e.key == key { o.preview = e.line }
        if guidesKey == key {
            if !nativeRuler { o.ruler = ruler }
            o.protractor = protractor
            o.reading = protractorReading
        }
        if let t = tapePreview, t.key == key { o.tape = (frame: t.frame, rotate: t.rotate, color: color(for: .tape)) }
        if let h = hoverTip, h.key == key, tool.ink != nil { o.tip = (point: h.point, color: color(for: tool), width: width(for: tool)) }
        return o
    }

    /// Where a hovering Apple Pencil is (page, point), to preview the pen's tip and colour there.
    private(set) var hoverTip: (key: String, point: InkPoint)?

    /// A hovering Pencil moved (nil: it went away). Pens show their tip; the eraser its circle.
    func pencilHover(_ p: InkPoint?, pageKey key: String?, scale: Double) {
        if tool == .eraser { hover(p, scale: scale); return }
        if let p, let key { hoverTip = (key, p) } else if hoverTip == nil { return } else { hoverTip = nil }
        overlayChanged()
    }

    // MARK: Pens

    /// A finished pen stroke from a canvas. Shape mode, or holding still at the end (`held`), turns
    /// it into a clean shape; the result says so, so a canvas showing the rough line can redraw.
    /// Returns true when what's kept differs from the line drawn (a clean shape, or a scratch-out
    /// that deleted what it crossed and isn't kept), so a canvas showing the rough line redraws.
    @discardableResult
    func addStroke(points: [InkPoint], tool: InkTool, color: String, width: Double, id: String? = nil, pageKey: String? = nil, held: Bool = false,
                   nib: Double? = nil) -> Bool {
        guard !points.isEmpty, let library = app?.library else { return false }
        let key = pageKey ?? currentKey
        if scribbleToErase, tool != .highlighter, !held,
           let gone = InkScribble.targets(points, strokes: (content[key]?.strokes ?? []).map { ($0.id, $0.points) }) {
            if let id { unsavedStrokes[id] = nil }
            content[key]?.strokes.removeAll { gone.contains($0.id) }
            unsavedDeletes.formUnion(gone)
            revision += 1
            record(Action(remove: gone.map { Ref(id: $0, kind: "stroke") }))
            Task {
                await library.deleteStrokes(gone)
                unsavedDeletes.subtract(gone)
                app?.inkChanged()
            }
            return true
        }
        // A tap on tape opens or covers it instead of leaving a dot.
        if let first = points.first, let b = InkGeometry.bounds(points), max(b.width, b.height) * zoom < 4, let strip = tape(at: first, key: key) {
            togglePeek(strip.id)
            return true
        }
        // Put down on the ruler's edge or the protractor's arc: the line runs along it.
        var guided: [InkPoint]?
        if let first = points.first, let snap = guideSnap(first, pageKey: key, scale: zoom) {
            guided = points.map { along(snap, $0) }
        }
        var snapped = guided == nil && (shapeMode || held) ? InkShapes.recognize(points) : nil
        // A highlighter only ever straightens; held still, it does from its start to its end.
        if tool == .highlighter, snapped != nil, snapped?.shape != .line {
            snapped = held ? Self.straightLine(points) : nil
        }
        if snapped != nil { haptic?(.snapped) }
        let pts = snapped?.points ?? guided ?? points
        let shape = snapped?.shape.rawValue
        let editorTool = InkEditorTool(rawValue: tool.rawValue) ?? .pen
        var style = InkStrokeStyle(dash: dash(for: editorTool), nib: nib)
        if let shape, tool != .highlighter, shape == "line" || shape == "polyline" || shape == "curve" { style.arrow = arrow }
        if let shape, InkStrokeStyle.closedShapes.contains(shape) { style.fill = fill }
        let id = id ?? UUID().uuidString.lowercased()
        let line = InkLine(id: id, tool: tool, color: color, width: width, points: pts, shape: shape, style: style)
        content[key, default: InkContent()].strokes.append(line)
        unsavedStrokes[id] = (key, line)
        revision += 1
        record(Action(add: [Ref(id: id, kind: "stroke")]))
        let itemId = target.itemId, layer = target.layer
        Task {
            await library.addStroke(id: id, on: itemId, layer: layer, pageKey: key, tool: tool, color: color, width: width, points: pts, shape: shape,
                                    style: style.isEmpty ? nil : style)
            // What's stored is what's shown: no reload (it would decode every stroke again).
            unsavedStrokes[id] = nil
            app?.inkChanged()
        }
        return snapped != nil || guided != nil
    }

    /// A straight line from the first point to the last.
    static func straightLine(_ pts: [InkPoint]) -> InkShapes.Result? {
        guard let a = pts.first, let b = pts.last, hypot(b.x - a.x, b.y - a.y) >= 4 else { return nil }
        let p = pts.map(\.pressure).reduce(0, +) / Double(pts.count)
        return InkShapes.Result(shape: .line, points: [InkPoint(x: a.x, y: a.y, pressure: p), InkPoint(x: b.x, y: b.y, pressure: p, t: b.t)])
    }

    // MARK: Tape

    func tape(at p: InkPoint, key: String) -> InkBox? {
        (content[key]?.elements ?? []).last { $0.kind == .tape && $0.contains(p) }
    }

    /// A strip of tape laid from `a` to `b`, like GoodNotes: as wide as the tape's size, along the
    /// pen's line and turned with it (snapping level or upright within 3°).
    static func tapeStrip(from a: InkPoint, to b: InkPoint, thick: Double) -> (frame: InkGeometry.Rect, rotate: Double) {
        let dx = b.x - a.x, dy = b.y - a.y
        var turn = atan2(dy, dx)
        // Kept between −90° and 90°, so the strip's pattern never ends up upside down.
        if turn > .pi / 2 { turn -= .pi } else if turn < -.pi / 2 { turn += .pi }
        let snap = 3 * Double.pi / 180
        for level in [-Double.pi / 2, 0, Double.pi / 2] where abs(turn - level) < snap { turn = level }
        let length = max(thick, hypot(dx, dy))
        let mid = InkPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        let frame = InkGeometry.Rect(x: mid.x - length / 2, y: mid.y - thick / 2, width: length, height: thick)
        return (frame, turn)
    }

    func togglePeek(_ id: String) {
        if peeked.contains(id) { peeked.remove(id) } else { peeked.insert(id) }
        revision += 1
        overlayChanged()
    }

    private func layTape(_ key: String, from a: InkPoint, to b: InkPoint) {
        guard let library = app?.library else { return }
        let strip = Self.tapeStrip(from: a, to: b, thick: width(for: .tape))
        let itemId = target.itemId, layer = target.layer, color = color(for: .tape)
        Task {
            let id = await library.addElement(on: itemId, layer: layer, pageKey: key, kind: .tape, frame: strip.frame, color: color, rotate: strip.rotate)
            record(Action(add: [Ref(id: id, kind: "element")]))
            await reloadInk()
            app?.inkChanged()
        }
    }

    /// The tape being laid, to show while dragging.
    var tapePreview: (key: String, frame: InkGeometry.Rect, rotate: Double)? {
        guard case .tape(let key, let a, let b)? = gesture else { return nil }
        let strip = Self.tapeStrip(from: a, to: b, thick: width(for: .tape))
        return (key, strip.frame, strip.rotate)
    }

    // MARK: The page grid

    /// Each page's grid of stroke boxes, rebuilt when the ink changes, so the eraser and lasso test only nearby strokes.
    @ObservationIgnored private var grids: [String: (revision: Int, grid: InkGrid)] = [:]

    func strokes(near r: InkGeometry.Rect?, key: String) -> [InkLine] {
        let lines = content[key]?.strokes ?? []
        guard let r else { return [] }
        let grid: InkGrid
        if let hit = grids[key], hit.revision == revision { grid = hit.grid } else {
            var g = InkGrid()
            for l in lines { g.add(l.id, l.bounds) }
            grids[key] = (revision, g)
            grid = g
        }
        let ids = Set(grid.query(r))
        return lines.filter { ids.contains($0.id) }
    }

    /// Strokes PencilKit's own eraser removed (not used while Trove's eraser is on, but kept in step).
    func removeStrokes(_ ids: [String], pageKey: String? = nil) {
        guard !ids.isEmpty, let library = app?.library else { return }
        let key = pageKey ?? currentKey
        content[key]?.strokes.removeAll { ids.contains($0.id) }
        unsavedDeletes.formUnion(ids)
        revision += 1
        record(Action(remove: ids.map { Ref(id: $0, kind: "stroke") }))
        Task {
            await library.deleteStrokes(ids)
            unsavedDeletes.subtract(ids)
            await reloadInk()
            app?.inkChanged()
        }
    }

    // MARK: The eraser, lasso and text (pointer events in page points)

    /// `scale` is screen points per page point, so handles and the eraser keep their size on screen.
    func pointerDown(_ p: InkPoint, pageKey key: String, scale: Double) {
        let s = max(0.05, scale)
        // The ruler and protractor: their bodies move them, their knobs turn them.
        if beginGuideDrag(p, pageKey: key, scale: s, pen: false) { return }
        switch tool {
        case .text:
            if let edit = textEdit {
                // A tap inside the box being typed in is the text field's.
                if edit.pageKey == key, isInside(edit, p) { return }
                commitTextEdit()
            }
            if let box = textBox(at: p, key: key) { beginText(box, key: key) } else { newText(at: p, key: key) }
        case .shape:
            let from = shapeKind == .connector ? (connectableAt(p, key: key) ?? "") : ""
            gesture = .shape(key: key, start: p, end: p, from: from)
        case .lasso:
            if let sel = selection, sel.pageKey == key, let box = selectionBox() {
                if let index = shapeHandleIndex(at: p, scale: s), let line = singleShape() {
                    gesture = .handle(key: key, id: line.id, index: index)
                    shapeEdit = (key, line)
                    revision += 1
                    return
                }
                let knob = InkRenderer.rotateHandle(box, scale: s)
                if hypot(knob.x - p.x, knob.y - p.y) <= 16 / s {
                    gesture = .turn(key: key, centre: InkPoint(x: box.x + box.width / 2, y: box.y + box.height / 2), start: p)
                    return
                }
                let r = 20 / s
                let corner = corners(box).firstIndex { hypot($0.x - p.x, $0.y - p.y) <= r }
                if corner != nil || (p.x >= box.x && p.x <= box.maxX && p.y >= box.y && p.y <= box.maxY) {
                    gesture = .drag(key: key, start: p, corner: corner, box: box)
                    return
                }
            }
            selection = nil
            lassoPath = [p]
            lassoTap = p
            gesture = .lasso(key: key)
            overlayChanged()
        case .tape:
            gesture = .tape(key: key, start: p, end: p)
            overlayChanged()
        case .laser:
            lasers.append(LaserLine(key: key, points: [p], color: color(for: .laser), width: width(for: .laser), ended: nil))
            gesture = .laser(key: key)
            overlayChanged()
        case .eraser:
            eraserRadius = eraserSize / s
            eraserAt = p
            if eraserMode != .stroke { gesture = .partial(key: key, last: p) } else { gesture = .erase(key: key, last: p, removed: []) }
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
            overlayChanged()
        case .tape(let key, let start, _):
            gesture = .tape(key: key, start: start, end: p)
            overlayChanged()
        case .laser:
            if !lasers.isEmpty { lasers[lasers.count - 1].points.append(p) }
            overlayChanged()
        case .drag(_, let start, let corner, let box):
            let t: InkGeometry.Transform
            if let corner, (0..<4).contains(corner) {
                // Resize from the opposite corner, keeping the proportions (from 5 % to 50×).
                let c = corners(box), o = c[(corner + 2) % 4], h = c[corner]
                let sx = (p.x - o.x) / (abs(h.x - o.x) < 1e-6 ? 1 : h.x - o.x), sy = (p.y - o.y) / (abs(h.y - o.y) < 1e-6 ? 1 : h.y - o.y)
                let k = (sx + sy) / 2
                t = InkGeometry.Transform(sx: k.isFinite ? min(50, max(0.05, k)) : 1, sy: k.isFinite ? min(50, max(0.05, k)) : 1, ox: o.x, oy: o.y)
            } else {
                t = .move(p.x - start.x, p.y - start.y)
            }
            // A point that isn't a real number (a glitch) leaves the selection where it was.
            guard t.isUsable else { return }
            // Lifting the selection off the page redraws the page once; after that only the overlay moves.
            if dragTransform == nil { revision += 1 }
            dragTransform = t
            overlayChanged()
        case .turn(_, let c, let start):
            let a = atan2(p.y - c.y, p.x - c.x) - atan2(start.y - c.y, start.x - c.x)
            let r = InkEditing.snapRotation(a)
            let t = InkEditing.rotate(r, about: c)
            guard t.isUsable else { return }
            if dragTransform == nil { revision += 1 }
            dragTransform = t
            turning = r * 180 / Double.pi
            overlayChanged()
        case .handle(let key, let id, let index):
            guard let line = content[key]?.strokes.first(where: { $0.id == id }) else { return }
            let moved = InkEditing.moveShapeHandle(shape: line.shape, points: line.points, index: index, to: p)
            var reshaped = line
            reshaped.shape = moved.shape
            reshaped.points = moved.points
            shapeEdit = (key, reshaped)
            overlayChanged()
        case .shape(let key, let start, _, let from):
            gesture = .shape(key: key, start: start, end: p, from: from)
            if let line = shapeLine(key: key, from: start, to: p, fromId: from) { shapeDraft = (key, line) } else { shapeDraft = nil }
            overlayChanged()
        case .guide(let kind, let turn, let start, let origin, let grab):
            moveGuide(kind, turn: turn, start: start, origin: origin, grab: grab, to: p)
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
            overlayChanged()
        case .partial:
            eraserAt = nil
            commitPartialErase()
        case .lasso(let key):
            if !finishLasso(key) { tapSelect(lassoTap, key: key) }
        case .laser:
            endLaser()
        case .drag:
            commitDrag()
        case .tape(let key, let start, let end):
            overlayChanged()
            // A tap opens or covers the strip under it; a drag lays a new one.
            if hypot(end.x - start.x, end.y - start.y) * zoom < 4 {
                if let strip = tape(at: start, key: key) { togglePeek(strip.id) }
            } else {
                layTape(key, from: start, to: end)
            }
        case .turn:
            commitDrag()
        case .handle:
            commitHandle()
        case .shape(let key, let start, let end, let from):
            finishShape(key: key, from: start, to: end, fromId: from)
        case .guide:
            overlayChanged()
        case nil:
            break
        }
    }

    // MARK: Laser pointer

    struct LaserLine {
        var key: String
        var points: [InkPoint]
        var color: String
        var width: Double
        var ended: Date?
    }
    static let laserFade: TimeInterval = 1.1
    private(set) var lasers: [LaserLine] = []

    /// The line fades out over a second; it's never saved.
    private func endLaser() {
        if !lasers.isEmpty, lasers[lasers.count - 1].ended == nil { lasers[lasers.count - 1].ended = Date() }
        Task { @MainActor [weak self] in
            while let self, !self.lasers.isEmpty {
                try? await Task.sleep(for: .milliseconds(33))
                let now = Date()
                self.lasers.removeAll { $0.ended.map { now.timeIntervalSince($0) > Self.laserFade } ?? false }
                self.overlayChanged()
                if self.lasers.allSatisfy({ $0.ended == nil }) { break }
            }
        }
    }

    func pointerCancelled() {
        switch gesture {
        case .partial: erasePreview = [:]
        case .drag, .turn: dragTransform = nil; turning = nil
        case .lasso: lassoPath = []
        case .laser: endLaser()
        case .handle: shapeEdit = nil
        case .shape: shapeDraft = nil
        default: break
        }
        if case .erase(_, _, let removed) = gesture, !removed.isEmpty { record(Action(remove: removed.map { Ref(id: $0, kind: "stroke") })) }
        gesture = nil
        eraserAt = nil
        revision += 1
        overlayChanged()
    }

    /// The eraser's circle under a hovering pen or mouse.
    func hover(_ p: InkPoint?, scale: Double) {
        guard tool == .eraser, gesture == nil else { if eraserAt != nil && gesture == nil { eraserAt = nil; overlayChanged() }; return }
        eraserRadius = eraserSize / max(0.05, scale)
        eraserAt = p
        overlayChanged()
    }

    /// The eraser's radius in screen points: the precise one exactly its size, the others a little bigger to be easy to hit.
    private var eraserSize: Double { eraserMode == .precise ? max(0.25, width(for: .eraser) / 2) : width(for: .eraser) / 2 + 4 }

    private func eraseTo(_ p: InkPoint) {
        eraserAt = p
        var inkTouched = false
        let only: Set<InkTool>? = highlighterOnly ? [.highlighter] : nil
        switch gesture {
        case .erase(let key, let last, var removed):
            let path = [last, p]
            let near = strokes(near: InkGeometry.bounds(path, pad: eraserRadius), key: key)
            let gone = near.filter { line in
                (only == nil || only!.contains(line.tool)) && InkGeometry.erase(line.points, along: path, radius: eraserRadius + line.width / 2) != nil
            }.map(\.id)
            if !gone.isEmpty, let library = app?.library {
                content[key]?.strokes.removeAll { gone.contains($0.id) }
                inkTouched = true
                removed.formUnion(gone)
                unsavedDeletes.formUnion(gone)
                Task {
                    await library.deleteStrokes(gone)
                    unsavedDeletes.subtract(gone)
                    app?.inkChanged()
                }
            }
            gesture = .erase(key: key, last: p, removed: removed)
        case .partial(let key, let last):
            let path = [last, p]
            for line in strokes(near: InkGeometry.bounds(path, pad: eraserRadius), key: key) where only == nil || only!.contains(line.tool) {
                let current = erasePreview[line.id] ?? [line.points]
                var changed = false
                let next = current.flatMap { piece -> [[InkPoint]] in
                    guard let cut = InkGeometry.erase(piece, along: path, radius: eraserRadius + line.width / 2) else { return [piece] }
                    changed = true
                    return cut
                }
                if changed { erasePreview[line.id] = next; inkTouched = true }
            }
            gesture = .partial(key: key, last: p)
        default:
            break
        }
        if inkTouched { edited = true; revision += 1 }
        overlayChanged()
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

    /// Picks what the loop goes round. False when it was a tap, not a loop (too short to go round anything).
    @discardableResult
    private func finishLasso(_ key: String) -> Bool {
        let loop = lassoPath
        lassoPath = []
        let extent = InkGeometry.bounds(loop).map { max($0.width, $0.height) * max(0.05, zoom) } ?? 0
        guard loop.count >= 3, extent >= 8 else { overlayChanged(); return false }
        let c = content[key] ?? InkContent()
        let kinds = lassoKinds
        let near: [InkLine] = kinds.picksInk ? self.strokes(near: InkGeometry.bounds(loop), key: key) : []
        let strokes = near.filter { InkGeometry.lassoSelects($0.points, lasso: loop) }.map(\.id)
        let boxes = c.elements.filter { kinds.picks($0.kind) && InkGeometry.lassoSelects($0.drawnFrame, lasso: loop) }.map(\.id)
        selection = grown(key, ids: strokes + boxes)
        return true
    }

    /// Where the lasso's last loop started (a tap there picks what's under it).
    @ObservationIgnored private var lassoTap: InkPoint?

    /// A tap with the lasso (a short Pencil tap or a click) picks the text box, picture or tape under
    /// it, else the strokes it touches (within 8 screen points).
    private func tapSelect(_ p: InkPoint?, key: String) {
        guard let p else { return }
        let c = content[key] ?? InkContent()
        let kinds = lassoKinds
        if let box = c.elements.last(where: { b in kinds.picks(b.kind) && b.contains(p) }) {
            selection = grown(key, ids: [box.id])
            return
        }
        guard kinds.picksInk else { return }
        let r = 8 / max(0.05, zoom)
        let hit = strokes(near: InkGeometry.Rect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r), key: key)
            .filter { InkGeometry.hits($0.points, width: $0.width, x: p.x, y: p.y, radius: r) }.map(\.id)
        if !hit.isEmpty { selection = grown(key, ids: hit) }
    }

    /// The box around the selection, moved by the drag in progress.
    func selectionBox() -> InkGeometry.Rect? {
        guard let sel = selection else { return nil }
        let c = content[sel.pageKey] ?? InkContent()
        var box: InkGeometry.Rect?
        for line in c.strokes where sel.strokes.contains(line.id) { box = InkGeometry.union(box, line.bounds) }
        for b in c.elements where sel.elements.contains(b.id) { box = InkGeometry.union(box, b.drawnBounds) }
        if let box, let t = dragTransform { return t.apply(box) }
        return box
    }

    func corners(_ b: InkGeometry.Rect) -> [InkPoint] {
        [InkPoint(x: b.x, y: b.y), InkPoint(x: b.maxX, y: b.y), InkPoint(x: b.maxX, y: b.maxY), InkPoint(x: b.x, y: b.maxY)]
    }

    private static let strokeFields = ["points", "points2", "width", "color", "nib", "shape"]
    private static let elementFields = ["x", "y", "w", "h", "size", "color", "text", "rotate", "flip", "font", "bold", "italic"]

    /// Fields the lasso changes, read before and after, so undo can put them back.
    private func snapshot(_ sel: InkSelection, strokeFields: [String] = InkEditorModel.strokeFields,
                          elementFields: [String] = InkEditorModel.elementFields) async -> [(ref: Ref, fields: [String: JSONValue])] {
        guard let library = app?.library else { return [] }
        var out: [(ref: Ref, fields: [String: JSONValue])] = []
        for id in sel.strokes { out.append((Ref(id: id, kind: "stroke"), await library.inkFields(id, strokeFields))) }
        for id in sel.elements { out.append((Ref(id: id, kind: "element"), await library.inkFields(id, elementFields))) }
        return out
    }

    private func commitDrag() {
        turning = nil
        guard let t = dragTransform, t.isUsable, t != InkGeometry.Transform(), let sel = selection else {
            if dragTransform != nil { dragTransform = nil; revision += 1 }
            overlayChanged()
            return
        }
        dragTransform = nil
        transformSelection(t, sel)
    }

    /// Moves, resizes, turns or flips what's selected with one transform, then brings connectors
    /// joined to it back onto what they join. One undo step.
    private func transformSelection(_ t: InkGeometry.Transform, _ sel: InkSelection) {
        guard t.isUsable, let library = app?.library else { return }
        // Show it where it landed straight away.
        content[sel.pageKey]?.strokes = (content[sel.pageKey]?.strokes ?? []).map { sel.strokes.contains($0.id) ? $0.transformed(t) : $0 }
        content[sel.pageKey]?.elements = (content[sel.pageKey]?.elements ?? []).map { sel.elements.contains($0.id) ? $0.transformed(t) : $0 }
        for (id, s) in unsavedStrokes where sel.strokes.contains(id) { unsavedStrokes[id] = (s.key, s.line.transformed(t)) }
        revision += 1
        let own = (content[sel.pageKey]?.strokes ?? []).filter { sel.strokes.contains($0.id) && $0.isConnector }.map(\.id)
        let itemId = target.itemId, layer = target.layer
        // After the lasso's previous write: its undo snapshot and reload then see this move's start, not half of it.
        let previous = lassoWrites
        lassoWrites = Task {
            await previous?.value
            let picked = Array(sel.strokes) + Array(sel.elements)
            let joined = await library.connectors(on: itemId, layer: layer, pageKey: sel.pageKey, joinedTo: picked)
            let links = Array(Set(joined + own))
            var touched = sel
            touched.strokes.formUnion(links)
            let before = await snapshot(touched)
            await library.transformStrokes(Array(sel.strokes), by: t)
            await library.transformElements(Array(sel.elements), by: t)
            await library.rerouteConnectors(links)
            record(Action(before: before, after: await snapshot(touched)))
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
        if tool != .lasso { tool = .lasso }
        selection = grown(key, ids: ids)
    }

    /// A selection of ids on a page with the rest of their groups (nil when none are there).
    private func grown(_ key: String, ids: [String]) -> InkSelection? {
        let c = content[key] ?? InkContent()
        var all: [(id: String, group: String)] = c.strokes.map { (line: InkLine) -> (id: String, group: String) in (id: line.id, group: line.group) }
        all += c.elements.map { (box: InkBox) -> (id: String, group: String) in (id: box.id, group: box.group) }
        let set = Set(InkEditing.withGroups(ids, all: all))
        let strokes = Set(c.strokes.map(\.id)).intersection(set), elements = Set(c.elements.map(\.id)).intersection(set)
        let picked = InkSelection(pageKey: key, strokes: strokes, elements: elements)
        return picked.count > 0 ? picked : nil
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
                                                    points: l.points.map { t.apply($0) }, shape: l.shape, style: l.style) { ids.append(id) }
            }
            for b in clip.boxes {
                ids.append(await library.addElement(on: itemId, layer: layer, pageKey: key, kind: b.kind, frame: t.apply(b.frame), text: b.text,
                                                    size: b.size, color: b.color, image: b.image, rotate: b.rotate, flip: b.flip, textStyle: b.textStyle))
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
                               text: "", size: size, color: color(for: .text), style: textStyle)
    }

    private func beginText(_ box: InkBox, key: String) {
        textEdit = InkTextEdit(elementId: box.id, pageKey: key, frame: box.frame, text: box.text, size: box.size, color: box.color,
                               style: box.textStyle, rotate: box.rotate)
        // Shown in the text field while it's typed in.
        revision += 1
    }

    /// Whether a point is on the box being typed in (as tall as its lines).
    private func isInside(_ edit: InkTextEdit, _ p: InkPoint) -> Bool {
        let h = max(edit.frame.height, InkRenderer.textHeight(edit.text, width: edit.frame.width, size: edit.size, style: edit.style))
        return InkEditing.contains(InkEditing.Frame(edit.frame, rotate: edit.rotate), p, height: h)
    }

    /// Closes the text box being typed in, keeping what was typed.
    func commitTextEdit() {
        if let edit = textEdit { commitText(edit) }
    }

    /// A new box, a changed one, or (emptied) none.
    func commitText(_ edit: InkTextEdit) {
        textEdit = nil
        guard let library = app?.library else { return }
        let text = edit.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let itemId = target.itemId, layer = target.layer
        var frame = edit.frame
        frame.height = InkRenderer.textHeight(text, width: frame.width, size: edit.size, style: edit.style)
        revision += 1
        Task {
            if let id = edit.elementId {
                let sel = InkSelection(pageKey: edit.pageKey, strokes: [], elements: [id])
                if text.isEmpty {
                    await library.deleteElements([id])
                    record(Action(remove: [Ref(id: id, kind: "element")]))
                } else {
                    let before = await snapshot(sel)
                    await library.updateElement(id, frame: frame, text: text, size: edit.size, color: edit.color, textStyle: edit.style)
                    record(Action(before: before, after: await snapshot(sel)))
                }
            } else if !text.isEmpty {
                let id = await library.addElement(on: itemId, layer: layer, pageKey: edit.pageKey, kind: .text, frame: frame, text: text,
                                                  size: edit.size, color: edit.color, textStyle: edit.style)
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

    func setPage(_ key: String, paper: InkPaper? = nil, color: String? = nil, size: [Double]? = nil) {
        guard isSketch, let library = app?.library else { return }
        let itemId = target.itemId
        Task {
            await library.setPage(key, of: itemId, paper: paper, color: color, size: size)
            await pagesChanged()
        }
    }

    /// Paper, colour ("" = white) or size for every page at once.
    func setAllPages(paper: InkPaper? = nil, color: String? = nil, size: [Double]? = nil) {
        guard isSketch, let library = app?.library else { return }
        let itemId = target.itemId
        Task {
            await library.setAllPages(of: itemId, paper: paper, color: color, size: size)
            await pagesChanged()
        }
    }

    /// The current page's own colour (nil = white).
    var pageColor: String? {
        if case .paper(_, let color)? = currentPage?.background { return color }
        return nil
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
        commitTextEdit()
        guard edited, isSketch, let first = pages.first, let library = app?.library else { return }
        edited = false // once: Done and closing the window both land here
        let c = display(first.key)
        let bounds = first.infinite ? await library.inkBounds(on: target.itemId, pageKey: first.key) : nil
        if let jpeg = await Task.detached(priority: .utility, operation: { InkRenderer.thumbnailJPEG(first, content: c, bounds: bounds) }).value {
            try? await library.setThumbnail(target.itemId, jpeg: jpeg)
        }
        // Only the pages written on are read again; `.fast` in Low Power Mode or when hot.
        let fast = app?.policy.recognition == .fast
        let pagesRead = await Handwriting.read(target.itemId, library: library, fast: fast)
        app?.power.count { $0.visionPages += pagesRead }
        app?.inkChanged(now: true)
    }
}

// MARK: - Editing faster (ROADMAP S3): guides, shapes and handles, lasso actions, text styles, the elements library

extension InkEditorModel {
    // MARK: Ruler and protractor

    /// Shows or hides the ruler or protractor on the page in view (in its middle).
    func toggleGuide(_ kind: InkGuideKind) {
        let key = currentKey
        if guidesKey != key { ruler = nil; protractor = nil }
        guidesKey = key
        let c = guideCentre()
        switch kind {
        case .ruler: ruler = ruler == nil ? InkEditing.Guide(x: c.x, y: c.y, angle: -Double.pi / 12) : nil
        case .protractor: protractor = protractor == nil ? InkEditing.Guide(x: c.x, y: c.y + 80, angle: 0) : nil
        }
        protractorReading = nil
        if ruler == nil && protractor == nil { guidesKey = nil }
        overlayChanged()
    }

    private func guideCentre() -> InkPoint {
        guard let spec = currentPage, !spec.infinite else { return visibleCenter }
        return InkPoint(x: spec.width / 2, y: spec.height / 2)
    }

    /// What a point is on: a guide's body (`turn` 0, to move it) or one of its knobs (−1, 1, to turn it).
    func guideHit(_ p: InkPoint, pageKey key: String, scale: Double) -> (kind: InkGuideKind, turn: Int)? {
        guard guidesKey == key else { return nil }
        let px = 1 / max(0.05, scale), knob = 16 * px
        if let g = protractor {
            let (u, v) = g.local(p)
            for side in [-1, 1] where hypot(u - Double(side) * (g.radius - InkRenderer.guideKnob), v - 10) <= knob { return (.protractor, side) }
            if v <= 4 * px && hypot(u, v) <= g.radius - 18 { return (.protractor, 0) }
        }
        if let g = ruler, !nativeRuler {
            let (u, v) = g.local(p)
            for side in [-1, 1] where hypot(u - Double(side) * (g.length / 2 - InkRenderer.guideKnob), v) <= knob { return (.ruler, side) }
            if abs(u) <= g.length / 2 && abs(v) <= g.width / 2 - 10 { return (.ruler, 0) }
        }
        return nil
    }

    /// Starts moving or turning a guide when `p` is on one. `pen`: a pen put down on an edge or the arc draws instead.
    @discardableResult
    func beginGuideDrag(_ p: InkPoint, pageKey key: String, scale: Double, pen: Bool) -> Bool {
        guard let hit = guideHit(p, pageKey: key, scale: scale) else { return false }
        if pen, guideSnap(p, pageKey: key, scale: scale) != nil { return false }
        let found: InkEditing.Guide? = hit.kind == .ruler ? ruler : protractor
        guard let g = found else { return false }
        gesture = .guide(kind: hit.kind, turn: hit.turn, start: p, origin: g, grab: atan2(p.y - g.y, p.x - g.x))
        return true
    }

    /// Moves a guide with its body, or turns it about its centre with a knob (snapping to 15° steps).
    private func moveGuide(_ kind: InkGuideKind, turn: Int, start: InkPoint, origin: InkEditing.Guide, grab: Double, to p: InkPoint) {
        var g = origin
        if turn != 0 {
            g.angle = InkEditing.snapRotation(origin.angle + atan2(p.y - origin.y, p.x - origin.x) - grab)
        } else {
            g.x = origin.x + p.x - start.x
            g.y = origin.y + p.y - start.y
        }
        if kind == .ruler { ruler = g } else { protractor = g }
        overlayChanged()
    }

    /// The guide a pen put down at `p` draws along (within 14 screen points of a ruler edge or the protractor's arc).
    func guideSnap(_ p: InkPoint, pageKey key: String, scale: Double) -> InkGuideSnap? {
        guard guidesKey == key else { return nil }
        let tolerance = 14 / max(0.05, scale)
        if let r = ruler, !nativeRuler {
            let edge = InkEditing.rulerEdge(r, p, tolerance: tolerance)
            if edge != 0 { return .ruler(edge) }
        }
        if let pro = protractor, InkEditing.onProtractorArc(pro, p, tolerance: tolerance) { return .arc }
        return nil
    }

    /// A point moved onto the guide edge or arc it's drawn along (pressure and time kept).
    func along(_ snap: InkGuideSnap?, _ p: InkPoint) -> InkPoint {
        switch snap {
        case .ruler(let edge)?:
            guard let r = ruler else { return p }
            return InkEditing.onRulerEdge(r, edge: edge, p)
        case .arc?:
            guard let pro = protractor else { return p }
            return InkEditing.onArc(pro, p)
        case nil:
            return p
        }
    }

    /// The protractor reads the angle of wherever the pen or pointer is near it.
    func noteReading(_ p: InkPoint?, pageKey key: String?) {
        guard let pro = protractor, guidesKey != nil else { return }
        var next: InkPoint?
        if let p, key == guidesKey, hypot(p.x - pro.x, p.y - pro.y) <= pro.radius * 1.6 { next = p }
        if next == nil && protractorReading == nil { return }
        protractorReading = next
        overlayChanged()
    }

    // MARK: Shapes: the picker, handles and connectors

    /// The selection when it's one clean shape on its own (it shows its own handles). Connectors follow what they join instead.
    func singleShape() -> InkLine? {
        guard let sel = selection, sel.strokes.count == 1, sel.elements.isEmpty, let id = sel.strokes.first,
              let line = content[sel.pageKey]?.strokes.first(where: { $0.id == id }), line.shape != nil, !line.isConnector else { return nil }
        return line
    }

    private func shapeHandleIndex(at p: InkPoint, scale: Double) -> Int? {
        guard let line = singleShape() else { return nil }
        let r = 14 / max(0.05, scale)
        return InkEditing.shapeHandles(shape: line.shape, points: line.points).firstIndex { hypot($0.x - p.x, $0.y - p.y) <= r }
    }

    /// The box a connector end follows: a stroke's line grown by half its width, or an element's box as drawn.
    private func localBox(_ id: String, key: String) -> InkGeometry.Rect? {
        guard !id.isEmpty else { return nil }
        let c = content[key] ?? InkContent()
        if let line = c.strokes.first(where: { $0.id == id }) { return InkGeometry.bounds(line.points, pad: line.width / 2) }
        if let box = c.elements.first(where: { $0.id == id }) { return box.drawnBounds }
        return nil
    }

    /// The text box, picture or closed shape under a point that a connector can join.
    private func connectableAt(_ p: InkPoint, key: String) -> String? {
        let c = content[key] ?? InkContent()
        if let box = c.elements.last(where: { $0.contains(p) }) { return box.id }
        let shape = c.strokes.last { line in
            guard InkEditing.connectable(shape: line.shape, from: line.from, to: line.to),
                  let b = InkGeometry.bounds(line.points, pad: line.width / 2) else { return false }
            return p.x >= b.x && p.x <= b.maxX && p.y >= b.y && p.y <= b.maxY
        }
        return shape?.id
    }

    /// The stroke the shape tool would add for a drag from `a` to `b`.
    private func shapeLine(key: String, from a: InkPoint, to b: InkPoint, fromId: String) -> InkLine? {
        var style = InkStrokeStyle(dash: dash(for: .shape))
        let kind = shapeKind, color = color(for: .shape), width = width(for: .shape)
        if kind == .line || kind == .arrow || kind == .connector {
            var toId = ""
            var ends = (InkPoint(x: a.x, y: a.y), InkPoint(x: b.x, y: b.y))
            if kind == .connector {
                toId = connectableAt(b, key: key) ?? ""
                if toId == fromId { toId = "" }
                ends = InkEditing.connectorEnds(a, b, from: localBox(fromId, key: key), to: localBox(toId, key: key))
            }
            if kind == .line { style.arrow = arrow } else { style.arrow = arrow == "both" ? "both" : "end" }
            var line = InkLine(id: "shape-draft", tool: .pen, color: color, width: width, points: [ends.0, ends.1], shape: "line", style: style)
            line.from = fromId
            line.to = toId
            return line
        }
        guard let pts = InkEditing.shapePoints(kind.rawValue, from: a, to: b) else { return nil }
        if InkStrokeStyle.closedShapes.contains(kind.rawValue) { style.fill = fill }
        return InkLine(id: "shape-draft", tool: .pen, color: color, width: width, points: pts, shape: kind.rawValue, style: style)
    }

    /// The shape tool lifts: the shape it dragged out (a tap adds nothing).
    private func finishShape(key: String, from a: InkPoint, to b: InkPoint, fromId: String) {
        shapeDraft = nil
        overlayChanged()
        guard hypot(b.x - a.x, b.y - a.y) * max(0.05, zoom) >= 6, var line = shapeLine(key: key, from: a, to: b, fromId: fromId),
              let library = app?.library else { return }
        let id = UUID().uuidString.lowercased()
        line.id = id
        content[key, default: InkContent()].strokes.append(line)
        unsavedStrokes[id] = (key, line)
        revision += 1
        record(Action(add: [Ref(id: id, kind: "stroke")]))
        let itemId = target.itemId, layer = target.layer, stored = line
        Task {
            await library.addStroke(id: id, on: itemId, layer: layer, pageKey: key, tool: stored.tool, color: stored.color, width: stored.width,
                                    points: stored.points, shape: stored.shape, style: stored.style.isEmpty ? nil : stored.style,
                                    from: stored.from, to: stored.to)
            unsavedStrokes[id] = nil
            app?.inkChanged()
        }
    }

    /// A handle lifts: the reshaped shape is stored, and connectors joined to it follow.
    private func commitHandle() {
        guard let edit = shapeEdit, let library = app?.library else { shapeEdit = nil; revision += 1; return }
        shapeEdit = nil
        let key = edit.key, line = edit.line
        if let i = content[key]?.strokes.firstIndex(where: { $0.id == line.id }) { content[key]?.strokes[i] = line }
        revision += 1
        let itemId = target.itemId, layer = target.layer
        let previous = lassoWrites
        lassoWrites = Task {
            await previous?.value
            let links = await library.connectors(on: itemId, layer: layer, pageKey: key, joinedTo: [line.id])
            let sel = InkSelection(pageKey: key, strokes: Set([line.id] + links), elements: [])
            let before = await snapshot(sel)
            await library.setStrokeShape(line.id, shape: line.shape, points: line.points)
            await library.rerouteConnectors(links)
            record(Action(before: before, after: await snapshot(sel)))
            await reloadInk()
            app?.inkChanged()
        }
    }

    // MARK: The lasso's actions

    private func selectionCentre() -> InkPoint? {
        guard let b = selectionBox() else { return nil }
        return InkPoint(x: b.x + b.width / 2, y: b.y + b.height / 2)
    }

    /// Turns the selection about its middle (radians, clockwise).
    func turnSelection(by r: Double) {
        guard let sel = selection, let c = selectionCentre() else { return }
        transformSelection(InkEditing.rotate(r, about: c), sel)
    }

    /// Mirrors the selection left to right (`horizontal`) or upside down.
    func flipSelection(horizontal: Bool) {
        guard let sel = selection, let c = selectionCentre() else { return }
        transformSelection(InkEditing.flip(horizontal: horizontal, about: c), sel)
    }

    /// Straighten: turns slanted writing level (or upright) about its middle.
    func straightenSelection() {
        guard let sel = selection else { return }
        let lines = (content[sel.pageKey]?.strokes ?? []).filter { sel.strokes.contains($0.id) }
        let r = InkEditing.straightenAngle(lines.flatMap(\.points))
        if abs(r) > 1e-4 { turnSelection(by: r) }
    }

    /// Bring to front (`front`) or send to back, keeping the picked things' own order.
    func arrangeSelection(front: Bool) {
        guard let sel = selection, let library = app?.library else { return }
        Task {
            let before = await snapshot(sel, strokeFields: ["createdAt"], elementFields: ["createdAt"])
            await library.reorderInk(Array(sel.strokes) + Array(sel.elements), front: front)
            record(Action(before: before, after: await snapshot(sel, strokeFields: ["createdAt"], elementFields: ["createdAt"])))
            await reloadInk()
            app?.inkChanged()
        }
    }

    /// The selection's group when it's exactly one whole group, else "".
    var selectionGroup: String {
        guard let sel = selection else { return "" }
        let c = content[sel.pageKey] ?? InkContent()
        var groups: Set<String> = []
        for line in c.strokes where sel.strokes.contains(line.id) { groups.insert(line.group) }
        for box in c.elements where sel.elements.contains(box.id) { groups.insert(box.group) }
        guard groups.count == 1, let only = groups.first else { return "" }
        return only
    }

    /// Groups the selection (picked and moved as one from then on), or ungroups it if it's one group.
    func toggleGroup() {
        guard let sel = selection, let library = app?.library else { return }
        let ungroup = !selectionGroup.isEmpty
        guard ungroup || sel.count >= 2 else { return }
        Task {
            let before = await snapshot(sel, strokeFields: ["group"], elementFields: ["group"])
            await library.setInkGroup(Array(sel.strokes) + Array(sel.elements), group: ungroup ? "" : nil)
            record(Action(before: before, after: await snapshot(sel, strokeFields: ["group"], elementFields: ["group"])))
            await reloadInk()
            app?.inkChanged()
        }
    }

    /// Just the selected ink, to draw on its own.
    private func selectionContent(_ sel: InkSelection) -> InkContent {
        let c = content[sel.pageKey] ?? InkContent()
        var out = InkContent()
        out.strokes = c.strokes.filter { sel.strokes.contains($0.id) }
        out.elements = c.elements.filter { sel.elements.contains($0.id) }
        out.pictures = pictures
        return out
    }

    /// The selection's box with a little room round it.
    private func selectionArea() -> InkGeometry.Rect? {
        guard let b = selectionBox() else { return nil }
        return InkGeometry.Rect(x: b.x - 8, y: b.y - 8, width: b.width + 16, height: b.height + 16)
    }

    /// Copy as image: a PNG of the selection on the clipboard.
    func copySelectionAsImage() {
        guard let sel = selection, let area = selectionArea() else { return }
        let c = selectionContent(sel)
        guard let image = InkRenderer.renderSelection(c, box: area, scale: 3), let png = InkRenderer.png(image) else { return }
        #if os(iOS)
        UIPasteboard.general.setData(png, forPasteboardType: UTType.png.identifier)
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(png, forType: .png)
        #endif
        app?.toast = "Copied as a picture"
    }

    /// Convert to text: the handwriting read off the selection (Vision, on this device) becomes a text box under it.
    func convertSelectionToText() {
        guard let sel = selection, let area = selectionArea(), let library = app?.library else { return }
        var c = selectionContent(sel)
        c.elements = []
        let key = sel.pageKey, itemId = target.itemId, layer = target.layer
        let size = width(for: .text), color = color(for: .text), style = textStyle
        Task {
            let text = await Task.detached(priority: .userInitiated) { () async -> String in
                guard let image = InkRenderer.renderSelection(c, box: area, scale: 3, whiteBackground: true) else { return "" }
                return await AppleEnricher.recognizeText(in: image)
            }.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { app?.toast = "No handwriting found there"; return }
            let w = max(120, area.width - 16)
            let h = InkRenderer.textHeight(text, width: w, size: size, style: style)
            let frame = InkGeometry.Rect(x: area.x + 8, y: area.maxY + 4, width: w, height: h)
            let id = await library.addElement(on: itemId, layer: layer, pageKey: key, kind: .text, frame: frame, text: text, size: size,
                                              color: color, textStyle: style)
            record(Action(add: [Ref(id: id, kind: "element")]))
            await reloadInk()
            app?.inkChanged()
        }
    }

    /// Ask AI about the selection: on this device with Apple Intelligence (from the handwriting read
    /// off it), else the relay's cloud AI (from a picture of it) when that's on.
    func askAI(_ action: InkAIAction) {
        guard let sel = selection, let area = selectionArea(), let app else { return }
        let c = selectionContent(sel)
        aiBusy = true
        Task {
            let picture = await Task.detached(priority: .userInitiated) { () async -> (png: Data?, text: String) in
                guard let image = InkRenderer.renderSelection(c, box: area, scale: 2, whiteBackground: true) else { return (nil, "") }
                let text = await AppleEnricher.recognizeText(in: image)
                return (InkRenderer.png(image), text)
            }.value
            if let png = picture.png, let result = await app.runInkAI(action, image: png, text: picture.text) {
                aiResult = InkAIResult(action: action, result: result)
            }
            aiBusy = false
        }
    }

    /// Ask AI's answer as a note connected to this drawing (or its flashcards as a flashcards note).
    func saveAIResult() {
        guard let r = aiResult, let library = app?.library else { return }
        aiResult = nil
        let itemId = target.itemId, title = target.title
        Task {
            if !r.result.cards.isEmpty {
                if let item = await library.item(itemId) { await app?.saveFlashcards(r.result, from: item) }
                return
            }
            let body = r.result.text + "\n\n_" + r.result.label + "._"
            let id = await library.addNote(title: r.action.label + ": " + title, body: body)
            let ai: JSONValue = .object(["where": .string(r.result.place), "model": .string(r.result.model)])
            await library.update(id, ["ai": ai, "needsEnrichment": .bool(false)])
            await library.connect(id, itemId)
            app?.toast = "Saved as a note"
            app?.inkChanged(now: true)
        }
    }

    // MARK: The elements library

    func loadStickers() async {
        guard let library = app?.library else { return }
        stickers = await library.stickers()
    }

    /// Save as element: the selection becomes a reusable element (on every device).
    func saveSelectionAsElement(name: String, folder: String) {
        guard let sel = selection, let library = app?.library else { return }
        let itemId = target.itemId, layer = target.layer
        Task {
            let strokes = await library.strokes(on: itemId, layer: layer, pageKey: sel.pageKey).filter { sel.strokes.contains($0.id) }
            let elements = await library.elements(on: itemId, layer: layer, pageKey: sel.pageKey).filter { sel.elements.contains($0.id) }
            await library.addSticker(name: name.trimmingCharacters(in: .whitespacesAndNewlines), folder: folder.trimmingCharacters(in: .whitespacesAndNewlines),
                                     strokes: strokes, elements: elements)
            await loadStickers()
            app?.toast = "Saved to your elements"
            app?.inkChanged()
        }
    }

    /// Puts a library element in the middle of the page (or of what's in view on an endless canvas), selected.
    func placeSticker(_ sticker: InkSticker) {
        guard let library = app?.library, let spec = currentPage else { return }
        let key = spec.key, itemId = target.itemId, layer = target.layer
        let at = spec.infinite ? visibleCenter : InkPoint(x: spec.width / 2, y: spec.height / 2)
        Task {
            let ids = await library.placeSticker(sticker, on: itemId, layer: layer, pageKey: key, at: at)
            guard !ids.isEmpty else { return }
            await reloadInk()
            record(Action(add: ids.map { Ref(id: $0, kind: kind(of: $0, key: key)) }))
            selectIds(ids, key: key)
            app?.inkChanged()
        }
    }

    func deleteSticker(_ sticker: InkSticker) {
        guard !sticker.builtin, let library = app?.library else { return }
        Task {
            await library.deleteSticker(sticker.id)
            await loadStickers()
            app?.inkChanged()
        }
    }

    /// A library element as ink to draw (its preview).
    static func stickerContent(_ sticker: InkSticker) -> InkContent {
        var c = InkContent()
        var lines: [InkLine] = []
        for (i, s) in sticker.strokes.enumerated() {
            lines.append(InkLine(id: "\(sticker.id)#\(i)", tool: s.inkTool, color: s.color, width: s.width, points: s.points, shape: s.shape, style: s.style))
        }
        var boxes: [InkBox] = []
        for (i, e) in sticker.elements.enumerated() { boxes.append(InkBox(id: "\(sticker.id)@\(i)", sticker: e)) }
        c.strokes = lines
        c.elements = boxes
        return c
    }

    // MARK: Text style

    /// Whether text boxes are among what the lasso picked (the text options then show).
    var selectionHasText: Bool {
        guard let sel = selection, !sel.elements.isEmpty else { return false }
        return (content[sel.pageKey]?.elements ?? []).contains { sel.elements.contains($0.id) && $0.kind == .text }
    }

    /// The style the text options show: the box being typed in, else a selected text box, else the next box's.
    var currentTextStyle: InkTextStyle {
        if let edit = textEdit { return edit.style }
        if let sel = selection, let box = (content[sel.pageKey]?.elements ?? []).first(where: { sel.elements.contains($0.id) && $0.kind == .text }) {
            return box.textStyle
        }
        return textStyle
    }

    /// Font, bold or italic: on the box being typed in, the selected text boxes, and the next new box.
    func applyTextStyle(_ style: InkTextStyle) {
        textStyle = style
        if textEdit != nil {
            textEdit?.style = style
            return
        }
        guard let sel = selection, let library = app?.library else { return }
        let boxes = (content[sel.pageKey]?.elements ?? []).filter { sel.elements.contains($0.id) && $0.kind == .text }
        guard !boxes.isEmpty else { return }
        let only = InkSelection(pageKey: sel.pageKey, strokes: [], elements: Set(boxes.map(\.id)))
        Task {
            let before = await snapshot(only)
            for box in boxes {
                var frame = box.frame
                frame.height = InkRenderer.textHeight(box.text, width: frame.width, size: box.size, style: style)
                await library.updateElement(box.id, frame: frame, textStyle: style)
            }
            record(Action(before: before, after: await snapshot(only)))
            await reloadInk()
            app?.inkChanged()
        }
    }

    /// Bullets on every line of the box being typed in, or off when they all have one.
    func toggleBullets() {
        guard let edit = textEdit else { return }
        textEdit?.text = InkTextStyle.toggleBullets(edit.text)
    }
}

/// A Return in a bulleted line continues the list ("• "); on an empty bullet it ends it.
enum InkBullets {
    static func afterReturn(_ text: String, at location: Int) -> (text: String, cursor: Int)? {
        let ns = text as NSString
        guard location >= 0, location <= ns.length else { return nil }
        let before = ns.substring(to: location) as NSString
        let newline = before.range(of: "\n", options: .backwards).location
        let start = newline == NSNotFound ? 0 : newline + 1
        let line = before.substring(from: start)
        guard line.hasPrefix("• ") else { return nil }
        if line == "• " {
            return (ns.replacingCharacters(in: NSRange(location: start, length: location - start), with: ""), start)
        }
        return (ns.replacingCharacters(in: NSRange(location: location, length: 0), with: "\n• "), location + 3)
    }
}
