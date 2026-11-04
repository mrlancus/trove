import Foundation
import Observation
import PDFKit
import TroveCore
#if os(iOS)
import UIKit
#else
import AppKit
#endif

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
    private(set) var courses: [Course] = []
    private var specFiles: [String: Catalogue.Spec] = [:]
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
        try? FileManager.default.createDirectory(at: Self.papersFolder, withIntermediateDirectories: true)
        refreshCache()
        if let library = app.library { courses = await library.courses() }
        await loadCatalogue()
        for c in courses { await loadSpec(c.spec) }
        await seedConcepts()
        await reload()
        await readUploadTexts()
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

    /// The momentum skills (the first slice) for anyone doing a Physics course.
    private func seedConcepts() async {
        guard let library = app?.library, courses.contains(where: { $0.name.localizedCaseInsensitiveContains("physics") }) else { return }
        let have = Set(await library.concepts().map(\.id))
        for c in Self.seed where !have.contains(Develop.conceptId(c.name)) {
            let id = await library.addConcept(c.name, type: c.type, origin: .spec)
            for r in c.requires {
                await library.setEdge(from: id, to: Develop.conceptId(r), type: .requires, state: .accepted, origin: .spec)
            }
        }
    }

    // MARK: Courses and the catalogue

    /// Where the catalogue is kept up to date (the repo's `catalogue/`, rebuilt weekly by CI from the boards'
    /// own listings); the copy bundled with the app is the fallback.
    static let catalogueBase = URL(string: "https://raw.githubusercontent.com/mrlancus/trove/main/catalogue/")!
    static var catalogueFolder: URL { papersFolder.appendingPathComponent("catalogue", isDirectory: true) }

    /// The index: bundled first (instant), then a newer one from the web, at most once a day.
    private func loadCatalogue() async {
        let local = Self.catalogueFolder.appendingPathComponent("index.json")
        if catalogue == nil {
            let data = (try? Data(contentsOf: local)) ?? Bundle.main.url(forResource: "index", withExtension: "json", subdirectory: "catalogue").flatMap { try? Data(contentsOf: $0) }
            catalogue = await Task.detached(priority: .userInitiated) { data.flatMap { try? Catalogue.decode($0) } }.value
        }
        let age = (try? local.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate).map { -$0.timeIntervalSinceNow } ?? .infinity
        guard age > 86_400, let got = try? await URLSession.shared.data(from: Self.catalogueBase.appendingPathComponent("index.json")),
              (got.1 as? HTTPURLResponse)?.statusCode == 200 else { return }
        let data = got.0
        guard let fresh = await Task.detached(priority: .utility, operation: { try? Catalogue.decode(data) }).value else { return }
        try? FileManager.default.createDirectory(at: Self.catalogueFolder.appendingPathComponent("specs"), withIntermediateDirectories: true)
        try? data.write(to: local, options: .atomic)
        catalogue = fresh
        specFiles.removeAll() // re-read spec files that may have changed
        for c in courses { await loadSpec(c.spec) }
    }

    /// One spec's documents: downloaded copy, else bundled, else from the web (then kept).
    @discardableResult
    func loadSpec(_ id: String) async -> Catalogue.Spec? {
        if let s = specFiles[id] { return s }
        let local = Self.catalogueFolder.appendingPathComponent("specs/\(id).json")
        var data = try? Data(contentsOf: local)
        if data == nil, let url = Bundle.main.url(forResource: id, withExtension: "json", subdirectory: "catalogue/specs") { data = try? Data(contentsOf: url) }
        if data == nil, let got = try? await URLSession.shared.data(from: Self.catalogueBase.appendingPathComponent("specs/\(id).json")),
           (got.1 as? HTTPURLResponse)?.statusCode == 200 {
            let fetched = got.0
            data = fetched
            try? FileManager.default.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fetched.write(to: local, options: .atomic)
        }
        guard let data, let spec = await Task.detached(priority: .userInitiated, operation: { try? Catalogue.decodeSpec(data) }).value else { return nil }
        specFiles[id] = spec
        return spec
    }

    /// Your chosen courses with their documents (those loaded so far).
    var courseSpecs: [Catalogue.Spec] { courses.compactMap { specFiles[$0.spec] } }

    func addCourse(_ spec: Catalogue.Spec) async {
        guard let library = app?.library else { return }
        let board = catalogue?.board(spec.board)?.name ?? spec.board.uppercased()
        await library.setCourse(Course(spec: spec.id, name: "\(board) \(spec.name)"))
        courses = await library.courses()
        await loadSpec(spec.id)
        await seedConcepts()
    }

    func removeCourse(_ course: Course) async {
        guard let library = app?.library else { return }
        var off = course
        off.active = false
        await library.setCourse(off)
        courses = await library.courses()
    }

    func boardName(_ id: String) -> String { catalogue?.board(id)?.name ?? id.uppercased() }

    /// The spec a catalogue document belongs to (among your courses).
    func spec(ofDoc id: String) -> Catalogue.Spec? {
        courseSpecs.first { s in id.hasPrefix(s.id + "-") && s.docs.contains { $0.id == id } }
    }

    /// Question papers of a course on this device.
    func downloaded(_ spec: Catalogue.Spec) -> Int { spec.questionPapers.filter { cached.contains($0.id) }.count }

    // MARK: Papers

    /// Downloads the chosen papers (each with its mark scheme and report; all of a course's when `papers`
    /// is nil) from the board's own site, on Wi-Fi only, one at a time, cancellable; then splits them.
    func download(_ spec: Catalogue.Spec, papers: Set<String>? = nil) {
        guard downloadTask == nil, let catalogue else { return }
        let missing = catalogue.downloadPlan(spec: spec, cached: cached, papers: papers)
        guard !missing.isEmpty else {
            Task { await split(spec) }
            return
        }
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
            if failed > 0 {
                message = "\(failed) file\(failed == 1 ? "" : "s") couldn't be downloaded (they show as unavailable). Downloads use Wi-Fi only."
            }
            await split(spec)
        }
    }

    func cancelDownload() {
        downloadTask?.cancel()
    }

    /// Splits every downloaded question paper of a course into problems and reads its mark schemes.
    func split(_ spec: Catalogue.Spec) async {
        guard let library = app?.library, let catalogue else { return }
        let layouts = [catalogue.layout(for: spec.board), PaperSplitter.genericLayout]
        splitting = true
        defer { splitting = false }
        let skillConcepts = await library.concepts().filter { $0.type == .skill }
        let done = Set(problems.map(\.sourceKey))
        var made = 0, unsplit = 0
        // A paper split on another device has its problems already (they sync); this device still reads its
        // text and mark scheme for itself, since those stay on the device.
        for doc in spec.questionPapers where cached.contains(doc.id) && !(done.contains("cat:\(doc.id)") && loadPaperCache("\(doc.id)-questions") != nil) {
            let known = done.contains("cat:\(doc.id)")
            let file = Self.file(doc.id)
            let parsed = await Task.detached(priority: .userInitiated) { () -> (lines: [PaperSplitter.Line], size: CGSize)? in
                guard let pdf = PDFDocument(url: file) else { return nil }
                return PaperPDF.lines(pdf)
            }.value
            guard let parsed else { continue }
            let (questions, layout) = PaperSplitter.splitBest(parsed.lines, layouts: layouts, pageHeight: parsed.size.height, pageWidth: parsed.size.width)
            if questions.isEmpty { unsplit += 1; continue }
            var texts: [String: String] = [:]
            for q in questions {
                texts[q.key] = q.text
                if known { continue }
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
                let entries = PaperSplitter.schemePaper(lines, layout: layout)
                schemes[ms.id] = entries
                savePaperCache(entries, name: "\(ms.id)-scheme")
            }
        }
        message = made == 0 && unsplit == 0 ? nil
            : "\(made) questions ready to practise" + (unsplit > 0 ? "; \(unsplit) paper\(unsplit == 1 ? "" : "s") had no questions Trove could find (essay or listening papers, or scans)." : ".")
        await reload()
    }

    // MARK: Your own papers

    /// Saves a file you picked (a PDF, a photo, a scan) as an item in your trove, so it syncs to all your
    /// devices, then splits it into questions. Pictures become a one-page PDF first.
    func upload(_ data: Data, name: String, mime: String) async {
        guard let library = app?.library else { return }
        var pdf = data, fileName = name
        if !mime.contains("pdf") {
            guard let made = Self.pdf(fromImage: data) else { message = "Couldn't read \(name)."; return }
            pdf = made
            fileName = (name as NSString).deletingPathExtension + ".pdf"
        }
        guard let id = try? await library.addFile(pdf, name: fileName, mime: "application/pdf", kind: .pdf, source: .app,
                                                  title: (name as NSString).deletingPathExtension, folder: ["Practice papers"]) else {
            message = "Couldn't save \(name)."; return
        }
        await app?.reload()
        if let item = await library.item(id) { await split(item: item) }
    }

    nonisolated static func pdf(fromImage data: Data) -> Data? {
        #if os(iOS)
        guard let image = UIImage(data: data), let page = PDFPage(image: image) else { return nil }
        #else
        guard let image = NSImage(data: data), let page = PDFPage(image: image) else { return nil }
        #endif
        let doc = PDFDocument()
        doc.insert(page, at: 0)
        return doc.dataRepresentation()
    }

    /// The questions in one of your PDFs: numbered questions and parts, or one per page when there's no
    /// text Trove can read (a photo or a scan).
    nonisolated static func questions(inPDF data: Data) -> [PaperSplitter.Question]? {
        guard let doc = PDFDocument(data: data) else { return nil }
        let parsed = PaperPDF.lines(doc)
        // Parts lettered (a), (b)… become 1.1, 1.2; a number only starts a question when it follows on from
        // the last one (1, 2, 3…), so "3 kg of water" at the margin stays text.
        let qs = PaperSplitter.splitPaper(parsed.lines, layout: PaperSplitter.genericLayout, pageHeight: parsed.size.height, pageWidth: parsed.size.width)
        if !qs.isEmpty { return qs }
        return (0..<doc.pageCount).map { page in
            PaperSplitter.Question(key: "\(page + 1)", parent: nil, regions: [PageRegion(page: page, rect: [0, 0, parsed.size.width, parsed.size.height])],
                                   marks: nil, text: parsed.lines.filter { $0.page == page }.map(\.text).joined(separator: "\n"))
        }
    }

    /// Splits one of your PDF items into problems (they stay items in your vault and sync like any other).
    func split(item: Item) async {
        guard let library = app?.library, let att = item.attachments.first(where: { $0.mime == "application/pdf" }),
              let data = try? await library.attachmentData(att) else { message = "Couldn't open that PDF."; return }
        splitting = true
        defer { splitting = false }
        guard let questions = await Task.detached(priority: .userInitiated, operation: { Self.questions(inPDF: data) }).value else {
            message = "Couldn't read that file."; return
        }
        let skillConcepts = await library.concepts().filter { $0.type == .skill }
        var texts: [String: String] = [:]
        for q in questions {
            texts[q.key] = q.text
            await library.addProblem(sourceKey: "item:\(item.id)", key: q.key, parent: q.parent, pages: q.regions, marks: q.marks, level: .other,
                                     label: "\(item.displayTitle) Q\(q.key)", skills: ConceptMatch.mentioned(in: q.text, concepts: skillConcepts))
        }
        questionText["item-\(item.id)"] = texts
        savePaperCache(texts, name: "item-\(item.id)-questions")
        message = questions.isEmpty ? "Nothing to practise in \(item.displayTitle)." : "\(questions.count) questions from \(item.displayTitle) ready to practise."
        await reload()
    }

    /// Uploads split on another device: their problems synced; read their text here too (it stays on the device).
    private func readUploadTexts() async {
        guard let library = app?.library else { return }
        for id in practisedItems where loadPaperCache("item-\(id)-questions") == nil {
            guard let item = await library.item(id), let att = item.attachments.first(where: { $0.mime == "application/pdf" }),
                  let data = try? await library.attachmentData(att),
                  let qs = await Task.detached(priority: .utility, operation: { Self.questions(inPDF: data) }).value else { continue }
            let texts = Dictionary(qs.map { ($0.key, $0.text) }, uniquingKeysWith: { a, _ in a })
            questionText["item-\(id)"] = texts
            savePaperCache(texts, name: "item-\(id)-questions")
        }
    }

    private func savePaperCache(_ value: [String: String], name: String) {
        if let data = try? JSONEncoder().encode(value) { try? data.write(to: Self.papersFolder.appendingPathComponent("\(name).json")) }
    }

    private func loadPaperCache(_ name: String) -> [String: String]? {
        guard let data = try? Data(contentsOf: Self.papersFolder.appendingPathComponent("\(name).json")) else { return nil }
        return try? JSONDecoder().decode([String: String].self, from: data)
    }

    func docId(_ p: Problem) -> String? { p.sourceKey.hasPrefix("cat:") ? String(p.sourceKey.dropFirst(4)) : nil }
    func itemId(_ p: Problem) -> String? { p.sourceKey.hasPrefix("item:") ? String(p.sourceKey.dropFirst(5)) : nil }

    /// The PDF a problem is on: a catalogue paper in the local cache, or one of your items.
    func pdfData(_ p: Problem) async -> Data? {
        if let doc = docId(p) { return try? Data(contentsOf: Self.file(doc)) }
        guard let id = itemId(p), let library = app?.library, let item = await library.item(id),
              let att = item.attachments.first(where: { $0.mime == "application/pdf" }) else { return nil }
        return try? await library.attachmentData(att)
    }

    /// The question's text, read from the paper on this device (never stored in the vault).
    func text(of p: Problem) -> String {
        if let id = itemId(p) {
            if questionText["item-\(id)"] == nil { questionText["item-\(id)"] = loadPaperCache("item-\(id)-questions") ?? [:] }
            return questionText["item-\(id)"]?[p.key] ?? ""
        }
        guard let doc = docId(p) else { return "" }
        if questionText[doc] == nil { questionText[doc] = loadPaperCache("\(doc)-questions") ?? [:] }
        return questionText[doc]?[p.key] ?? ""
    }

    /// The matched mark-scheme entry, if any.
    func scheme(of p: Problem) -> String? {
        guard let docId = docId(p), let catalogue, let spec = spec(ofDoc: docId), let qp = spec.docs.first(where: { $0.id == docId }),
              let ms = catalogue.companions(of: qp, in: spec).ms else { return nil }
        if schemes[ms.id] == nil { schemes[ms.id] = loadPaperCache("\(ms.id)-scheme") ?? [:] }
        return schemes[ms.id]?[p.key]
    }

    /// Problems whose paper is on this device.
    var practisable: [Problem] { problems.filter { docId($0).map(cached.contains) ?? (itemId($0) != nil) } }

    /// Your PDF items that can be split into questions.
    var myPDFs: [Item] { (app?.items ?? []).filter { $0.attachments.contains { $0.mime == "application/pdf" } } }

    /// Your uploaded papers that are split already (by item id).
    var practisedItems: Set<String> { Set(problems.compactMap(itemId)) }

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
        if picked.isEmpty { message = practisable.isEmpty ? "Add a course and download some papers first, or upload your own." : "Nothing new to practise for that right now." }
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

    var hasAI: Bool { app?.ownAI != nil }

    func saveGoal(_ goal: CampaignPlanner.Goal) async {
        guard let library = app?.library else { return }
        await library.saveCampaign(goal)
        // A goal's courses are your courses too.
        for spec in goal.courses where !courses.contains(where: { $0.spec == spec }) {
            if let s = catalogue?.spec(spec) { await addCourse(s) }
        }
        await reload()
    }

    func removeGoal(_ goal: CampaignPlanner.Goal) async {
        await app?.library?.removeCampaign(goal)
        await reload()
    }

    /// "How long have you got today?": sizes today's plan; the latest answer is the usual for later days.
    func setToday(_ goal: CampaignPlanner.Goal, minutes: Int) async {
        var g = goal
        g.setToday(minutes, now: Date().timeIntervalSince1970 * 1000)
        await saveGoal(g)
    }

    /// Today's practice for a goal: as many questions as today's time allows, from its courses' papers.
    func startGoal(_ goal: CampaignPlanner.Goal) {
        let plan = plan(goal)
        var filter = Practice.Filter()
        filter.sourcePrefixes = goal.sourcePrefixes
        if let today = plan.days.first, !today.skills.isEmpty, !goal.courses.isEmpty || !goal.skills.isEmpty { filter.skills = Set(today.skills) }
        let count = max(1, plan.days.first?.questions ?? 3)
        let seed = UInt64.random(in: 1...UInt64.max)
        let now = Date().timeIntervalSince1970 * 1000
        var picked = Practice.pick(count, from: practisable, attempts: attempts, skills: skills, filter: filter, now: now, seed: seed)
        if picked.isEmpty, !filter.skills.isEmpty { // today's skills have no questions on this device: any from its courses
            filter.skills = []
            picked = Practice.pick(count, from: practisable, attempts: attempts, skills: skills, filter: filter, now: now, seed: seed)
        }
        session = picked.isEmpty ? nil : Session(problems: picked, seed: seed)
        if picked.isEmpty { message = goal.courses.isEmpty ? "Add a course to this goal, or download some papers first." : "Download some of this course's papers first." }
    }

    /// Courses the AI may put in a goal: yours, then catalogue specs matching words of the conversation.
    func goalCandidates(_ messages: [GoalChat.Message]) -> [GoalChat.Candidate] {
        var out = courses.map { GoalChat.Candidate(spec: $0.spec, name: $0.name, yours: true) }
        guard let catalogue else { return out }
        var words: Set<String> = []
        for m in messages where m.role == .you {
            for part in m.text.lowercased().split(whereSeparator: { c in !c.isLetter && !c.isNumber }) {
                let w = String(part)
                let isCode = w.count >= 3 && w.allSatisfy(\.isNumber)
                if w.count >= 4 || isCode { words.insert(w) }
            }
        }
        let stop: Set<String> = ["want", "exam", "exams", "paper", "papers", "level", "test", "with", "need", "this", "next", "june", "year", "about", "revise", "pass"]
        var scored: [String: (Catalogue.Spec, Int)] = [:]
        for w in words where !stop.contains(w) {
            for spec in catalogue.search(w) { scored[spec.id] = (spec, (scored[spec.id]?.1 ?? 0) + 1) }
        }
        let have = Set(out.map(\.spec))
        for (spec, _) in scored.values.sorted(by: { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.id < $1.0.id }).prefix(30) where !have.contains(spec.id) {
            out.append(GoalChat.Candidate(spec: spec.id, name: "\(boardName(spec.board)) \(spec.name)", yours: false))
        }
        return out
    }

    func clarifyGoal(_ messages: [GoalChat.Message]) async throws -> GoalChat.Reply {
        guard let ai = app?.ownAI else { throw DevelopError("Set up your AI in Settings → AI, or fill the goal in yourself.") }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_GB")
        return try await ai.clarifyGoal(messages, candidates: goalCandidates(messages), today: f.string(from: Date()))
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
