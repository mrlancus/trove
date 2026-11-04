import PDFKit
import SwiftUI
import TroveCore
#if os(iOS)
import PencilKit
#endif

/// Develop's home (docs/DEVELOP_PLAN.md §E): what to do next in one card, then papers, skills and
/// review. iPad and Mac: the sidebar's Develop; iPhone: the Practise tab.
struct DevelopView: View {
    @Environment(AppModel.self) private var model
    @State private var develop = DevelopModel.shared
    @State private var anki: URL?
    @State private var addingGoal = false

    var body: some View { perfBody.perfWorkflow("Develop") }

    @ViewBuilder private var perfBody: some View {
        Group {
            if develop.session != nil {
                PracticeView(develop: develop)
            } else {
                home
            }
        }
        .navigationTitle("Develop")
        .tint(Theme.accent)
        .task {
            await develop.start(model)
            Diagnostics.shared.ready("Develop")
        }
        .onChange(of: model.dataVersion) { _, _ in Task { await develop.reload() } }
    }

    private var home: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                nextCard
                if let message = develop.message {
                    Text(message).font(.callout).foregroundStyle(.secondary)
                }
                goals
                papers
                skillsList
                if !develop.toReview.isEmpty { review }
                more
            }
            .padding(Theme.Space.xl)
            .frame(maxWidth: Theme.readingWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private var nextCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let next = develop.next, !develop.practisable.isEmpty {
                Text("Next").font(.caption).foregroundStyle(.secondary)
                Text(next.skill.name).font(.title2.weight(.semibold))
                Text(next.why).font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button("Start 3 questions") { develop.startSession(count: 3, skill: next.skill.id) }
                        .buttonStyle(.borderedProminent)
                    Button("Practise anything") { develop.startSession(count: 5) }
                        .buttonStyle(.bordered)
                }
            } else {
                Text("Practise with real papers").font(.title3.weight(.semibold))
                Text("Download AQA A-level Physics papers from AQA's own website onto this device, split them into questions, then practise. Mark yourself against the mark scheme, or with your AI if you want.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(cornerRadius: Theme.Radius.large)
    }

    /// Preparation goals: readiness in a sentence, and the next days' plan.
    private var goals: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Goals").font(.headline)
                Spacer()
                Button { addingGoal = true } label: { Label("Prepare for…", systemImage: "flag") }.buttonStyle(.bordered).controlSize(.small)
            }
            if develop.goals.isEmpty {
                Text("Add an exam or a competition with its date: Trove plans what to practise each day from what you've shown so far.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(develop.goals, id: \.id) { goal in
                let plan = develop.plan(goal)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(goal.name).font(.subheadline.weight(.semibold))
                        Spacer()
                        Text(Date(timeIntervalSince1970: goal.deadline / 1000), style: .date).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(plan.why).font(.caption).foregroundStyle(.secondary)
                    ForEach(Array(plan.days.prefix(3).enumerated()), id: \.offset) { i, day in
                        Text("\(i == 0 ? "Today" : i == 1 ? "Tomorrow" : Date(timeIntervalSince1970: day.date / 1000).formatted(.dateTime.weekday(.wide))): "
                             + (day.skills.isEmpty ? "nothing new needed" : day.skills.map(develop.name).joined(separator: ", "))
                             + (day.diagnostic ? " (first check)" : ""))
                            .font(.caption)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(cornerRadius: Theme.Radius.large)
        .sheet(isPresented: $addingGoal) { GoalSheet(develop: develop) }
    }

    private var papers: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Papers").font(.headline)
            if let spec = develop.spec {
                let have = spec.docs.filter { develop.cached.contains($0.id) }.count
                LabeledContent("\(spec.qualification) \(spec.subject) (AQA \(spec.code))", value: "\(have) of \(spec.docs.count) on this device")
                HStack {
                    if let d = develop.downloading {
                        ProgressView(value: Double(d.done), total: Double(max(1, d.total)))
                            .frame(maxWidth: 200)
                        Text("\(d.done) of \(d.total)").font(.caption).monospacedDigit()
                        Button("Cancel") { develop.cancelDownload() }
                    } else {
                        Button(have == spec.docs.count ? "Check for missing papers" : "Download papers (Wi-Fi)") { develop.download() }
                        Button(develop.splitting ? "Splitting…" : "Split into questions") { Task { await develop.splitAll() } }
                            .disabled(develop.splitting || have == 0)
                    }
                }
                .buttonStyle(.bordered)
                Text("\(develop.practisable.count) questions ready. Papers stay on this device and never sync; only your attempts do.")
                    .font(.caption).foregroundStyle(.secondary)
                if !develop.myPDFs.isEmpty {
                    Menu {
                        ForEach(develop.myPDFs.prefix(40)) { item in
                            Button(item.displayTitle) { Task { await develop.split(item: item) } }
                        }
                    } label: { Label("Practise from one of my PDFs…", systemImage: "doc.text.magnifyingglass") }
                    .disabled(develop.splitting)
                }
            } else {
                Text("The paper catalogue isn't in this build.").font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(cornerRadius: Theme.Radius.large)
    }

    private var skillsList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Skills").font(.headline)
            ForEach(develop.concepts.filter { $0.type == .skill && $0.mergedInto == nil }.sorted { $0.name < $1.name }) { c in
                let s = develop.skills[c.id]
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(c.name)
                        Spacer()
                        if let m = s?.mastery { Text("\(Int((m * 100).rounded())) %").monospacedDigit().foregroundStyle(.secondary) }
                        if s?.proficient == true { Image(systemName: "checkmark.seal.fill").foregroundStyle(.green).accessibilityLabel("Proficient") }
                    }
                    Text(s?.why ?? "Not assessed yet.").font(.caption).foregroundStyle(.secondary)
                    if let brier = s?.brier() {
                        // Calibration (DEVELOP_PLAN §B3 point 3): 0.25 is guessing; lower means the model predicts you well.
                        Text("Predictions: Brier \(String(format: "%.2f", brier))\(brier > 0.25 ? " (worse than guessing: tell me)" : "")")
                            .font(.caption2).foregroundStyle(brier > 0.25 ? .orange : .secondary)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(cornerRadius: Theme.Radius.large)
    }

    private var review: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("To review").font(.headline)
            Text("AI marks it wasn't sure of. They count for nothing until you confirm them.").font(.caption).foregroundStyle(.secondary)
            ForEach(develop.toReview) { a in
                HStack {
                    Text(a.label.isEmpty ? "An attempt" : a.label).lineLimit(1)
                    Spacer()
                    Text(a.score.map { "\(Int(($0 * 100).rounded())) %" } ?? "–").monospacedDigit()
                    Button("Confirm") { Task { await develop.confirm(a, score: a.score ?? 0) } }.buttonStyle(.bordered)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(cornerRadius: Theme.Radius.large)
    }

    private var more: some View {
        HStack {
            if let anki {
                ShareLink(item: anki) { Label("Share cards for Anki", systemImage: "square.and.arrow.up") }
            } else {
                Button { Task { anki = await develop.ankiFile() } } label: { Label("Export cards for Anki (.apkg)", systemImage: "rectangle.stack") }
            }
        }
        .buttonStyle(.bordered)
    }
}

/// One question at a time: the original page (diagrams included), the answer, then marking.
struct PracticeView: View {
    let develop: DevelopModel
    @State private var answer = ""
    @State private var showSource = false
    @State private var marking = false
    @State private var ticked: Set<Int> = []
    @State private var aiResult: DevelopMarking.Result?
    @State private var working = false
    @State private var error: String?
    @State private var picture: CGImage?
    @State private var done: String?
    @State private var hints: [String] = []
    @State private var writing = DeviceInfo.isPad
    #if os(iOS)
    @State private var drawing = PKDrawing()
    #endif

    var body: some View {
        if let p = develop.session?.current {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("Question \((develop.session?.at ?? 0) + 1) of \(develop.session?.problems.count ?? 0)").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button { showSource.toggle() } label: { Image(systemName: "info.circle") }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(showSource ? "Hide where it's from" : "Show where it's from")
                        Button("End") { develop.session = nil }
                    }
                    if showSource { Text(p.label).font(.callout).foregroundStyle(.secondary) }
                    questionPicture(p)
                    if let marks = p.marks { Text("\(marks) mark\(marks == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary) }
                    if let done {
                        Text(done).font(.headline)
                        Button("Next question") { reset(); develop.advance() }.buttonStyle(.borderedProminent)
                    } else if marking {
                        schemeChecklist(p)
                    } else {
                        ForEach(Array(hints.enumerated()), id: \.offset) { i, h in
                            Label { Text(h).font(.callout) } icon: { Text("\(i + 1)").font(.caption.bold()).foregroundStyle(Theme.accent) }
                                .padding(10).frame(maxWidth: .infinity, alignment: .leading).card(cornerRadius: Theme.Radius.small)
                        }
                        HStack {
                            Text("Your answer").font(.headline)
                            Spacer()
                            #if os(iOS)
                            Picker("Answer by", selection: $writing) {
                                Image(systemName: "keyboard").tag(false).accessibilityLabel("Type")
                                Image(systemName: "pencil.tip").tag(true).accessibilityLabel("Write")
                            }
                            .pickerStyle(.segmented).frame(width: 110)
                            #endif
                        }
                        #if os(iOS)
                        if writing {
                            AnswerCanvas(drawing: $drawing)
                                .frame(minHeight: 320)
                                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.small).stroke(.secondary.opacity(0.3)))
                        } else {
                            typedAnswer
                        }
                        #else
                        typedAnswer
                        #endif
                        HStack {
                            Button("Show mark scheme") { marking = true }.buttonStyle(.borderedProminent)
                            Button(working ? "Marking…" : "Mark with AI") { Task { await markWithAI(p) } }
                                .buttonStyle(.bordered).disabled(working || !hasAnswer)
                            if hints.count < DevelopHints.levels.count {
                                Button(hints.isEmpty ? "Hint" : "Another hint") { Task { await nextHint(p) } }
                                    .buttonStyle(.bordered).disabled(working)
                            }
                            Spacer()
                            Button("Skip") { Task { await develop.record(p, score: nil, marking: .none, hint: hints.count); done = "Kept, but it counts as no evidence." } }
                        }
                    }
                    if let aiResult { aiResultView(aiResult) }
                    if let error { Text(error).font(.callout).foregroundStyle(.red) }
                }
                .padding(20)
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .task(id: p.id) { picture = await render(p) }
        }
    }

    @ViewBuilder private func questionPicture(_ p: Problem) -> some View {
        if let picture {
            Image(decorative: picture, scale: 2)
                .resizable().scaledToFit()
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            Text(develop.text(of: p)).font(.body).textSelection(.enabled)
        }
    }

    private func render(_ p: Problem) async -> CGImage? {
        guard let region = p.pages.first, let data = await develop.pdfData(p) else { return nil }
        return await Task.detached(priority: .userInitiated) {
            guard let pdf = PDFDocument(data: data) else { return nil }
            return PaperPDF.image(pdf, region)
        }.value
    }

    @ViewBuilder private func schemeChecklist(_ p: Problem) -> some View {
        let scheme = develop.scheme(of: p)
        let points = DevelopMarking.points(fromScheme: scheme ?? "")
        VStack(alignment: .leading, spacing: 8) {
            Text("Mark scheme").font(.headline)
            if points.isEmpty {
                Text("No mark scheme entry was found for this question. Mark it out of \(p.marks ?? 1) yourself:").font(.callout)
                Stepper("\(ticked.count) of \(p.marks ?? 1) marks", value: Binding(get: { ticked.count }, set: { n in ticked = Set(0..<max(0, n)) }),
                        in: 0...(p.marks ?? 1))
            } else {
                Text("Tick each point you earned.").font(.caption).foregroundStyle(.secondary)
                ForEach(points) { point in
                    Toggle(isOn: Binding(get: { ticked.contains(point.id) }, set: { on in if on { ticked.insert(point.id) } else { ticked.remove(point.id) } })) {
                        Text(point.text).font(.callout)
                    }
                    #if os(macOS)
                    .toggleStyle(.checkbox)
                    #endif
                }
            }
            Button("Done") {
                let score = DevelopMarking.selfMarkScore(ticked: ticked.count, marks: p.marks, points: points.count)
                Task {
                    await develop.record(p, score: score, marking: .selfMarked, hint: hints.count)
                    done = "\(min(ticked.count, p.marks ?? ticked.count)) / \(p.marks ?? max(1, points.count)) · counted as self-marked against the mark scheme"
                }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func aiResultView(_ r: DevelopMarking.Result) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(r.marking == .aiScheme ? "AI marked against the mark scheme" : "AI marked without a mark scheme (lower confidence)")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(Array(r.awarded.enumerated()), id: \.offset) { _, a in
                Label {
                    VStack(alignment: .leading) {
                        Text(a.point).font(.callout)
                        if !a.why.isEmpty { Text(a.why).font(.caption).foregroundStyle(.secondary) }
                    }
                } icon: { Image(systemName: a.got ? "checkmark.circle.fill" : "xmark.circle").foregroundStyle(a.got ? .green : .secondary) }
            }
            if !r.rationale.isEmpty { Text(r.rationale).font(.caption).foregroundStyle(.secondary) }
            if r.uncertain { Text("Not sure of this mark: it goes to review and counts for nothing until you confirm it.").font(.caption).foregroundStyle(.orange) }
        }
        .padding(12)
        .card(cornerRadius: Theme.Radius.medium)
    }

    private var typedAnswer: some View {
        TextEditor(text: $answer)
            .frame(minHeight: 140)
            .padding(6)
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.small).stroke(.secondary.opacity(0.3)))
    }

    private var hasAnswer: Bool {
        #if os(iOS)
        if writing { return !drawing.strokes.isEmpty }
        #endif
        return !answer.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// The handwritten answer as a JPEG (white page, 2× scale), only when writing.
    private var answerImage: Data? {
        #if os(iOS)
        guard writing, !drawing.strokes.isEmpty else { return nil }
        let bounds = drawing.bounds.insetBy(dx: -12, dy: -12)
        let ink = drawing.image(from: bounds, scale: 2)
        let renderer = UIGraphicsImageRenderer(size: bounds.size)
        let page = renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: bounds.size))
            ink.draw(in: CGRect(origin: .zero, size: bounds.size))
        }
        return page.jpegData(compressionQuality: 0.8)
        #else
        return nil
        #endif
    }

    private func nextHint(_ p: Problem) async {
        working = true
        defer { working = false }
        do {
            hints.append(try await develop.hint(p, level: hints.count + 1, workSoFar: answer, earlier: hints))
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func markWithAI(_ p: Problem) async {
        working = true
        defer { working = false }
        do {
            let r = try await develop.markWithAI(p, answer: answer, image: answerImage)
            aiResult = r
            await develop.record(p, score: r.score, marking: r.marking, hint: hints.count, uncertain: r.uncertain)
            done = "\(Int((r.score * 100).rounded())) % · \(r.marking == .aiScheme ? "AI-marked against the mark scheme" : "AI-marked without one")"
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func reset() {
        answer = ""; showSource = false; marking = false; ticked = []; aiResult = nil; error = nil; picture = nil; done = nil; hints = []
        #if os(iOS)
        drawing = PKDrawing()
        #endif
    }
}

/// An item's concepts (docs/DEVELOP_PLAN.md §B3 point 1): suggested from its text on this device (no
/// AI), each accepted or rejected in place; a rejection sticks.
struct ItemConceptsSection: View {
    let item: Item
    @Environment(AppModel.self) private var model
    @State private var accepted: [Concept] = []
    @State private var suggested: [Concept] = []

    var body: some View {
        Group {
            if !accepted.isEmpty || !suggested.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Concepts").font(.headline)
                    FlowRow {
                        ForEach(accepted) { c in
                            Label(c.name, systemImage: "graduationcap").font(.callout)
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(.tint.opacity(0.12), in: Capsule())
                        }
                    }
                    ForEach(suggested) { c in
                        HStack {
                            Text("About \(c.name)?").font(.callout)
                            Spacer()
                            Button { Task { await set(c, .accepted) } } label: { Image(systemName: "checkmark") }.accessibilityLabel("Yes, it's about \(c.name)")
                            Button { Task { await set(c, .rejected) } } label: { Image(systemName: "xmark") }.accessibilityLabel("No")
                        }
                        .buttonStyle(.bordered).controlSize(.small)
                    }
                }
            }
        }
        .task(id: "\(item.id)|\(model.dataVersion)") { await load() }
    }

    private func load() async {
        guard let library = model.library else { return }
        let concepts = await library.concepts()
        let index = EdgeIndex(edges: await library.edges(), concepts: concepts)
        let byId = Dictionary(concepts.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let mine = index.from(item.id, type: .about)
        accepted = mine.filter { $0.state == .accepted }.compactMap { byId[index.resolve($0.to)] }
        let text = item.displayTitle + "\n" + item.body + "\n" + (item.ocrText ?? "")
        let linked = Set(mine.map(\.to))
        let found = await Task.detached(priority: .utility) { ConceptMatch.mentioned(in: text, concepts: concepts) }.value
        suggested = found.filter { !linked.contains($0) && !index.isRejected(from: item.id, type: .about, to: $0) }.prefix(3).compactMap { byId[$0] }
    }

    private func set(_ c: Concept, _ state: EdgeState) async {
        guard let library = model.library else { return }
        await library.setEdge(from: item.id, to: c.id, type: .about, state: state, origin: .user)
        await load()
    }
}

#if os(iOS)
/// The answer pad: PencilKit, the Pencil or a finger, a black pen (docs/DEVELOP_PLAN.md §E).
struct AnswerCanvas: UIViewRepresentable {
    @Binding var drawing: PKDrawing

    func makeUIView(context: Context) -> PKCanvasView {
        let view = PKCanvasView()
        view.drawingPolicy = .anyInput
        view.tool = PKInkingTool(.pen, color: .black, width: 3)
        view.backgroundColor = .white
        view.overrideUserInterfaceStyle = .light
        view.drawing = drawing
        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ view: PKCanvasView, context: Context) {
        if view.drawing != drawing { view.drawing = drawing }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        let parent: AnswerCanvas
        init(_ parent: AnswerCanvas) { self.parent = parent }
        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            let d = canvasView.drawing
            MainActor.assumeIsolated { parent.drawing = d }
        }
    }
}
#endif

/// Adding a goal: a name, a date, how long a day.
struct GoalSheet: View {
    let develop: DevelopModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var date = Date().addingTimeInterval(14 * 86_400)
    @State private var minutes = 30

    var body: some View {
        NavigationStack {
            Form {
                TextField("Goal (e.g. AQA Physics Paper 1)", text: $name)
                DatePicker("Date", selection: $date, in: Date()..., displayedComponents: .date)
                Stepper("\(minutes) minutes a day", value: $minutes, in: 10...180, step: 10)
            }
            .navigationTitle("Prepare for…")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { Task { await develop.addGoal(name: name, deadline: date, minutesPerDay: minutes); dismiss() } }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 260)
        #endif
    }
}
