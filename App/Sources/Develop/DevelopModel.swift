import Foundation
import Observation
import PDFKit
import TroveCore

/// Develop in the apps (docs/DEVELOP_PLAN.md §D phase 2, §E): the paper catalogue, downloading papers
/// from the board onto this device, splitting them into questions, practising, marking, and mastery.
/// Papers stay in a local cache (Application Support/Trove/papers) and never sync (decision 3); the
/// vault holds the problem records (references and regions, no question text) and the attempts.
@MainActor
@Observable
final class DevelopModel {
    static let shared = DevelopModel()

    @ObservationIgnored weak var app: AppModel?

    private(set) var catalogue: Catalogue?
    private(set) var cached: Set<String> = []
    private(set) var problems: [Problem] = []
    private(set) var attempts: [Attempt] = []
    private(set) var skills: [String: SkillState] = [:]
    private(set) var concepts: [Concept] = []
    private(set) var index = EdgeIndex()
    private(set) var goals: [CampaignPlanner.Goal] = []
    var downloading: (done: Int, total: Int)?
    var splitting = false
    var message: String?
    @ObservationIgnored private var downloadTask: Task<Void, Never>?
    @ObservationIgnored private var questionText: [String: [String: String]] = [:]
    @ObservationIgnored private var schemes: [String: [String: String]] = [:]

    var session: Session?

    struct Session {
        var problems: [Problem]
        var at = 0
        var seed: UInt64
        var current: Problem? { at < problems.count ? problems[at] : nil }
    }

    static var papersFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Trove/papers", isDirectory: true)
    }

    static func file(_ docId: String) -> URL { papersFolder.appendingPathComponent("\(docId).pdf") }

    /// The concepts of the slice's topic (momentum), in Trove's own words (decision 12: no
    /// specification text is shipped). Each is a concept or a skill, with what it needs.
    static let seed: [(name: String, type: ConceptType, requires: [String])] = [
        ("Momentum", .concept, []),
        ("Newton's laws of motion", .concept, []),
        ("Conservation of momentum", .skill, ["Momentum"]),
        ("Impulse", .skill, ["Momentum"]),
        ("Force as the rate of change of momentum", .skill, ["Momentum", "Newton's laws of motion"]),
        ("Elastic and inelastic collisions", .skill, ["Conservation of momentum"]),
    ]

    // MARK: Loading

    func start(_ app: AppModel) async {
        self.app = app
        if catalogue == nil, let url = Bundle.main.url(forResource: "papers", withExtension: "json"),
           let data = try? Data(contentsOf: url) {
            catalogue = try? Catalogue.decode(data)
        }
        try? FileManager.default.createDirectory(at: Self.papersFolder, withIntermediateDirectories: true)
        refreshCache()
        await seedConcepts()
        await reload()
    }

    func refreshCache() {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: Self.papersFolder.path)) ?? []
        cached = Set(files.filter { $0.hasSuffix(".pdf") }.map { String($0.dropLast(4)) })
    }

    func reload() async {
        guard let library = app?.library else { return }
        problems = await library.problems()
        attempts = await library.attempts()
        concepts = await library.concepts()
        goals = await library.campaigns()
        index = EdgeIndex(edges: await library.edges(), concepts: concepts)
        let all = attempts
        skills = await Task.detached(priority: .userInitiated) { Mastery.evaluate(all) }.value
    }

    private func seedConcepts() async {
        guard let library = app?.library else { return }
        let have = Set(await library.concepts().map(\.id))
        for c in Self.seed where !have.contains(Develop.conceptId(c.name)) {
            let id = await library.addConcept(c.name, type: c.type, origin: .spec)
            for r in c.requires {
                await library.setEdge(from: id, to: Develop.conceptId(r), type: .requires, state: .accepted, origin: .spec)
            }
        }
    }

    // MARK: Papers

    var spec: Catalogue.Spec? { catalogue?.spec("aqa-7408") }

    /// Downloads every paper of the spec this device doesn't have, from the board's own site, on
    /// Wi-Fi only, one at a time, cancellable.
    func download() {
        guard downloadTask == nil, let catalogue, let spec else { return }
        let missing = catalogue.downloadPlan(spec: spec.id, cached: cached)
        guard !missing.isEmpty else { message = "Every paper is on this device."; return }
        downloading = (0, missing.count)
        downloadTask = Task {
            let config = URLSessionConfiguration.default
            config.allowsExpensiveNetworkAccess = false
            config.allowsConstrainedNetworkAccess = false
            config.waitsForConnectivity = false
            let session = URLSession(configuration: config)
            var failed = 0
            for (i, doc) in missing.enumerated() {
                if Task.isCancelled { break }
                guard let url = URL(string: doc.url) else { failed += 1; continue }
                do {
                    let (tmp, response) = try await session.download(from: url)
                    let ok = (response as? HTTPURLResponse)?.statusCode == 200
                    if ok { try? FileManager.default.removeItem(at: Self.file(doc.id)); try FileManager.default.moveItem(at: tmp, to: Self.file(doc.id)) } else { failed += 1 }
                } catch {
                    failed += 1
                }
                downloading = (i + 1, missing.count)
            }
            refreshCache()
            downloading = nil
            downloadTask = nil
            message = failed == 0 ? "Papers downloaded. Split them into questions next." :
                "\(failed) paper\(failed == 1 ? "" : "s") couldn't be downloaded (they show as unavailable). Downloads use Wi-Fi only."
        }
    }

    func cancelDownload() {
        downloadTask?.cancel()
    }

    /// Splits every downloaded question paper into problems and reads its mark scheme.
    func splitAll() async {
        guard let library = app?.library, let catalogue, let spec, let layout = catalogue.board(spec.board)?.layout else { return }
        splitting = true
        defer { splitting = false }
        let concepts = await library.concepts()
        let skillConcepts = concepts.filter { $0.type == .skill }
        var made = 0
        for doc in spec.docs where doc.type == .qp && cached.contains(doc.id) {
            let file = Self.file(doc.id)
            let parsed = await Task.detached(priority: .userInitiated) { () -> (lines: [PaperSplitter.Line], size: CGSize)? in
                guard let pdf = PDFDocument(url: file) else { return nil }
                return PaperPDF.lines(pdf)
            }.value
            guard let parsed else { continue }
            let questions = PaperSplitter.split(parsed.lines, layout: layout, pageHeight: parsed.size.height, pageWidth: parsed.size.width)
            var texts: [String: String] = [:]
            let existing = Set(problems.filter { $0.sourceKey == "cat:\(doc.id)" && $0.splitBy == "user" }.map(\.key))
            for q in questions where q.marks != nil && !existing.contains(q.key) {
                texts[q.key] = q.text
                let tagged = ConceptMatch.mentioned(in: q.text, concepts: skillConcepts)
                await library.addProblem(sourceKey: "cat:\(doc.id)", key: q.key, parent: q.parent, pages: q.regions, marks: q.marks,
                                         level: spec.level, label: catalogue.label(doc, in: spec, question: q.key), skills: tagged)
                made += 1
            }
            questionText[doc.id] = texts
            savePaperCache(texts, name: "\(doc.id)-questions")
            if let ms = catalogue.companions(of: doc, in: spec).ms, cached.contains(ms.id) {
                let msFile = Self.file(ms.id)
                let lines = await Task.detached(priority: .userInitiated) { PDFDocument(url: msFile).map { PaperPDF.lines($0).lines } ?? [] }.value
                let entries = PaperSplitter.scheme(lines, layout: layout)
                schemes[ms.id] = entries
                savePaperCache(entries, name: "\(ms.id)-scheme")
            }
        }
        message = made == 0 ? "No questions found. Download the papers first." : "\(made) questions ready to practise."
        await reload()
    }

    private func savePaperCache(_ value: [String: String], name: String) {
        if let data = try? JSONEncoder().encode(value) { try? data.write(to: Self.papersFolder.appendingPathComponent("\(name).json")) }
    }

    private func loadPaperCache(_ name: String) -> [String: String]? {
        guard let data = try? Data(contentsOf: Self.papersFolder.appendingPathComponent("\(name).json")) else { return nil }
        return try? JSONDecoder().decode([String: String].self, from: data)
    }

    func docId(_ p: Problem) -> String? { p.sourceKey.hasPrefix("cat:") ? String(p.sourceKey.dropFirst(4)) : nil }

    /// The question's text, read from the paper on this device (never stored in the vault).
    func text(of p: Problem) -> String {
        guard let doc = docId(p) else { return "" }
        if questionText[doc] == nil { questionText[doc] = loadPaperCache("\(doc)-questions") ?? [:] }
        return questionText[doc]?[p.key] ?? ""
    }

    /// The matched mark-scheme entry, if any.
    func scheme(of p: Problem) -> String? {
        guard let docId = docId(p), let catalogue, let spec, let qp = spec.docs.first(where: { $0.id == docId }),
              let ms = catalogue.companions(of: qp, in: spec).ms else { return nil }
        if schemes[ms.id] == nil { schemes[ms.id] = loadPaperCache("\(ms.id)-scheme") ?? [:] }
        return schemes[ms.id]?[p.key]
    }

    /// Problems whose paper is on this device.
    var practisable: [Problem] { problems.filter { docId($0).map(cached.contains) ?? false } }

    // MARK: Practice

    /// What to do next: the skill that most needs practice now, with why.
    var next: (skill: Concept, why: String)? {
        let now = Date().timeIntervalSince1970 * 1000
        let ranked = concepts.filter { $0.type == .skill && $0.mergedInto == nil }.map { c -> (Concept, Double, String) in
            guard let s = skills[c.id], let m = s.memory else { return (c, 0.5, "Not assessed yet") }
            let due = (s.due ?? .infinity) <= now
            let p = s.pApply(daysAfterLast: (now - m.last) / 86_400_000) ?? 0
            return (c, due ? 1 + (1 - p) : 1 - p, due ? "Due: last practised \(Self.ago(m.last))" : s.why)
        }.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.id < $1.0.id }
        return ranked.first.map { ($0.0, $0.2) }
    }

    static func ago(_ ms: Double) -> String {
        let days = Int((Date().timeIntervalSince1970 * 1000 - ms) / 86_400_000)
        return days <= 0 ? "today" : days == 1 ? "yesterday" : "\(days) days ago"
    }

    func startSession(count: Int = 5, skill: String? = nil) {
        var filter = Practice.Filter()
        if let skill { filter.skills = [skill] }
        let seed = UInt64.random(in: 1...UInt64.max)
        let picked = Practice.pick(count, from: practisable, attempts: attempts, skills: skills, filter: filter,
                                   now: Date().timeIntervalSince1970 * 1000, seed: seed)
        session = picked.isEmpty ? nil : Session(problems: picked, seed: seed)
        if picked.isEmpty { message = practisable.isEmpty ? "Download and split the papers first." : "Nothing new to practise for that right now." }
    }

    func advance() {
        guard var s = session else { return }
        s.at += 1
        session = s.at < s.problems.count ? s : nil
    }

    /// Records the attempt and re-derives mastery.
    func record(_ p: Problem, score: Double?, marking: Marking, hint: Int = 0, uncertain: Bool = false) async {
        guard let library = app?.library else { return }
        let a = Attempt(id: "attempt.\(UUID().uuidString)", problem: p.id, skills: p.skills, at: Date().timeIntervalSince1970 * 1000,
                        hint: hint, marking: marking, score: score, uncertain: uncertain, b: Difficulty.b(p), sourceKey: p.sourceKey, label: p.label)
        await library.recordAttempt(a)
        await reload()
    }

    /// Marks with your AI (only on a tap). An uncertain low-effort mark is checked once more at medium.
    /// The next hint (1…5) for a problem, from your AI, only on a tap.
    func hint(_ p: Problem, level: Int, workSoFar: String, earlier: [String]) async throws -> String {
        guard let ai = app?.ownAI else { throw DevelopError("Hints use your AI: set it up in Settings → AI.") }
        return try await ai.developHint(level: level, question: text(of: p), scheme: scheme(of: p), workSoFar: workSoFar, earlier: earlier, about: p.label)
    }

    func markWithAI(_ p: Problem, answer: String, image: Data? = nil) async throws -> DevelopMarking.Result {
        guard let ai = app?.ownAI else {
            throw DevelopError("Set up your AI in Settings → AI to mark with AI, or show the mark scheme and mark it yourself.")
        }
        let scheme = scheme(of: p), hard = Difficulty.isHard(p)
        var (result, _) = try await ai.markAttempt(question: text(of: p), scheme: scheme, answer: answer, answerImage: image, marks: p.marks,
                                                   hard: hard, about: p.label)
        if result.uncertain, !hard {
            (result, _) = try await ai.markAttempt(question: text(of: p), scheme: scheme, answer: answer, answerImage: image, marks: p.marks,
                                                   hard: hard, retryOfUncertain: true, about: p.label)
        }
        return result
    }

    /// Attempts marked by AI that came back uncertain: counted as nothing until confirmed.
    var toReview: [Attempt] { attempts.filter { $0.uncertain }.sorted { $0.at > $1.at } }

    func confirm(_ a: Attempt, score: Double) async {
        guard let library = app?.library else { return }
        var fixed = a
        fixed.score = score
        fixed.uncertain = false
        fixed.marking = .selfMarked
        await library.recordAttempt(fixed)
        await reload()
    }

    // MARK: Goals

    func addGoal(name: String, deadline: Date, minutesPerDay: Int) async {
        guard let library = app?.library else { return }
        await library.saveCampaign(.init(id: "campaign.\(UUID().uuidString)", name: name, deadline: deadline.timeIntervalSince1970 * 1000,
                                         minutesPerDay: minutesPerDay))
        await reload()
    }

    func plan(_ goal: CampaignPlanner.Goal) -> CampaignPlanner.Plan {
        let skillIds = concepts.filter { $0.type == .skill && $0.mergedInto == nil }.map(\.id)
        return CampaignPlanner.plan(goal, skills: skillIds, states: skills, now: Date().timeIntervalSince1970 * 1000)
    }

    func name(_ id: String) -> String { concepts.first { $0.id == id }?.name ?? id }

    // MARK: Anki

    /// An Anki package (.apkg); importing a newer one updates the same notes.
    func ankiFile() async -> URL? {
        guard let library = app?.library else { return nil }
        let cards = await library.studyCards()
        guard !cards.isEmpty else { message = "No flashcards yet."; return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Trove cards.apkg")
        do {
            let data = try AnkiPackage.make(cards, now: Int64(Date().timeIntervalSince1970 * 1000))
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            // The plain-text export imports into Anki too (File → Import).
            let txt = FileManager.default.temporaryDirectory.appendingPathComponent("Trove cards.txt")
            try? AnkiExport.tsv(cards).write(to: txt, atomically: true, encoding: .utf8)
            return txt
        }
    }
}

struct DevelopError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// PDF text with positions and page pictures, for splitting and showing questions (PDFKit on every platform).
enum PaperPDF {
    /// Every line of text with its box (points, origin top-left), and the first page's size.
    nonisolated static func lines(_ pdf: PDFDocument) -> (lines: [PaperSplitter.Line], size: CGSize) {
        var out: [PaperSplitter.Line] = []
        var size = CGSize(width: 595, height: 842)
        for i in 0..<pdf.pageCount {
            guard let page = pdf.page(at: i) else { continue }
            let box = page.bounds(for: .mediaBox)
            if i == 0 { size = box.size }
            guard let all = page.selection(for: box) else { continue }
            for line in all.selectionsByLine() {
                let text = (line.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let b = line.bounds(for: page)
                out.append(.init(page: i, x: b.minX - box.minX, y: box.maxY - b.maxY, width: b.width, height: b.height, text: text))
            }
        }
        return (out, size)
    }

    /// A question's region drawn at `scale` (diagrams included).
    nonisolated static func image(_ pdf: PDFDocument, _ region: PageRegion, scale: CGFloat = 2) -> CGImage? {
        guard let page = pdf.page(at: region.page), region.rect.count == 4 else { return nil }
        let box = page.bounds(for: .mediaBox)
        let r = CGRect(x: box.minX + region.rect[0], y: box.maxY - region.rect[1] - region.rect[3], width: region.rect[2], height: region.rect[3])
            .intersection(box)
        guard r.width > 1, r.height > 1 else { return nil }
        let w = Int(r.width * scale), h = Int(r.height * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -r.minX, y: -r.minY)
        page.draw(with: .mediaBox, to: ctx)
        return ctx.makeImage()
    }
}
