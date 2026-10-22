import PDFKit
import SwiftUI
import TroveCore
#if os(iOS)
import UIKit
#else
import AppKit
#endif

// PDFs like a PDF app (ROADMAP S5, PROTOCOL.md §10 "PDF text, highlights and forms"): PDFKit's view
// with find, highlighting selected text (the words are saved with the highlight), quotes, links and
// the form. Highlights, form values and Trove's ink are records on the file's layer, as on the
// website; the file itself never changes. "Export with annotations" writes them as real PDF
// annotations other apps can edit, shared or saved as a new version.

// MARK: Pages that draw Trove's marks

/// What Trove draws on one PDF page, in page points (top left, y down; `PDFPageBox`).
struct PDFPageMarks: @unchecked Sendable {
    var box: PDFPageBox
    var content: InkContent
}

/// A PDF page that draws Trove's highlights, ink, text boxes and tape over itself. PDFKit renders
/// pages on its own threads, so the marks are behind a lock.
final class TrovePDFPage: PDFPage {
    private let lock = NSLock()
    private var current: PDFPageMarks?

    var marks: PDFPageMarks? {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }

    override func draw(with box: PDFDisplayBox, to context: CGContext) {
        super.draw(with: box, to: context)
        guard let marks, !(marks.content.strokes.isEmpty && marks.content.elements.isEmpty) else { return }
        context.saveGState()
        // Into the page's own space (PDF units, y up), then page points (y down, turned by /Rotate).
        transform(context, for: box)
        context.concatenate(PDFReaderGeometry.pageToPDF(marks.box))
        InkRenderer.drawContent(marks.content, in: context)
        context.restoreGState()
    }
}

/// Makes a document's pages `TrovePDFPage`s (PDFKit asks its delegate for the class).
final class TrovePDFPageClass: NSObject, PDFDocumentDelegate {
    func classForPage() -> AnyClass { TrovePDFPage.self }
}

enum PDFReaderGeometry {
    /// A page's box as Trove measures it: its crop box in PDF space, turned by its rotation.
    static func box(_ page: PDFPage) -> PDFPageBox {
        let r = page.bounds(for: .cropBox)
        return PDFPageBox(view: [r.minX, r.minY, r.maxX, r.maxY], rotate: page.rotation)
    }

    /// Page points → PDF space, as a transform (`PDFPageBox.toPDF`).
    static func pageToPDF(_ b: PDFPageBox) -> CGAffineTransform {
        switch b.rotate {
        case 90: return CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: b.x1, ty: b.y1)
        case 180: return CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: b.x2, ty: b.y1)
        case 270: return CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: b.x2, ty: b.y2)
        default: return CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: b.x1, ty: b.y2)
        }
    }

    /// A rect in PDF space → page points.
    static func toPage(_ r: CGRect, _ b: PDFPageBox) -> InkGeometry.Rect {
        let p = b.toPage(r.minX, r.minY), q = b.toPage(r.maxX, r.maxY)
        let x = min(p.x, q.x), y = min(p.y, q.y)
        return InkGeometry.Rect(x: x, y: y, width: abs(q.x - p.x), height: abs(q.y - p.y))
    }

    /// A rect in page points → PDF space.
    static func toPDF(_ r: InkGeometry.Rect, _ b: PDFPageBox) -> CGRect {
        let p = b.toPDF(r.x, r.y), q = b.toPDF(r.x + r.width, r.y + r.height)
        return CGRect(x: min(p.x, q.x), y: min(p.y, q.y), width: abs(q.x - p.x), height: abs(q.y - p.y))
    }
}

// MARK: The reader's state

@MainActor
@Observable
final class PDFReaderModel {
    static let colors = ["#ffd60a", "#34c759", "#0a84ff", "#ff6fae", "#ff9500"]
    static let colorNames = ["yellow", "green", "blue", "pink", "orange"]

    let itemId: String
    let layer: String
    let document: PDFDocument?
    @ObservationIgnored private let pageClass = TrovePDFPageClass()
    @ObservationIgnored weak var view: PDFView?
    /// A tap on the page away from highlights, links and fields (the item's inline preview opens the viewer).
    @ObservationIgnored var onOpen: (() -> Void)?

    /// The selected text (empty: nothing selected).
    var selectedText = ""
    /// The highlight a tap opened.
    var openHighlight: InkElement?
    var lastColor = PDFReaderModel.colors[0]

    var findOpen = false
    var query = ""
    private(set) var hits: [PDFSelection] = []
    private(set) var current = -1
    private(set) var searching = false

    /// Highlights by page, for taps.
    @ObservationIgnored private var highlights: [Int: [InkElement]] = [:]
    @ObservationIgnored private var drawnSignature: [Int: String] = [:]
    /// Form values as last saved or loaded, by field name.
    @ObservationIgnored private var fieldValues: [String: JSONValue] = [:]
    @ObservationIgnored private var fieldsLoaded = false
    private(set) var hasForm = false

    init(itemId: String, layer: String, data: Data) {
        self.itemId = itemId
        self.layer = layer
        let doc = PDFDocument(data: data)
        doc?.delegate = pageClass
        document = doc
        hasForm = !(doc.map(Self.widgets) ?? []).isEmpty
    }

    var pageCount: Int { document?.pageCount ?? 0 }
    /// The page to show first (the viewer opened at a page).
    @ObservationIgnored var startPage = 0

    // MARK: Marks

    /// Re-reads ink, highlights and text boxes, and redraws the pages whose marks changed.
    func refresh(_ library: Library) async {
        guard let document else { return }
        let strokes = Dictionary(grouping: await library.strokes(on: itemId, layer: layer), by: \.pageKey)
        let elements = Dictionary(grouping: await library.elements(on: itemId, layer: layer), by: \.pageKey)
        var pictures: [String: CGImage] = [:]
        for e in elements.values.joined() where e.kind == .image {
            if let att = e.image, pictures[att.id] == nil, let data = try? await library.attachmentData(att), let image = InkRenderer.cgImage(data) {
                pictures[att.id] = image
            }
        }
        highlights = [:]
        for i in 0..<document.pageCount {
            guard let page = document.page(at: i) as? TrovePDFPage else { continue }
            let key = String(i)
            let lines = strokes[key] ?? [], boxes = (elements[key] ?? []).filter { $0.kind != .field }
            highlights[i] = boxes.filter { $0.kind == .highlight }
            let sig = "\(lines.count)-\(lines.map(\.record.updatedHLC).max() ?? "")-\(boxes.count)-\(boxes.map(\.record.updatedHLC).max() ?? "")"
            guard drawnSignature[i] != sig else { continue }
            drawnSignature[i] = sig
            var content = InkContent()
            content.strokes = lines.map(InkLine.init)
            content.elements = boxes.map(InkBox.init)
            content.pictures = pictures
            page.marks = PDFPageMarks(box: PDFReaderGeometry.box(page), content: content)
            view?.annotationsChanged(on: page)
        }
        if let open = openHighlight, !(highlights.values.joined().contains { $0.id == open.id }) { openHighlight = nil }
        await loadFields(library)
    }

    // MARK: Selection and highlights

    func selectionChanged() {
        let text = view?.currentSelection?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        selectedText = text
        if !text.isEmpty { openHighlight = nil }
    }

    /// Highlights the selected text in `color`; with `quote`, also keeps it in Quotes & Highlights.
    func highlightSelection(_ color: String, quote: Bool, model: AppModel) async {
        guard let library = model.library, let document, let selection = view?.currentSelection else { return }
        lastColor = color
        var words: [(page: Int, text: String)] = []
        for page in selection.pages {
            let index = document.index(for: page)
            let box = PDFReaderGeometry.box(page)
            let lines = selection.selectionsByLine().filter { $0.pages.contains(page) }
            let boxes = lines.map { PDFReaderGeometry.toPage($0.bounds(for: page), box) }
            let text = lines.compactMap(\.string).joined(separator: " ")
            if await library.addHighlight(on: itemId, layer: layer, pageKey: String(index), boxes: boxes, quote: text, color: color) != nil {
                words.append((index, text))
            }
        }
        view?.clearSelection()
        selectedText = ""
        if quote, let first = words.first {
            await library.addQuote(words.map(\.text).joined(separator: " "), from: itemId, page: first.page)
            model.toast = "Kept in Quotes & Highlights"
        }
        await done(model)
    }

    func recolor(_ e: InkElement, _ color: String, model: AppModel) async {
        lastColor = color
        await model.library?.updateElement(e.id, color: color)
        openHighlight = nil
        await done(model)
    }

    func remove(_ e: InkElement, model: AppModel) async {
        await model.library?.deleteElements([e.id])
        openHighlight = nil
        await done(model)
    }

    func quote(_ e: InkElement, model: AppModel) async {
        guard let page = Int(e.pageKey) else { return }
        await model.library?.addQuote(e.quote, from: itemId, page: page)
        openHighlight = nil
        model.toast = "Kept in Quotes & Highlights"
        await done(model)
    }

    func copy(_ e: InkElement?) {
        let text = e?.quote ?? view?.currentSelection?.string ?? ""
        Pasteboard.copy(PDFText.cleanQuote(text))
        openHighlight = nil
    }

    private func done(_ model: AppModel) async {
        if let library = model.library { await refresh(library) }
        model.inkChanged(now: true)
        await model.reload()
    }

    /// A tap at a point in the view: opens the highlight under it, if any.
    func tapped(at point: CGPoint) {
        guard let view, selectedText.isEmpty, let document, let page = view.page(for: point, nearest: false) else { openHighlight = nil; return }
        let inPage = view.convert(point, to: page)
        let p = PDFReaderGeometry.box(page).toPage(inPage.x, inPage.y)
        let index = document.index(for: page)
        openHighlight = (highlights[index] ?? []).reversed().first { e in
            e.highlightPieces.contains { r in p.x >= r.x && p.x <= r.x + r.width && p.y >= r.y && p.y <= r.y + r.height }
        }
        if openHighlight == nil, page.annotation(at: inPage) == nil { onOpen?() }
    }

    /// View-only: the form's fields can't be typed in or ticked (PDFKit edits them in place otherwise).
    func setFormEditable(_ on: Bool) {
        guard hasForm, let document else { return }
        for (_, a) in Self.widgets(document) where a.isReadOnly == on { a.isReadOnly = !on }
    }

    // MARK: Find

    func runFind() {
        guard let document else { return }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        hits = q.isEmpty ? [] : document.findString(q, withOptions: [.caseInsensitive, .diacriticInsensitive])
        current = hits.isEmpty ? -1 : 0
        showHits()
    }

    func step(_ by: Int) {
        guard !hits.isEmpty else { return }
        current = (current + by + hits.count) % hits.count
        showHits()
    }

    func closeFind() {
        findOpen = false
        query = ""
        hits = []
        current = -1
        view?.highlightedSelections = nil
    }

    private func showHits() {
        #if os(iOS)
        let all = UIColor.systemYellow.withAlphaComponent(0.45), now = UIColor.systemOrange.withAlphaComponent(0.7)
        #else
        let all = NSColor.systemYellow.withAlphaComponent(0.45), now = NSColor.systemOrange.withAlphaComponent(0.7)
        #endif
        for (i, hit) in hits.enumerated() { hit.color = i == current ? now : all }
        view?.highlightedSelections = hits.isEmpty ? nil : hits
        if hits.indices.contains(current) { view?.go(to: hits[current]) }
    }

    var findStatus: String {
        if query.trimmingCharacters(in: .whitespaces).isEmpty { return "" }
        return hits.isEmpty ? "Not found" : "\(current + 1) of \(hits.count)"
    }

    // MARK: The form

    nonisolated static func widgets(_ document: PDFDocument) -> [(page: Int, annotation: PDFAnnotation)] {
        var out: [(Int, PDFAnnotation)] = []
        for i in 0..<document.pageCount {
            guard let page = document.page(at: i) else { continue }
            for a in page.annotations where isWidget(a) && !(a.fieldName ?? "").isEmpty { out.append((i, a)) }
        }
        return out
    }

    nonisolated static func isWidget(_ a: PDFAnnotation) -> Bool {
        a.type == "Widget" || a.type == PDFAnnotationSubtype.widget.rawValue || a.type == "/Widget"
    }

    /// What a widget holds now: text, true/false for a check box, the chosen radio button's value.
    nonisolated static func value(of a: PDFAnnotation) -> JSONValue? {
        switch a.widgetFieldType {
        case .text, .choice: return .string(a.widgetStringValue ?? "")
        case .button:
            switch a.widgetControlType {
            case .checkBoxControl: return .bool(a.buttonWidgetState == .onState)
            case .radioButtonControl: return a.buttonWidgetState == .onState ? .string(a.buttonWidgetStateString) : nil
            default: return nil
            }
        default: return nil
        }
    }

    /// Shows a saved value in a widget.
    nonisolated static func apply(_ v: JSONValue, to a: PDFAnnotation) {
        switch a.widgetFieldType {
        case .text, .choice:
            if let s = v.string ?? v.array?.first?.string, a.widgetStringValue != s { a.widgetStringValue = s }
        case .button:
            switch a.widgetControlType {
            case .checkBoxControl:
                let on = v.bool ?? (v.string.map { $0 != "Off" && $0 == a.buttonWidgetStateString } ?? false)
                a.buttonWidgetState = on ? .onState : .offState
            case .radioButtonControl:
                a.buttonWidgetState = v.string == a.buttonWidgetStateString ? .onState : .offState
            default: break
            }
        default: break
        }
    }

    /// Shows saved values (from any device) in the fields, except one being typed in.
    private func loadFields(_ library: Library) async {
        guard hasForm, let document else { return }
        let saved = await library.pdfFields(on: itemId, layer: layer)
        for (_, a) in Self.widgets(document) {
            guard let name = a.fieldName, let e = saved[name], let v = e.fieldValue else { continue }
            // Unchanged since we last saw it: leave what's being typed alone.
            if fieldsLoaded, fieldValues[name] == v { continue }
            Self.apply(v, to: a)
        }
        for (name, e) in saved { if let v = e.fieldValue { fieldValues[name] = v } }
        if !fieldsLoaded {
            // The file's own values count as seen, so only edits are saved.
            for (name, now) in currentValues() where fieldValues[name] == nil { fieldValues[name] = now.value }
            fieldsLoaded = true
        }
    }

    /// Each field's value now, with the widget that shows it. A radio group is the button that's on
    /// (none on: left out); check boxes sharing a name are ticked if any is.
    private func currentValues() -> [String: (value: JSONValue, page: Int, frame: CGRect)] {
        guard let document else { return [:] }
        var out: [String: (value: JSONValue, page: Int, frame: CGRect)] = [:]
        for (page, a) in Self.widgets(document) {
            guard let name = a.fieldName, let v = Self.value(of: a) else { continue }
            if let had = out[name], had.value == .bool(true) || a.widgetControlType == .radioButtonControl { continue }
            out[name] = (v, page, a.bounds)
        }
        return out
    }

    /// Saves fields whose value changed since the last look (PDFKit edits them in place).
    func saveFields(_ library: Library) async -> Bool {
        guard hasForm, fieldsLoaded, let document else { return false }
        var changed = false
        for (name, now) in currentValues() where fieldValues[name] != now.value {
            guard let page = document.page(at: now.page) else { continue }
            let frame = PDFReaderGeometry.toPage(now.frame, PDFReaderGeometry.box(page))
            if await library.setPDFField(on: itemId, layer: layer, pageKey: String(now.page), name: name, value: now.value, frame: frame) != nil {
                fieldValues[name] = now.value
                changed = true
            }
        }
        return changed
    }

    // MARK: Export as real annotations

    /// The PDF with Trove's ink, highlights, text boxes and form values as real annotations (nil if
    /// there's nothing to export). Pictures and tape stay in Trove.
    nonisolated static func annotated(_ data: Data, strokes: [InkStroke], elements: [InkElement]) -> Data? {
        guard let doc = PDFDocument(data: data) else { return nil }
        let strokesByPage = Dictionary(grouping: strokes, by: \.pageKey)
        let elementsByPage = Dictionary(grouping: elements, by: \.pageKey)
        var count = 0
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            let box = PDFReaderGeometry.box(page), crop = page.bounds(for: .cropBox)
            for s in strokesByPage[String(i)] ?? [] where !s.points.isEmpty {
                let path = BezierPath()
                for (n, p) in s.points.enumerated() {
                    let q = box.toPDF(p.x, p.y)
                    let point = CGPoint(x: q.x - crop.minX, y: q.y - crop.minY)
                    if n == 0 { path.move(to: point) } else { path.addLine(toPoint: point) }
                }
                let a = PDFAnnotation(bounds: crop, forType: .ink, withProperties: nil)
                a.color = PlatformColor.of(InkRenderer.cgColor(s.color, alpha: s.tool.opacity))
                let border = PDFBorder()
                border.lineWidth = max(0.3, InkOutline.lineWidth(tool: s.tool, width: s.width, points: s.points))
                a.border = border
                a.add(path)
                page.addAnnotation(a)
                count += 1
            }
            for e in elementsByPage[String(i)] ?? [] {
                switch e.kind {
                case .highlight:
                    let pieces = e.highlightPieces.map { PDFReaderGeometry.toPDF($0, box) }
                    guard var bounds = pieces.first else { continue }
                    for r in pieces { bounds = bounds.union(r) }
                    let a = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
                    // Per piece: top left, top right, bottom left, bottom right, from the annotation's corner.
                    a.quadrilateralPoints = pieces.flatMap { r -> [NSValue] in
                        [CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY)]
                            .map { value(CGPoint(x: $0.x - bounds.minX, y: $0.y - bounds.minY)) }
                    }
                    a.color = PlatformColor.of(InkRenderer.cgColor(e.color, alpha: 0.35))
                    if !e.quote.isEmpty { a.contents = e.quote }
                    page.addAnnotation(a)
                    count += 1
                case .text where !e.text.isEmpty:
                    var f = e.frame
                    f.height = max(f.height, InkRenderer.textHeight(e.text, width: f.width, size: e.size, style: e.textStyle))
                    let a = PDFAnnotation(bounds: PDFReaderGeometry.toPDF(f, box), forType: .freeText, withProperties: nil)
                    a.contents = e.text
                    a.font = PlatformFont.systemFont(ofSize: e.size)
                    a.fontColor = PlatformColor.of(InkRenderer.cgColor(e.color))
                    a.color = .clear
                    let border = PDFBorder()
                    border.lineWidth = 0
                    a.border = border
                    page.addAnnotation(a)
                    count += 1
                default: break
                }
            }
        }
        let saved = Dictionary(elements.filter { $0.kind == .field && !$0.fieldName.isEmpty }.compactMap { e in e.fieldValue.map { (e.fieldName, $0) } },
                               uniquingKeysWith: { a, _ in a })
        for (_, a) in widgets(doc) {
            guard let name = a.fieldName, let v = saved[name] else { continue }
            apply(v, to: a)
            count += 1
        }
        return count == 0 ? nil : doc.dataRepresentation()
    }

    private nonisolated static func value(_ p: CGPoint) -> NSValue {
        #if os(iOS)
        NSValue(cgPoint: p)
        #else
        NSValue(point: p)
        #endif
    }
}

#if os(iOS)
typealias BezierPath = UIBezierPath
typealias PlatformColor = UIColor
typealias PlatformFont = UIFont
extension UIBezierPath {
    func addLine(toPoint p: CGPoint) { addLine(to: p) }
}
#else
typealias BezierPath = NSBezierPath
typealias PlatformColor = NSColor
typealias PlatformFont = NSFont
extension NSBezierPath {
    func addLine(toPoint p: CGPoint) { line(to: p) }
}
#endif

extension PlatformColor {
    static func of(_ cg: CGColor) -> PlatformColor {
        #if os(iOS)
        UIColor(cgColor: cg)
        #else
        NSColor(cgColor: cg) ?? .black
        #endif
    }
}

// MARK: The view

/// A PDF on an item: find, highlights, quotes, links, the form and Trove's ink, with an export.
struct PDFReaderView: View {
    let item: Item
    let attachment: Attachment
    let data: Data
    /// In the file viewer: fills it, no card.
    var fullScreen = false
    /// Highlights and the form can change (the viewer's view-only mode can only find, select and copy).
    var editable = true
    /// A tap on a page (the inline preview opens the viewer with it).
    var onOpen: (() -> Void)? = nil
    @Environment(AppModel.self) private var model
    @State private var reader: PDFReaderModel
    @State private var exportURL: URL?
    @State private var exporting = false
    @FocusState private var findFocused: Bool

    init(item: Item, attachment: Attachment, data: Data, fullScreen: Bool = false, editable: Bool = true, startPage: Int = 0, onOpen: (() -> Void)? = nil) {
        self.item = item
        self.attachment = attachment
        self.data = data
        self.fullScreen = fullScreen
        self.editable = editable
        self.onOpen = onOpen
        let reader = PDFReaderModel(itemId: item.id, layer: attachment.id, data: data)
        reader.startPage = startPage
        _reader = State(initialValue: reader)
    }

    var body: some View {
        VStack(spacing: 0) {
            bar
            if reader.findOpen { findBar }
            ZStack(alignment: .bottom) {
                PDFReaderRepresentable(reader: reader)
                if !reader.selectedText.isEmpty || reader.openHighlight != nil { selectionBar.padding(10) }
            }
            .frame(minHeight: fullScreen ? nil : 520)
        }
        .background(.background.secondary)
        .clipShape(RoundedRectangle(cornerRadius: fullScreen ? 0 : 14))
        .onAppear {
            reader.onOpen = onOpen
            reader.setFormEditable(editable)
        }
        .onChange(of: editable) { reader.setFormEditable(editable) }
        .task(id: "\(model.inkRevision)-\(model.dataVersion)") {
            if let library = model.library { await reader.refresh(library) }
            reader.setFormEditable(editable)
        }
        .task(id: "\(reader.hasForm)-\(editable)") {
            // PDFKit fills the form in place; changed values are saved as they're made.
            guard reader.hasForm, editable else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.5))
                if let library = model.library, await reader.saveFields(library) { model.inkChanged() }
            }
        }
        .onDisappear {
            guard reader.hasForm, editable, let library = model.library else { return }
            let reader = reader
            Task { _ = await reader.saveFields(library) }
        }
        .sheet(item: $exportURL) { url in ExportSheet(url: url, item: item, attachment: attachment) }
    }

    private var bar: some View {
        HStack(spacing: 10) {
            Text("\(reader.pageCount) page\(reader.pageCount == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button {
                reader.findOpen.toggle()
                if reader.findOpen { findFocused = true } else { reader.closeFind() }
            } label: { Label("Find in PDF", systemImage: "magnifyingglass") }
                .help("Find in PDF")
            Button { Task { await export() } } label: {
                if exporting { ProgressView().controlSize(.small) } else { Label("Export with annotations", systemImage: "square.and.arrow.up.on.square") }
            }
            .disabled(exporting)
            .help("Ink, highlights, text boxes and form values as PDF annotations other apps can edit")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var findBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Find in PDF", text: $reader.query)
                .textFieldStyle(.plain)
                .focused($findFocused)
                .onSubmit { reader.step(1) }
                .onChange(of: reader.query) { reader.runFind() }
            Text(reader.findStatus).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            Button { reader.step(-1) } label: { Image(systemName: "chevron.up") }.accessibilityLabel("Previous")
            Button { reader.step(1) } label: { Image(systemName: "chevron.down") }.accessibilityLabel("Next")
            Button { reader.closeFind() } label: { Image(systemName: "xmark.circle.fill") }.accessibilityLabel("Close find")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.background.tertiary)
    }

    /// Colours, Quote, Copy (and Remove for a highlight that was tapped).
    private var selectionBar: some View {
        let open = reader.openHighlight
        return HStack(spacing: 10) {
            if editable { editingButtons(open) }
            Button { reader.copy(open) } label: { Label("Copy", systemImage: "doc.on.doc") }
            if editable, let open {
                Button(role: .destructive) { Task { await reader.remove(open, model: model) } } label: { Label("Remove", systemImage: "trash") }
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
    }

    /// Highlight colours and Quote (edit mode only).
    @ViewBuilder
    private func editingButtons(_ open: InkElement?) -> some View {
        ForEach(Array(PDFReaderModel.colors.enumerated()), id: \.offset) { i, color in
            Button {
                Task {
                    if let open { await reader.recolor(open, color, model: model) } else { await reader.highlightSelection(color, quote: false, model: model) }
                }
            } label: {
                Circle().fill(Color(inkHex: color)).frame(width: 24, height: 24)
                    .overlay(Circle().strokeBorder(.primary.opacity(open?.color == color ? 0.6 : 0.1), lineWidth: 2))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(open == nil ? "Highlight in \(PDFReaderModel.colorNames[i])" : "Make it \(PDFReaderModel.colorNames[i])")
        }
        Divider().frame(height: 22)
        Button {
            Task {
                if let open { await reader.quote(open, model: model) } else { await reader.highlightSelection(reader.lastColor, quote: true, model: model) }
            }
        } label: { Label("Quote", systemImage: "quote.opening") }
            .help("Highlight it and keep it in Quotes & Highlights")
    }

    private func export() async {
        guard let library = model.library else { return }
        exporting = true
        defer { exporting = false }
        if reader.hasForm { _ = await reader.saveFields(library) }
        let strokes = await library.strokes(on: item.id, layer: attachment.id)
        let elements = await library.elements(on: item.id, layer: attachment.id)
        let data = data
        let out = await Task.detached(priority: .userInitiated) { PDFReaderModel.annotated(data, strokes: strokes, elements: elements) }.value
        guard let out else { model.toast = "Nothing to export yet: draw, highlight or fill in the form first."; return }
        let base = (attachment.name as NSString).deletingPathExtension
        exportURL = TemporaryFile(name: (base.isEmpty ? "Document" : base) + " (annotated).pdf", data: out).url
    }
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}

/// Share the annotated copy, or keep it as the file's new version.
private struct ExportSheet: View {
    let url: URL
    let item: Item
    let attachment: Attachment
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Label(url.lastPathComponent, systemImage: "doc.richtext").font(.headline)
                Text("Ink, highlights, text boxes and form values are real PDF annotations in this copy, so other PDF apps can edit them. Pictures and tape stay in Trove. To flatten instead, open it, press Edit, draw with the pen and use Export PDF.")
                    .font(.callout).foregroundStyle(.secondary)
                ShareLink(item: url) { Label("Share or save…", systemImage: "square.and.arrow.up") }
                    .buttonStyle(.borderedProminent)
                if item.attachments.first?.id == attachment.id {
                    Button {
                        Task {
                            await model.replaceFile(item, with: url)
                            dismiss()
                        }
                    } label: { Label("Save as a new version", systemImage: "square.and.arrow.down.on.square") }
                        .buttonStyle(.bordered)
                    Text("The current file is kept under Versions. Like any new version, it starts without Trove's ink; the old version keeps it.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)
            .navigationTitle("Export with annotations")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
        .frame(minWidth: 380, minHeight: 300)
    }
}

// MARK: PDFKit in SwiftUI

#if os(iOS)
struct PDFReaderRepresentable: UIViewRepresentable {
    let reader: PDFReaderModel

    func makeCoordinator() -> PDFReaderCoordinator { PDFReaderCoordinator(reader: reader) }

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.document = reader.document
        reader.view = view
        if reader.startPage > 0, let page = reader.document?.page(at: reader.startPage) { view.go(to: page) }
        context.coordinator.observe(view)
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(PDFReaderCoordinator.tap(_:)))
        tap.delegate = context.coordinator
        tap.cancelsTouchesInView = false
        view.addGestureRecognizer(tap)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {}
}

@MainActor
final class PDFReaderCoordinator: NSObject, UIGestureRecognizerDelegate {
    let reader: PDFReaderModel
    init(reader: PDFReaderModel) { self.reader = reader }

    func observe(_ view: PDFView) {
        NotificationCenter.default.addObserver(self, selector: #selector(selectionChanged), name: .PDFViewSelectionChanged, object: view)
    }

    @objc func selectionChanged(_ note: Notification) { reader.selectionChanged() }

    @objc func tap(_ g: UITapGestureRecognizer) {
        guard let view = g.view else { return }
        reader.tapped(at: g.location(in: view))
    }

    nonisolated func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}
#else
struct PDFReaderRepresentable: NSViewRepresentable {
    let reader: PDFReaderModel

    func makeCoordinator() -> PDFReaderCoordinator { PDFReaderCoordinator(reader: reader) }

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.document = reader.document
        reader.view = view
        if reader.startPage > 0, let page = reader.document?.page(at: reader.startPage) { view.go(to: page) }
        context.coordinator.observe(view)
        let click = NSClickGestureRecognizer(target: context.coordinator, action: #selector(PDFReaderCoordinator.click(_:)))
        click.delaysPrimaryMouseButtonEvents = false
        view.addGestureRecognizer(click)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {}
}

@MainActor
final class PDFReaderCoordinator: NSObject {
    let reader: PDFReaderModel
    init(reader: PDFReaderModel) { self.reader = reader }

    func observe(_ view: PDFView) {
        NotificationCenter.default.addObserver(self, selector: #selector(selectionChanged), name: .PDFViewSelectionChanged, object: view)
    }

    @objc func selectionChanged(_ note: Notification) { reader.selectionChanged() }

    @objc func click(_ g: NSClickGestureRecognizer) {
        guard let view = g.view else { return }
        reader.tapped(at: g.location(in: view))
    }
}
#endif
