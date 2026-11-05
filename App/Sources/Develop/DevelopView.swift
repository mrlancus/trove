import PDFKit
import SwiftUI
import TroveCore

/// Develop's home (docs/DEVELOP_PLAN.md §E): what to do next in one card, then papers, skills and
/// review. iPad and Mac: the sidebar's Develop; iPhone: the Practise tab.
struct DevelopView: View {
    @Environment(AppModel.self) private var model
    @State private var develop = DevelopModel.shared
    @State private var anki: URL?

    var body: some View { perfBody.perfWorkflow("Develop") }

    @ViewBuilder private var perfBody: some View {
        Group {
            if develop.session != nil {
                PracticeView(develop: develop)
            } else {
                home
            }
        }
        .navigationTitle("Learn")
        .tint(Theme.accent)
        .task {
            await develop.start(model)
            Diagnostics.shared.ready("Develop")
        }
        .onChange(of: model.dataVersion) { _, _ in Task { await develop.reload(); await develop.syncPapers() } }
    }

    private var home: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                nextCard
                if let message = develop.message {
                    Label(message, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
                }
                if !develop.attempts.isEmpty { statsStrip }
                YourWorkCard(develop: develop)
                CoursesCard(develop: develop)
                GoalsCard(develop: develop)
                UploadsCard(develop: develop)
                if develop.concepts.contains(where: { $0.type == .skill }) { skillsList }
                if !develop.toReview.isEmpty { review }
                more
            }
            .padding(Theme.Space.xl)
            .frame(maxWidth: Theme.readingWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    /// The one thing to do next, large, in Trove's colours.
    private var nextCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            if let next = develop.next, !develop.practisable.isEmpty {
                Label("Up next", systemImage: "sparkle").font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.85))
                Text(next.skill.name).font(.largeTitle.weight(.bold)).foregroundStyle(.white).lineLimit(2).minimumScaleFactor(0.7)
                Text(next.why).font(.callout).foregroundStyle(.white.opacity(0.9)).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: Theme.Space.s) {
                    Button { develop.startSession(count: 3, skill: next.skill.id) } label: {
                        Label("Start 3 questions", systemImage: "play.fill").font(.body.weight(.semibold)).padding(.horizontal, 6)
                    }
                    .buttonStyle(.borderedProminent).tint(.white).foregroundStyle(Theme.accent).controlSize(.large)
                    Button("Practise anything") { develop.startSession(count: 5) }
                        .buttonStyle(.bordered).tint(.white).controlSize(.large)
                }
                .padding(.top, Theme.Space.xs)
            } else if !develop.practisable.isEmpty {
                Label("Ready", systemImage: "sparkle").font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.85))
                Text("Pick up where you left off").font(.largeTitle.weight(.bold)).foregroundStyle(.white).minimumScaleFactor(0.7)
                Button { develop.startSession(count: 5) } label: {
                    Label("Practise 5 questions", systemImage: "play.fill").font(.body.weight(.semibold)).padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent).tint(.white).foregroundStyle(Theme.accent).controlSize(.large)
            } else {
                Label("Learn", systemImage: "graduationcap.fill").font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.85))
                Text("Practise with real papers").font(.largeTitle.weight(.bold)).foregroundStyle(.white).minimumScaleFactor(0.7)
                Text("Add a course below and Trove downloads its past papers from the exam board and splits them into questions. Work each one out on a page or a whiteboard, mark it against the mark scheme, and ask the tutor when you're stuck.")
                    .font(.callout).foregroundStyle(.white.opacity(0.9)).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Theme.Space.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(colors: [Brand.amber, Brand.coral], startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: Theme.Radius.large + 4, style: .continuous)
        )
        .shadow(color: Brand.coral.opacity(0.25), radius: 16, y: 8)
    }

    /// Three numbers, never more.
    private var statsStrip: some View {
        let s = develop.stats
        return HStack(spacing: Theme.Space.m) {
            stat("\(s.thisWeek)", "this week", symbol: "calendar")
            stat("\(s.streak)", s.streak == 1 ? "day in a row" : "days in a row", symbol: "flame")
            stat(s.recentAverage.map { "\(Int(($0 * 100).rounded()))%" } ?? "–", "recent average", symbol: "chart.line.uptrend.xyaxis")
        }
    }

    private func stat(_ value: String, _ label: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: symbol).font(.callout).foregroundStyle(Theme.accent)
            Text(value).font(.title2.weight(.semibold).monospacedDigit())
            Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(cornerRadius: Theme.Radius.medium)
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

/// One question at a time (docs/prompts/practice-space-home.md): the question as printed, then your
/// working in a real sketch (a page or a whiteboard, saved with the attempt, the tutor one tap away
/// inside it), then marking: the mark scheme to tick, or your AI on a tap.
struct PracticeView: View {
    let develop: DevelopModel
    @State private var answer = ""
    @State private var typing = false
    @State private var showSource = false
    @State private var marking = false
    @State private var ticked: Set<Int> = []
    @State private var aiResult: DevelopMarking.Result?
    @State private var working = false
    @State private var opening = false
    @State private var error: String?
    @State private var picture: CGImage?
    @State private var done: Outcome?

    /// How a question ended: its score (nil when skipped) and a line saying how it was marked.
    struct Outcome: Equatable {
        var score: Double?
        var text: String
    }
    @State private var hints: [String] = []
    @State private var kind = DevelopModel.workKind

    var body: some View {
        if let s = develop.session, let p = s.current {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.l) {
                    header(s, p)
                    questionCard(p)
                    if let done {
                        resultCard(done)
                    } else if marking {
                        schemeChecklist(p).padding(Theme.Space.l).card(cornerRadius: Theme.Radius.large)
                    } else {
                        workCard(p)
                        hintList
                        actions(p)
                    }
                    if let aiResult { aiResultView(aiResult).padding(Theme.Space.l).card(cornerRadius: Theme.Radius.large) }
                    if let error { Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.red) }
                }
                .padding(Theme.Space.xl)
                .frame(maxWidth: Theme.readingWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .task(id: p.id) { picture = await render(p) }
            .animation(.snappy(duration: 0.25), value: marking)
            .animation(.snappy(duration: 0.25), value: done)
        }
    }

    // MARK: Parts

    private func header(_ s: DevelopModel.Session, _ p: Problem) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(alignment: .firstTextBaseline) {
                Text("Question \(s.at + 1)").font(.title2.weight(.semibold))
                Text("of \(s.problems.count)").font(.title3).foregroundStyle(.secondary)
                Spacer()
                Button { showSource.toggle() } label: { Image(systemName: showSource ? "info.circle.fill" : "info.circle") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(showSource ? "Hide where it's from" : "Show where it's from")
                Button("End") { develop.session = nil }.buttonStyle(.bordered).controlSize(.small)
            }
            // Progress: one segment per question.
            HStack(spacing: 4) {
                ForEach(0..<s.problems.count, id: \.self) { i in
                    Capsule().fill(i < s.at ? Theme.accent : i == s.at ? Theme.accent.opacity(0.55) : Color.secondary.opacity(0.18))
                        .frame(height: 4)
                }
            }
            .accessibilityHidden(true)
            if showSource { Text(p.label).font(.callout).foregroundStyle(.secondary).transition(.opacity) }
        }
    }

    private func questionCard(_ p: Problem) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            if let picture {
                Image(decorative: picture, scale: 2)
                    .resizable().scaledToFit()
                    .frame(maxWidth: .infinity)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
            } else {
                Text(develop.text(of: p)).font(.body).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: Theme.Space.s) {
                if let marks = p.marks { chip("\(marks) mark\(marks == 1 ? "" : "s")", symbol: "checkmark.seal") }
                chip(develop.topic(skills: p.skills, label: p.label), symbol: "square.stack")
            }
        }
        .padding(Theme.Space.m)
        .card(cornerRadius: Theme.Radius.large)
    }

    private func chip(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Color.secondary.opacity(0.1), in: Capsule())
            .foregroundStyle(.secondary)
    }

    /// Where you work it out: the sketch (made on the first tap), or typing.
    @ViewBuilder private func workCard(_ p: Problem) -> some View {
        let work = develop.work(for: p)
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(spacing: Theme.Space.m) {
                Image(systemName: work == nil ? "pencil.and.scribble" : "doc.richtext")
                    .font(.title2).foregroundStyle(Theme.accent)
                    .frame(width: 44, height: 44)
                    .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(work == nil ? "Work it out" : "Your working").font(.headline)
                    Text(work == nil ? "On a \(kind == .page ? "page" : "whiteboard") with the question on it, saved with this attempt. Ask the tutor in there whenever you want."
                                     : "Saved in Sketches › Practice. Carry on, or mark it below.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: Theme.Space.s) {
                Button {
                    Task { opening = true; await develop.openWork(p, kind: kind); opening = false }
                } label: {
                    Label(work == nil ? "Open a \(kind.label.lowercased())" : "Continue working", systemImage: work == nil ? kind.symbol : "arrow.up.forward.app")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(opening)
                if work == nil {
                    Menu {
                        Picker("Work on", selection: $kind) {
                            ForEach(PracticeWork.Kind.allCases, id: \.self) { k in Label(k.label, systemImage: k.symbol).tag(k) }
                        }
                        Divider()
                        Button { typing.toggle() } label: { Label(typing ? "Hide the typed answer" : "Type instead", systemImage: "keyboard") }
                    } label: {
                        Image(systemName: "ellipsis").frame(width: 28, height: 28)
                    }
                    .buttonStyle(.bordered).controlSize(.large)
                    .accessibilityLabel("Page, whiteboard or typing")
                }
            }
            if typing {
                TextEditor(text: $answer)
                    .frame(minHeight: 120)
                    .padding(6)
                    .scrollContentBackground(.hidden)
                    .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
            }
        }
        .padding(Theme.Space.l)
        .card(cornerRadius: Theme.Radius.large)
        .onChange(of: kind) { _, k in DevelopModel.workKind = k }
    }

    @ViewBuilder private var hintList: some View {
        ForEach(Array(hints.enumerated()), id: \.offset) { i, h in
            HStack(alignment: .top, spacing: Theme.Space.m) {
                Text("\(i + 1)").font(.caption.bold()).foregroundStyle(.white)
                    .frame(width: 22, height: 22).background(Theme.accent, in: Circle())
                Text(h).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(Theme.Space.m).card(cornerRadius: Theme.Radius.medium)
        }
    }

    private func actions(_ p: Problem) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.s) {
                Button { marking = true } label: { Label("Mark it", systemImage: "checklist").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered).controlSize(.large)
                Button { Task { await markWithAI(p) } } label: {
                    Label(working ? "Marking…" : "Mark with AI", systemImage: "sparkles").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered).controlSize(.large)
                .disabled(working || !hasAnswer(p))
            }
            HStack {
                if hints.count < DevelopHints.levels.count {
                    Button(hints.isEmpty ? "A hint" : "Another hint") { Task { await nextHint(p) } }
                        .disabled(working)
                }
                Spacer()
                Button("Skip") {
                    Task {
                        await develop.record(p, score: nil, marking: .none, hint: hints.count)
                        done = Outcome(score: nil, text: "Skipped: kept, but it counts as no evidence.")
                    }
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .font(.callout)
        }
    }

    private func resultCard(_ done: Outcome) -> some View {
        HStack(spacing: Theme.Space.l) {
            ZStack {
                Circle().stroke(Color.secondary.opacity(0.15), lineWidth: 6)
                Circle().trim(from: 0, to: done.score ?? 0)
                    .stroke(Theme.accent, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(done.score.map { "\(Int(($0 * 100).rounded()))%" } ?? "–").font(.callout.weight(.semibold).monospacedDigit())
            }
            .frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Text(done.text).font(.callout).fixedSize(horizontal: false, vertical: true)
                Button("Next question") { reset(); develop.advance() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Theme.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(cornerRadius: Theme.Radius.large)
    }

    private func render(_ p: Problem) async -> CGImage? {
        guard !p.pages.isEmpty, let data = await develop.pdfData(p) else { return nil }
        return await Task.detached(priority: .userInitiated) {
            guard let pdf = PDFDocument(data: data) else { return nil }
            return PaperPDF.question(pdf, p.pages)
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
                    done = Outcome(score: score, text: "\(min(ticked.count, p.marks ?? ticked.count)) of \(p.marks ?? max(1, points.count)) marks, self-marked against the mark scheme.")
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

    private func hasAnswer(_ p: Problem) -> Bool {
        develop.work(for: p) != nil || !answer.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// What you've done so far: typed, plus what's handwritten in the working (read on the device).
    private func workSoFar(_ p: Problem) async -> String {
        var parts: [String] = []
        if !answer.trimmingCharacters(in: .whitespaces).isEmpty { parts.append(answer) }
        if let work = develop.work(for: p) {
            let written = await develop.workText(work)
            if !written.isEmpty { parts.append(written) }
        }
        return parts.joined(separator: "\n\n")
    }

    private func nextHint(_ p: Problem) async {
        working = true
        defer { working = false }
        do {
            hints.append(try await develop.hint(p, level: hints.count + 1, workSoFar: await workSoFar(p), earlier: hints))
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func markWithAI(_ p: Problem) async {
        working = true
        defer { working = false }
        do {
            var image: Data?
            if let work = develop.work(for: p) { image = await develop.workImage(work) }
            let r = try await develop.markWithAI(p, answer: await workSoFar(p), image: image)
            aiResult = r
            await develop.record(p, score: r.score, marking: r.marking, hint: hints.count, uncertain: r.uncertain)
            done = Outcome(score: r.score, text: r.marking == .aiScheme ? "Marked by your AI against the mark scheme." : "Marked by your AI without a mark scheme (less sure).")
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func reset() {
        answer = ""; typing = false; showSource = false; marking = false; ticked = []; aiResult = nil; error = nil; picture = nil; done = nil; hints = []
    }
}

/// Adding a goal: a name, a date, how long a day.

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

