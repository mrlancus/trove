import SwiftUI
import TroveCore

/// Ask inside a notebook, sketch or board (docs/MASTER_PLAN.md G14): normal questions, fact
/// checks, revision (it asks you, one question at a time), finding things (highlighted on the
/// page) and diagrams (a preview first: Keep, Remove or Tweak). Grounded in the notebook's own
/// text; each later question in a session pays about a tenth for the notebook (cached).
@MainActor
@Observable
final class StudyPanelModel {
    struct Entry: Identifiable {
        let id = UUID()
        var question: String
        var answer: String
        var refs: [StudyContext.Ref]
        var unverified: [String]
    }

    let editor: InkEditorModel
    var entries: [Entry] = []
    var input = ""
    var busy = false
    var status: String?
    var error: String?
    /// Nothing saved, no summary written or read (like a temporary chat in Claude or ChatGPT).
    var temporary = false
    var usage = AIUsage.Total()
    /// A diagram waiting for Keep / Remove / Tweak.
    var preview: DiagramSpec?
    var tweak = ""
    private var turns: [StudyTurn] = []
    private var context: StudyContext?
    /// Where each line of each page is (page key → line boxes), for highlighting.
    private var lineBoxes: [String: [InkGeometry.Rect?]] = [:]

    init(editor: InkEditorModel) { self.editor = editor }

    static var memory: StudyMemory {
        StudyMemory(directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Trove/sessions", isDirectory: true))
    }

    static var memoryOn: Bool {
        get { UserDefaults.standard.object(forKey: "study.memory") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "study.memory") }
    }

    var ready: Bool { editor.app?.ownAI != nil }

    /// Reads any pages whose handwriting changed (Vision, on the device), then puts together what
    /// the chat sees: every page's lines, handwriting first, then its text boxes.
    func prepare() async {
        guard let library = editor.app?.library else { return }
        status = "Reading your pages…"
        defer { status = nil }
        if editor.isSketch {
            let fast = editor.app?.policy.recognition == .fast
            _ = await Handwriting.read(editor.target.itemId, library: library, fast: fast)
        }
        let known = await HandwritingPages.shared.pages(of: editor.target.itemId)
        var pages: [StudyContext.Page] = []
        var boxes: [String: [InkGeometry.Rect?]] = [:]
        for (i, spec) in editor.pages.enumerated() {
            var lines: [String] = []
            var rects: [InkGeometry.Rect?] = []
            if let page = known[spec.key] {
                let textLines = page.text.split(separator: "\n", omittingEmptySubsequences: true).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                for (li, line) in textLines.enumerated() {
                    lines.append(line)
                    if let b = page.lines, li < b.count, b[li].count == 4 {
                        rects.append(InkGeometry.Rect(x: b[li][0], y: b[li][1], width: b[li][2], height: b[li][3]))
                    } else {
                        rects.append(nil)
                    }
                }
            }
            for box in editor.content[spec.key]?.elements ?? [] where box.kind == .text && !box.text.isEmpty {
                for line in box.text.split(separator: "\n") where !line.trimmingCharacters(in: .whitespaces).isEmpty {
                    lines.append(String(line))
                    rects.append(box.frame)
                }
            }
            pages.append(StudyContext.Page(key: spec.key, label: "Page \(i + 1)", text: lines.joined(separator: "\n")))
            boxes[spec.key] = rects
        }
        // A PDF or picture with no page-by-page text: what the whole file says.
        if pages.allSatisfy({ $0.lines.isEmpty }), let item = await library.item(editor.target.itemId) {
            let text = [item.body, item.ocrText ?? "", item.inkText ?? "", item.sketchText ?? ""].filter { !$0.isEmpty }.joined(separator: "\n")
            pages = [StudyContext.Page(key: editor.pages.first?.key ?? "0", label: "The whole document", text: text)]
            boxes = [:]
        }
        context = StudyContext(title: editor.target.title, pages: pages)
        lineBoxes = boxes
    }

    func send(_ question: String, maxTokens: Int = 700) async {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !busy else { return }
        guard let ai = editor.app?.ownAI else { error = "Add your AI in Settings → AI first."; return }
        input = ""
        busy = true
        error = nil
        defer { busy = false }
        if context == nil { await prepare() }
        guard let context else { return }
        if context.pages.allSatisfy({ $0.lines.isEmpty }) {
            error = "There's nothing readable in this notebook yet."
            return
        }
        let summary = temporary || !Self.memoryOn ? nil : (turns.isEmpty ? Self.memory.summary(for: editor.target.itemId) : nil)
        do {
            let answer = try await ai.studyReply(q, context: context, history: turns, summary: summary, maxTokens: maxTokens)
            if let u = answer.usage { usage.add(u) }
            turns.append(StudyTurn(question: q, answer: answer.text))
            entries.append(Entry(question: q, answer: answer.display(context: context), refs: answer.refs, unverified: answer.unverified))
            if let d = answer.diagram { preview = d }
            if !answer.refs.isEmpty { show(answer.refs) }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func run(_ shortcut: StudyShortcut) async {
        await send(shortcut.prompt(input), maxTokens: shortcut.maxTokens)
    }

    /// Marks cited lines on their pages and goes to the first.
    func show(_ refs: [StudyContext.Ref]) {
        var rects: [String: [InkGeometry.Rect]] = [:]
        for r in refs {
            if let box = lineBoxes[r.pageKey].flatMap({ r.line < $0.count ? $0[r.line] : nil }) {
                rects[r.pageKey, default: []].append(box)
            }
        }
        editor.highlight(rects, goTo: refs.first?.pageKey)
    }

    func clearHighlights() { editor.highlight([:], goTo: nil) }

    // MARK: Diagrams

    /// Puts the previewed diagram on the page as real shapes and text (one undo step each).
    func keepDiagram() async {
        guard let spec = preview, let library = editor.app?.library, let page = editor.currentPage else { return }
        preview = nil
        let origin = page.infinite ? InkPoint(x: editor.visibleCenter.x - 200, y: editor.visibleCenter.y - 120) : InkPoint(x: 48, y: 72)
        let layout = spec.layout(origin: origin, fontSize: 16)
        let color = editor.color(for: .pen)
        let item = editor.target.itemId, layer = editor.target.layer, key = page.key
        for box in layout.boxes {
            let f = box.frame
            let corners = [InkPoint(x: f.x, y: f.y), InkPoint(x: f.maxX, y: f.y), InkPoint(x: f.maxX, y: f.maxY), InkPoint(x: f.x, y: f.maxY), InkPoint(x: f.x, y: f.y)]
            _ = await library.addStroke(on: item, layer: layer, pageKey: key, tool: .pen, color: color, width: 1.5, points: corners, shape: "rectangle")
            _ = await library.addElement(on: item, layer: layer, pageKey: key, kind: .text,
                                         frame: InkGeometry.Rect(x: f.x + 8, y: f.y + f.height / 2 - 11, width: f.width - 16, height: 22),
                                         text: box.label, size: 15, color: color, textStyle: InkTextStyle())
        }
        for arrow in layout.arrows {
            _ = await library.addStroke(on: item, layer: layer, pageKey: key, tool: .pen, color: color, width: 1.5,
                                        points: [arrow.from, arrow.to], shape: "line", style: InkStrokeStyle(arrow: "end"))
        }
        if let title = spec.title, !title.isEmpty {
            _ = await library.addElement(on: item, layer: layer, pageKey: key, kind: .text,
                                         frame: InkGeometry.Rect(x: origin.x, y: origin.y - 34, width: max(200, layout.size.width), height: 26),
                                         text: title, size: 18, color: color, textStyle: InkTextStyle())
        }
        await editor.reloadInk()
        editor.app?.inkChanged()
    }

    func removeDiagram() { preview = nil; tweak = "" }

    func tweakDiagram() async {
        guard let spec = preview, let ai = editor.app?.ownAI else { return }
        let instruction = tweak.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty else { return }
        busy = true
        defer { busy = false }
        do {
            preview = try await ai.tweakDiagram(spec, instruction: instruction)
            tweak = ""
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: Ending

    /// Squeezes the session into the notebook's summary on this device (unless temporary or off).
    func endSession() async {
        clearHighlights()
        guard !temporary, Self.memoryOn, !turns.isEmpty, let ai = editor.app?.ownAI else { return }
        let id = editor.target.itemId, title = editor.target.title
        let previous = Self.memory.summary(for: id)
        if let summary = try? await ai.summariseSession(turns, notebook: title, previous: previous) {
            try? Self.memory.save(summary, for: id, title: title)
        }
    }
}

struct StudyPanel: View {
    @State var model: StudyPanelModel
    @Environment(\.dismiss) private var dismiss

    init(editor: InkEditorModel) { _model = State(initialValue: StudyPanelModel(editor: editor)) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if !model.ready {
                ContentUnavailableView("Add your AI", systemImage: "key", description: Text("Ask about this notebook with your own AI: Settings → AI. About 1–2p for a 30-minute revision session on the fast model."))
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            if model.entries.isEmpty { intro }
                            ForEach(model.entries) { entry in
                                EntryView(entry: entry) { model.show(entry.refs) }.id(entry.id)
                            }
                            if let spec = model.preview { DiagramPreview(model: model, spec: spec) }
                            if let status = model.status ?? (model.busy ? "Thinking…" : nil) {
                                Label(status, systemImage: "ellipsis").foregroundStyle(.secondary).font(.callout)
                            }
                            if let error = model.error { Text(error).foregroundStyle(.red).font(.callout) }
                        }
                        .padding(14)
                    }
                    .onChange(of: model.entries.count) { if let last = model.entries.last { withAnimation { proxy.scrollTo(last.id, anchor: .top) } } }
                }
                Divider()
                shortcuts
                composer
            }
        }
        .task { if model.ready { await model.prepare() } }
        .onDisappear { Task { await model.endSession() } }
    }

    private var header: some View {
        HStack {
            Text("Ask this notebook").font(.headline)
            Spacer()
            if model.usage.calls > 0 {
                Text(model.usage.cost < 0.01 ? "<1p" : String(format: "%.1fp", model.usage.cost * 100)).font(.caption).foregroundStyle(.secondary)
                    .help("What this session has cost so far")
            }
            Toggle(isOn: $model.temporary) { Image(systemName: model.temporary ? "eye.slash" : "clock.arrow.circlepath") }
                .toggleStyle(.button)
                .help(model.temporary ? "Temporary chat: nothing is saved" : "Saves a short summary on this device for next time (tap for a temporary chat)")
        }
        .padding(12)
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Ask anything about this notebook, check a fact, or say \"quiz me\".").font(.callout)
            Text("Answers come only from your notes, with the lines they're from. When it isn't in your notes, it says so.")
                .font(.caption).foregroundStyle(.secondary)
            if model.temporary { Text("Temporary chat: nothing will be saved.").font(.caption).foregroundStyle(.secondary) }
        }
    }

    private var shortcuts: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach([StudyShortcut.quiz, .weakSpots, .explain, .exam, .factCheck, .find, .diagram, .summarise], id: \.self) { s in
                    Button(s.label) { Task { await model.run(s) } }
                        .buttonStyle(.bordered).controlSize(.small)
                        .disabled(model.busy)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
    }

    private var composer: some View {
        HStack(spacing: 8) {
            TextField("Ask, answer, or say what to find…", text: $model.input, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)
                .onSubmit { Task { await model.send(model.input) } }
            Button { Task { await model.send(model.input) } } label: { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                .buttonStyle(.plain)
                .disabled(model.busy || model.input.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(12)
    }
}

private struct EntryView: View {
    let entry: StudyPanelModel.Entry
    let showPlaces: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(entry.question).font(.callout.weight(.medium))
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Brand.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
            Text(LocalizedStringKey(entry.answer)).font(.callout).textSelection(.enabled)
            HStack(spacing: 10) {
                if !entry.refs.isEmpty {
                    Button(entry.refs.count == 1 ? "Show on the page" : "Show \(entry.refs.count) places", action: showPlaces)
                        .font(.caption).buttonStyle(.borderless)
                }
                if !entry.unverified.isEmpty {
                    Label("Couldn't verify \(entry.unverified.count) reference\(entry.unverified.count == 1 ? "" : "s")", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
        }
    }
}

/// A diagram drawn faintly first, with Keep, Remove and a box to say what to change.
private struct DiagramPreview: View {
    @Bindable var model: StudyPanelModel
    let spec: DiagramSpec

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(spec.title ?? "Diagram").font(.callout.weight(.semibold))
            let layout = spec.layout(fontSize: 12)
            Canvas { ctx, size in
                let scale = min(1, size.width / max(1, layout.size.width + 8))
                ctx.scaleBy(x: scale, y: scale)
                let minX = layout.boxes.map(\.frame.x).min() ?? 0, minY = layout.boxes.map(\.frame.y).min() ?? 0
                ctx.translateBy(x: 4 - minX, y: 4 - minY)
                for a in layout.arrows {
                    var p = Path()
                    p.move(to: CGPoint(x: a.from.x, y: a.from.y))
                    p.addLine(to: CGPoint(x: a.to.x, y: a.to.y))
                    ctx.stroke(p, with: .color(.secondary), lineWidth: 1.2)
                    let angle = atan2(a.to.y - a.from.y, a.to.x - a.from.x)
                    var head = Path()
                    head.move(to: CGPoint(x: a.to.x, y: a.to.y))
                    head.addLine(to: CGPoint(x: a.to.x - 8 * cos(angle - 0.4), y: a.to.y - 8 * sin(angle - 0.4)))
                    head.move(to: CGPoint(x: a.to.x, y: a.to.y))
                    head.addLine(to: CGPoint(x: a.to.x - 8 * cos(angle + 0.4), y: a.to.y - 8 * sin(angle + 0.4)))
                    ctx.stroke(head, with: .color(.secondary), lineWidth: 1.2)
                }
                for b in layout.boxes {
                    let r = CGRect(x: b.frame.x, y: b.frame.y, width: b.frame.width, height: b.frame.height)
                    ctx.stroke(Path(roundedRect: r, cornerRadius: 6), with: .color(.primary.opacity(0.6)), lineWidth: 1)
                    ctx.draw(Text(b.label).font(.system(size: 11)), in: r.insetBy(dx: 4, dy: 4))
                }
            }
            .frame(height: min(260, max(80, layout.size.height + 12)))
            .opacity(0.75)
            HStack {
                Button("Keep") { Task { await model.keepDiagram() } }.buttonStyle(.borderedProminent)
                Button("Remove", role: .destructive) { model.removeDiagram() }.buttonStyle(.bordered)
            }
            HStack {
                TextField("Tweak it: \"arrows left to right\", \"add ATP\"…", text: $model.tweak)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await model.tweakDiagram() } }
                Button("Tweak") { Task { await model.tweakDiagram() } }
                    .disabled(model.busy || model.tweak.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(10)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }
}
