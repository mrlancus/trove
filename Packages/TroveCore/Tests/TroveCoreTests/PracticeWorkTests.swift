import Foundation
import Testing
@testable import TroveCore

/// Practising in real sketches (docs/prompts/practice-space-home.md).
struct PracticeWorkTests {
    @Test func labelsSplitIntoPaperAndQuestion() {
        #expect(PracticeWork.paper(of: "AQA 7408/2 June 2023 Q4.2") == "AQA 7408/2 June 2023")
        #expect(PracticeWork.question(of: "AQA 7408/2 June 2023 Q4.2") == "Q4.2")
        #expect(PracticeWork.title(label: "OCR J249/1H June 2023 Q3") == "Q3 · OCR J249/1H June 2023")
        #expect(PracticeWork.paper(of: "My notes") == "My notes")
        #expect(PracticeWork.title(label: "") == "Practice")
    }

    @Test func topicIsTheSkillElseThePaperWithoutItsSeries() {
        let names = ["c.momentum": "Conservation of momentum"]
        #expect(PracticeWork.topic(skills: ["c.momentum"], label: "AQA 7408/2 June 2023 Q4", name: { names[$0] }) == "Conservation of momentum")
        // Every year of the same paper groups together.
        #expect(PracticeWork.topic(skills: [], label: "AQA 7408/2 June 2023 Q4", name: { names[$0] }) == "AQA 7408/2")
        #expect(PracticeWork.topic(skills: [], label: "AQA 7408/2 June 2022 Q1", name: { names[$0] }) == "AQA 7408/2")
        #expect(PracticeWork.topic(skills: ["unknown"], label: "", name: { names[$0] }) == "Other questions")
    }

    @Test func foldersNeverSplitOnASlash() {
        let f = PracticeWork.folder(course: "AQA A-level Physics", topic: "AQA 7408/2")
        #expect(f.count == 3)
        #expect(f[0] == "Practice")
        #expect(!f[2].contains("/"))
        #expect(PracticeWork.folder(course: "", topic: "x")[1] == "My papers")
    }

    @Test func theQuestionSitsAcrossTheTopKeepingItsShape() {
        let r = PracticeWork.questionFrame(imageWidth: 1000, imageHeight: 400, pageWidth: 595)
        #expect(r.x == 36 && r.y == 36)
        #expect(abs(r.width - 523) < 0.001)
        #expect(abs(r.height - 523 * 0.4) < 0.001)
        let w = PracticeWork.questionFrame(imageWidth: 200, imageHeight: 100, pageWidth: nil)
        #expect(w.width == 520 && w.height == 260)
    }

    private func attempt(_ id: String, problem: String, at: Double, score: Double?, work: String = "", label: String = "AQA 7408/2 June 2023 Q1") -> Attempt {
        Attempt(id: id, problem: problem, skills: [], at: at, hint: 0, marking: score == nil ? .none : .selfMarked, score: score,
                b: 0, sourceKey: "cat:x", label: label, work: work)
    }

    @Test func attemptsGroupByCourseThenTopicNewestFirst() {
        let a = [
            attempt("1", problem: "p1", at: 100, score: 0.5),
            attempt("2", problem: "p1", at: 300, score: 1),
            attempt("3", problem: "p2", at: 200, score: 0.25, label: "AQA 7408/1 June 2023 Q2"),
            attempt("4", problem: "p3", at: 400, score: nil), // skipped, no working: left out
            attempt("5", problem: "p3", at: 500, score: nil, work: "sketch.5"), // not marked yet, but has working
        ]
        let courses = PracticeWork.group(a, course: { _ in "Physics" }, topic: { PracticeWork.topic(skills: [], label: $0.label, name: { _ in nil }) })
        #expect(courses.count == 1)
        let topics = courses[0].topics
        #expect(topics.map(\.name) == ["AQA 7408/2", "AQA 7408/1"])
        #expect(topics[0].attempts.map(\.id) == ["5", "2", "1"])
        #expect(topics[0].average == 0.75)
        #expect(topics[0].trend == 0.5)
        #expect(topics[0].retried["p1"]?.map(\.id) == ["1", "2"])
        #expect(courses[0].count == 4)
    }

    @Test func workSurvivesTheRecord() async {
        let lib = Library(engine: SyncEngine(device: "D", keys: nil, encrypted: false))
        _ = await lib.recordAttempt(attempt("attempt.w", problem: "p", at: 1, score: 1, work: "item.abc"))
        _ = await lib.recordAttempt(attempt("attempt.n", problem: "p", at: 2, score: 1))
        let all = await lib.attempts()
        #expect(all.first { $0.id == "attempt.w" }?.work == "item.abc")
        #expect(all.first { $0.id == "attempt.n" }?.work == "")
    }

    @Test func theTutorSeesTheQuestionAndSchemeFirst() {
        let p = PracticeContext(label: "AQA 7408/2 June 2023 Q4", question: "A 2 kg trolley…", scheme: "p = mv (1)", marks: 3)
        let c = p.around(StudyContext(title: "Q4", pages: [StudyContext.Page(key: "0", label: "Page 1", text: "p = 2 × 3")]))
        #expect(c.pages.map(\.key) == ["practice.question", "practice.scheme", "0"])
        #expect(c.pages[0].label.contains("3 marks"))
        let noScheme = PracticeContext(label: "x", question: "q", scheme: "  ", marks: nil)
        #expect(noScheme.pages.count == 1)
        for a in TutorAction.allCases { #expect(!a.prompt.isEmpty && !a.label.isEmpty) }
    }
}

struct PracticeStatsTests {
    private let day = 86_400_000.0
    private func a(_ at: Double, _ score: Double?) -> Attempt {
        Attempt(id: "\(at)", problem: "p", skills: [], at: at, hint: 0, marking: .selfMarked, score: score, b: 0, sourceKey: "")
    }

    @Test func weekStreakAndAverage() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let now = 20 * day + 12 * 3_600_000 // noon on day 20
        let attempts = [a(now - 1000, 1), a(now - day, 0.5), a(now - 2 * day, 0), a(now - 9 * day, 1), a(now - 3000, nil)]
        let s = PracticeStats(attempts, now: now, calendar: utc)
        #expect(s.thisWeek == 3) // the unmarked one without working doesn't count
        #expect(s.streak == 3)
        #expect(s.recentAverage == 0.625)
    }

    @Test func aStreakSurvivesUntilTheDayIsOver() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let now = 20 * day + 12 * 3_600_000
        // Nothing today yet, but yesterday and the day before: still 2.
        #expect(PracticeStats([a(now - day, 1), a(now - 2 * day, 1)], now: now, calendar: utc).streak == 2)
        #expect(PracticeStats([a(now - 3 * day, 1)], now: now, calendar: utc).streak == 0)
        #expect(PracticeStats([], now: now, calendar: utc).recentAverage == nil)
    }
}

/// Splitting v2 (docs/prompts/practice-space-home.md): only the question, with its context.
struct TightSplitTests {
    // Written for this test in a competition-paper style: "Question 1", parts "c)", "(i)", marks "(10)".
    func line(_ page: Int, _ x: Double, _ y: Double, _ t: String, width: Double = 400) -> PaperSplitter.Line {
        .init(page: page, x: x, y: y, width: width, height: 12, text: t)
    }

    var paper: [PaperSplitter.Line] {
        [
            line(0, 60, 60, "Question 1"),
            line(0, 60, 80, "This question is about the energy of a star."),
            line(0, 80, 120, "a) State what fuels the star. (2)"),
            line(0, 80, 160, "b) Show that the core pressure is about 10^16 Pa."),
            line(0, 100, 180, "where X is the mass fraction of hydrogen. (3)"),
            line(0, 60, 230, "Photons made in the core take a random walk to the surface of the star."),
            line(0, 80, 260, "c) Estimate the time for a photon to escape."),
            line(0, 100, 280, "(i) Find the mean free path."),
            line(0, 100, 300, "(ii) Hence find the number of steps. (4)"),
            line(0, 60, 400, "........................................................."),
            line(1, 60, 60, "Question 2"),
            line(1, 80, 90, "a) Define luminosity. (1)"),
        ]
    }

    @Test func competitionStyleLabelsSplit() {
        let qs = PaperSplitter.splitPaper(paper, layout: PaperSplitter.genericLayout, pageHeight: 842, pageWidth: 595)
        #expect(qs.map(\.key) == ["1", "1.1", "1.2", "1.3", "1.3.1", "1.3.2", "2", "2.1"])
        #expect(qs.first { $0.key == "1.2" }?.marks == 3)
    }

    @Test func aLeadInGoesWithThePartItIntroduces() {
        let qs = PaperSplitter.splitPaper(paper, layout: PaperSplitter.genericLayout, pageHeight: 842, pageWidth: 595)
        let b = qs.first { $0.key == "1.2" }!, c = qs.first { $0.key == "1.3" }!
        #expect(!b.text.contains("random walk"))
        #expect(c.text.contains("random walk"))
        // c)(ii) carries the question's stem and c)'s lead-in, not a) or b).
        let cii = qs.first { $0.key == "1.3.2" }!
        #expect(cii.text.contains("energy of a star") && cii.text.contains("random walk") && cii.text.contains("Hence find"))
        #expect(!cii.text.contains("fuels") && !cii.text.contains("core pressure"))
    }

    @Test func regionsHoldOnlyTheQuestion() {
        let qs = PaperSplitter.splitPaper(paper, layout: PaperSplitter.genericLayout, pageHeight: 842, pageWidth: 595)
        let b = qs.first { $0.key == "1.2" }!
        // The question's stem comes first (its context), then b) itself.
        #expect(b.regions.count == 2)
        let r = b.regions.last!.rect
        // From b)'s first line to its marks, not down to the next part, and not the page's full width.
        #expect(r[1] >= 150 && r[1] + r[3] <= 200)
        #expect(r[0] > 0 && r[0] + r[2] < 595)
        // The answer dots after c)(ii)'s marks are left out.
        let cii = qs.first { $0.key == "1.3.2" }!
        #expect(cii.regions.allSatisfy { $0.rect[1] + $0.rect[3] < 400 })
    }

    @Test func aSecondSplitReplacesTheFirst() async {
        let lib = Library(engine: SyncEngine(device: "D", keys: nil, encrypted: false))
        let page = [PageRegion(page: 0, rect: [0, 0, 595, 842])]
        for key in ["1", "2", "3"] {
            _ = await lib.addProblem(sourceKey: "item:x", key: key, pages: page, marks: nil, level: .other, label: "Paper Q\(key)")
        }
        _ = await lib.addProblem(sourceKey: "item:y", key: "2", pages: page, marks: nil, level: .other, label: "Other Q2")
        #expect(await lib.problems().allSatisfy { $0.splitVersion == PaperSplitter.version })
        await lib.removeProblems(sourceKey: "item:x", keeping: ["1", "1.3"])
        let left = await lib.problems().map { "\($0.sourceKey)/\($0.key)" }.sorted()
        #expect(left == ["item:x/1", "item:y/2"])
    }

    @Test func proseIsWordsNotAnswerLines() {
        #expect(PaperSplitter.isProse("Photons made in the core take a random walk"))
        #expect(!PaperSplitter.isProse("........................ m s−1"))
        #expect(!PaperSplitter.isProse("Turn over for the next question"))
        #expect(!PaperSplitter.isProse("(10)"))
    }
}
