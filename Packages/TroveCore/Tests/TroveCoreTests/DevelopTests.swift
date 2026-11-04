import Foundation
import Testing
@testable import TroveCore
import Crypto

/// Develop's first slice (docs/DEVELOP_PLAN.md §D phase 1; docs/testing/develop.md TEST-DEV-001 on).
@Suite struct DevelopTests {
    static func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")))
    }

    static func attempt(_ o: [String: JSONValue]) -> Attempt {
        Attempt(id: o["id"]?.string ?? "", problem: o["problem"]?.string ?? "", skills: o["skills"]?.stringArray ?? [], at: o["at"]?.number ?? 0,
                hint: Int(o["hint"]?.number ?? 0), marking: Marking(rawValue: o["marking"]?.string ?? "") ?? .none, score: o["score"]?.number,
                uncertain: o["uncertain"]?.bool ?? false, b: o["b"]?.number ?? 0, sourceKey: o["source"]?.string ?? "")
    }

    static func r4(_ x: Double) -> Double { (x * 10_000).rounded() / 10_000 }

    // TEST-DEV-001
    @Test func theWorkedExamplesComeOutExactly() throws {
        let doc = try JSONDecoder().decode(JSONValue.self, from: Self.fixture("mastery-cases"))
        let cases = try #require(doc.object?["cases"]?.array)
        #expect(cases.count == 6)
        for c in cases {
            let o = try #require(c.object)
            let name = o["name"]?.string ?? ""
            let attempts = (o["attempts"]?.array ?? []).compactMap(\.object).map(Self.attempt)
            let e = try #require(o["expect"]?.object)
            let s = Mastery.evaluate(skill: "concept.conservation-of-momentum", attempts)
            #expect(Self.r4(s.ability) == e["ability"]?.number, "\(name): ability \(s.ability)")
            #expect(Self.r4(s.information) == e["information"]?.number, "\(name): information \(s.information)")
            #expect(s.mastery.map(Self.r4) == e["mastery"]?.number, "\(name): mastery \(String(describing: s.mastery))")
            #expect(s.memory.map { Self.r4($0.stability) } == e["stability"]?.number, "\(name): stability")
            if let d = e["difficulty"]?.number { #expect(s.memory.map { Self.r4($0.difficulty) } == d, "\(name): difficulty") }
            if let days = e["intervalDays"]?.number, let m = s.memory {
                #expect(Self.r4(FSRS.interval(stability: m.stability, retention: MasteryConstants.standard.skillRetention)) == days, "\(name): interval")
            }
            if let days = e["dueDays"]?.number, let m = s.memory, let due = s.due { #expect((due - m.last) / 86_400_000 == days, "\(name): due") }
            #expect(s.proficient == e["proficient"]?.bool, "\(name): proficient")
            #expect(Double(s.attempts) == e["attempts"]?.number, "\(name): counted")
            #expect(Double(s.trivial) == e["trivial"]?.number, "\(name): trivial")
        }
    }

    // TEST-DEV-002
    @Test func oneSuccessIsNeverMasteryAndWhySaysWhy() {
        let one = Mastery.evaluate(skill: "s", [Attempt(id: "a", problem: "p", skills: ["s"], at: 0, hint: 0, marking: .selfMarked, score: 1, b: 3, sourceKey: "x")])
        #expect(!one.proficient)
        #expect(one.why.contains("1 success"))
        #expect(one.why.contains("2 more"))
        // Reading the full solution after failing brings the skill back the next day.
        let failed = Mastery.evaluate(skill: "s", [Attempt(id: "a", problem: "p", skills: ["s"], at: 0, hint: 5, marking: .selfMarked, score: 1, b: 0, sourceKey: "x")])
        #expect(failed.due == 86_400_000)
        // Two failures more than a day after the last success point at the prerequisites.
        let day = 86_400_000.0
        let slipping = Mastery.evaluate(skill: "s", [
            Attempt(id: "a", problem: "p1", skills: ["s"], at: 0, hint: 0, marking: .selfMarked, score: 1, b: 0, sourceKey: "x"),
            Attempt(id: "b", problem: "p2", skills: ["s"], at: 3 * day, hint: 0, marking: .selfMarked, score: 0, b: 0, sourceKey: "x"),
            Attempt(id: "c", problem: "p3", skills: ["s"], at: 6 * day, hint: 0, marking: .selfMarked, score: 0.2, b: 0, sourceKey: "x"),
        ])
        #expect(slipping.needsPrerequisites)
        #expect(slipping.lastWasFailure)
    }

    // TEST-DEV-003
    @Test func idsAreStableAndSlugsFold() {
        #expect(Develop.slug("Conservation of Momentum") == "conservation-of-momentum")
        #expect(Develop.slug("  Énergie cinétique!! ") == "energie-cinetique")
        #expect(Develop.conceptId("Conservation of momentum") == Develop.conceptId("conservation  of MOMENTUM"))
        #expect(Develop.edgeId(from: "a", type: .confusedWith, to: "b") == Develop.edgeId(from: "b", type: .confusedWith, to: "a"))
        #expect(Develop.edgeId(from: "a", type: .about, to: "b") != Develop.edgeId(from: "b", type: .about, to: "a"))
        #expect(Develop.edgeId(from: "item.1", type: .about, to: "concept.x") == "edge." + String("item.1\nabout\nconcept.x".sha256Hex.prefix(12)))
    }

    // TEST-DEV-004 (TEST-GRAPH-010)
    @Test func twoDevicesMakeTheSameConceptAndEdgeOffline() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("develop-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let a = SyncEngine(device: "A", keys: nil, encrypted: false, transports: [FolderTransport(root: root)])
        let b = SyncEngine(device: "B", keys: nil, encrypted: false, transports: [FolderTransport(root: root)])
        let la = Library(engine: a), lb = Library(engine: b)
        let ca = await la.addConcept("Conservation of momentum", type: .skill)
        let cb = await lb.addConcept("conservation of Momentum", type: .skill)
        #expect(ca == cb)
        await la.setEdge(from: "item.photo", to: ca, type: .about, state: .accepted, origin: .user)
        await lb.setEdge(from: "item.photo", to: cb, type: .about, state: .suggested, origin: .ai, confidence: 0.6)
        _ = await a.sync(); _ = await b.sync(); _ = await a.sync()
        let ea = await la.edges(), eb = await lb.edges()
        #expect(ea.count == 1 && eb.count == 1)
        #expect(ea == eb)
        #expect(await la.concepts().count == 1)
    }

    // TEST-DEV-005 (TEST-GRAPH-011)
    @Test func aRejectedLinkStaysRejected() async {
        let lib = Library(engine: SyncEngine(device: "A", keys: nil, encrypted: false))
        let c = await lib.addConcept("Impulse")
        await lib.setEdge(from: "item.photo", to: c, type: .about, state: .suggested, origin: .ai)
        await lib.setEdge(from: "item.photo", to: c, type: .about, state: .rejected, origin: .user)
        // The AI suggests it again: nothing changes.
        await lib.setEdge(from: "item.photo", to: c, type: .about, state: .suggested, origin: .ai)
        let edges = await lib.edges()
        #expect(edges.count == 1 && edges[0].state == .rejected)
        let index = EdgeIndex(edges: edges, concepts: await lib.concepts())
        #expect(index.isRejected(from: "item.photo", type: .about, to: c))
        #expect(index.from("item.photo").isEmpty)
        #expect(index.from("item.photo", includeRejected: true).count == 1)
        // I can still accept it myself.
        await lib.setEdge(from: "item.photo", to: c, type: .about, state: .accepted, origin: .user)
        #expect(await lib.edges().first?.state == .accepted)
    }

    // TEST-DEV-006 (TEST-GRAPH-012)
    @Test func everyLinkWorksBothWaysAndThroughMerges() async {
        let lib = Library(engine: SyncEngine(device: "A", keys: nil, encrypted: false))
        let momentum = await lib.addConcept("Conservation of momentum", type: .skill)
        let dup = await lib.addConcept("Momentum conservation", type: .skill)
        await lib.setEdge(from: "item.photo", to: momentum, type: .about, state: .accepted, origin: .user)
        await lib.setEdge(from: "problem.q2", to: dup, type: .tests, state: .accepted, origin: .rule)
        await lib.setEdge(from: "card.1", to: "item.photo", type: .madeFrom, state: .accepted, origin: .user)
        // The two names are the same words: an automatic merge every device makes alike.
        let merges = ConceptMatch.automaticMerges(await lib.concepts())
        #expect(merges.count == 1)
        let (loser, winner) = merges[0]
        #expect(winner == min(momentum, dup))
        await lib.mergeConcept(loser, into: winner)
        var index = EdgeIndex(edges: await lib.edges(), concepts: await lib.concepts())
        #expect(Set(index.to(winner).map(\.from)) == ["item.photo", "problem.q2"])
        #expect(index.from("problem.q2", type: .tests).map(\.to) == [dup])
        #expect(index.resolve(dup) == winner)
        #expect(index.to("item.photo", type: .madeFrom).map(\.from) == ["card.1"])
        // Undoing the merge restores both.
        await lib.unmergeConcept(loser)
        index = EdgeIndex(edges: await lib.edges(), concepts: await lib.concepts())
        #expect(index.to(winner).count == 1)
        #expect(index.resolve(loser) == loser)
    }

    @Test func theIndexFollowsTheChangeFeed() async {
        let engine = SyncEngine(device: "A", keys: nil, encrypted: false)
        let lib = Library(engine: engine)
        var index = EdgeIndex()
        var token = await engine.changes(since: 0).token
        let c = await lib.addConcept("Work")
        let e = await lib.setEdge(from: "item.n", to: c, type: .about, state: .accepted, origin: .user)
        let changes = await engine.changes(since: token)
        token = changes.token
        let records = await engine.records
        index.apply(changes) { id in records.first { $0.id == id } }
        #expect(index.to(c).map(\.id) == [e])
        await engine.delete(e)
        let gone = await engine.changes(since: token)
        index.apply(gone) { _ in nil }
        #expect(index.to(c).isEmpty)
    }

    @Test func conceptsMentionedInText() {
        func concept(_ name: String) -> Concept {
            Concept(Record(id: Develop.conceptId(name), kind: Develop.conceptKind, fields: ["name": .string(name)], createdHLC: "1", updatedHLC: "1"))
        }
        let all = [concept("Momentum"), concept("Kinetic energy"), concept("Impulse")]
        let text = "Momentum is conserved in collisions. Kinetic energy isn't always. Momentum p = mv."
        #expect(ConceptMatch.mentioned(in: text, concepts: all) == [Develop.conceptId("Kinetic energy"), Develop.conceptId("Momentum")])
        #expect(ConceptMatch.compare("Conservation of momentum", "momentum conservation") == .same)
        #expect(ConceptMatch.compare("Newton's second law", "Newton's third law") == .different)
    }

    // TEST-DEV-007
    @Test func practicePicksAreSeededFreshAndFiltered() {
        let day = 86_400_000.0, now = 100 * day
        func problem(_ i: Int, skill: String, marks: Int, level: ProblemLevel = .alevel) -> Problem {
            Problem(Record(id: "problem.\(i)", kind: Develop.problemKind, fields: [
                "source": ["catalogue": .string("aqa-7408-1-2023-06-qp")], "key": .string("\(i).1"), "marks": .number(Double(marks)),
                "level": .string(level.rawValue), "skills": JSONValue([skill]),
            ], createdHLC: "1", updatedHLC: "1"))
        }
        let problems = (0..<40).map { problem($0, skill: $0 % 2 == 0 ? "s.weak" : "s.strong", marks: 1 + $0 % 6) }
        let attempts = [
            Attempt(id: "a1", problem: "problem.1", skills: ["s.strong"], at: now - 1 * day, hint: 0, marking: .selfMarked, score: 1, b: 0, sourceKey: "x"),
            Attempt(id: "a2", problem: "problem.3", skills: ["s.strong"], at: now - 10 * day, hint: 0, marking: .selfMarked, score: 1, b: 0, sourceKey: "x"),
        ]
        let skills = Mastery.evaluate(attempts)
        let first = Practice.pick(10, from: problems, attempts: attempts, skills: skills, now: now, seed: 7)
        let again = Practice.pick(10, from: problems, attempts: attempts, skills: skills, now: now, seed: 7)
        #expect(first.map(\.id) == again.map(\.id))
        #expect(Set(first.map(\.id)).count == 10)
        #expect(Practice.pick(10, from: problems, attempts: attempts, skills: skills, now: now, seed: 8).map(\.id) != first.map(\.id))
        // Done yesterday: not offered again yet; done 10 days ago: fine.
        #expect(!first.contains { $0.id == "problem.1" })
        let all = Practice.pick(100, from: problems, attempts: attempts, skills: skills, now: now, seed: 1)
        #expect(all.count == 39)
        var f = Practice.Filter()
        f.minMarks = 3; f.maxMarks = 4; f.skills = ["s.weak"]
        let filtered = Practice.pick(100, from: problems, attempts: attempts, skills: skills, filter: f, now: now, seed: 1)
        #expect(!filtered.isEmpty && filtered.allSatisfy { ($0.marks ?? 0) >= 3 && ($0.marks ?? 0) <= 4 && $0.skills == ["s.weak"] })
        // The weak (never attempted) skill's problems come up more often than the practised one's.
        var weak = 0
        for seed in 0..<200 as Range<UInt64> {
            if Practice.pick(1, from: problems, attempts: attempts, skills: skills, now: now, seed: seed).first?.skills == ["s.weak"] { weak += 1 }
        }
        #expect(weak > 100)
    }

    // TEST-DEV-008
    @Test func hardMeansHardToSolveNotLongOrManyMarks() {
        func problem(_ level: ProblemLevel, marks: Int, avg: Double? = nil) -> Problem {
            var f: [String: JSONValue] = ["level": .string(level.rawValue), "marks": .number(Double(marks))]
            if let avg { f["nationalAverage"] = .number(avg) }
            return Problem(Record(id: "p", kind: Develop.problemKind, fields: f, createdHLC: "1", updatedHLC: "1"))
        }
        #expect(!Difficulty.isHard(problem(.gcse, marks: 12, avg: 0.1)))
        #expect(!Difficulty.isHard(problem(.alevel, marks: 9)))
        #expect(Difficulty.isHard(problem(.alevel, marks: 2, avg: 0.3)))
        #expect(Difficulty.isHard(problem(.alevel, marks: 2), ownEstimate: 1.2, attempts: 5))
        #expect(!Difficulty.isHard(problem(.alevel, marks: 2), ownEstimate: 1.2, attempts: 4))
        #expect(Difficulty.isHard(problem(.competition, marks: 1)))
        #expect(Self.r4(Difficulty.b(problem(.alevel, marks: 4, avg: 0.25))) == 1.0986)
        #expect(Difficulty.b(problem(.gcse, marks: 4)) == -1)
        #expect(DevelopAI.route(.mark, hard: false) == .init(model: "claude-haiku-5-5", effort: "low", maxTokens: 1_200))
        #expect(DevelopAI.route(.mark, hard: true).effort == "medium")
        #expect(DevelopAI.route(.mark, hard: false, retryOfUncertain: true).effort == "medium")
        #expect(DevelopAI.Task.allCasesForTest.allSatisfy { DevelopAI.route($0, hard: true).model == "claude-haiku-5-5" })
    }

    static let catalogueFolder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("catalogue")

    // TEST-DEV-009 (TEST-CUR-001, TEST-CUR-003)
    @Test func theCatalogueIsLinksOnBoardSitesOnly() throws {
        let cat = try Catalogue.decode(Data(contentsOf: Self.catalogueFolder.appendingPathComponent("index.json")))
        let hosts = ["aqa": ["aqa.org.uk", "cdn.sanity.io"], "ocr": ["ocr.org.uk"], "eduqas": ["wjec.co.uk", "eduqas.co.uk"],
                     "wjec": ["wjec.co.uk"], "cie": ["cambridgeinternational.org"]]
        #expect(Set(cat.specs.map(\.board)).isSubset(of: Set(hosts.keys)))
        #expect(cat.specs.allSatisfy { $0.docs.isEmpty }, "the index carries no documents")
        #expect(Set(cat.specs.map(\.id)).count == cat.specs.count)
        #expect(cat.specs(level: .gcse).count > 20 && cat.specs(level: .alevel).count > 20)
        // Every spec file: links on its board's own site, unique ids, never a mirror.
        for summary in cat.specs {
            let spec = try Catalogue.decodeSpec(Data(contentsOf: Self.catalogueFolder.appendingPathComponent("specs/\(summary.id).json")))
            #expect(spec.id == summary.id && !spec.questionPapers.isEmpty)
            #expect(Set(spec.docs.map(\.id)).count == spec.docs.count, "\(spec.id) has duplicate ids")
            for doc in spec.docs {
                let host = URL(string: doc.url)?.host ?? ""
                #expect(hosts[spec.board, default: []].contains { host == $0 || host.hasSuffix("." + $0) }, "\(doc.id) points at \(host)")
                #expect(!doc.url.lowercased().contains("physicsandmathstutor") && !doc.url.lowercased().contains("savemyexams"))
            }
        }
        let spec = try Catalogue.decodeSpec(Data(contentsOf: Self.catalogueFolder.appendingPathComponent("specs/aqa-7408.json")))
        #expect(spec.level == .alevel && spec.subject == "Physics")
        let qp = try #require(spec.docs.first { $0.id == "aqa-7408-2-2023-06-qp" })
        let (ms, er) = cat.companions(of: qp, in: spec)
        #expect(ms?.id == "aqa-7408-2-2023-06-ms")
        #expect(er?.id == "aqa-7408-2-2023-06-er")
        #expect(cat.label(qp, in: spec, question: "4.2") == "AQA 7408/2 June 2023 Q4.2")
        // Choosing one paper downloads it with its mark scheme and report, nothing else.
        #expect(Set(cat.downloadPlan(spec: spec, cached: [], papers: [qp.id]).map(\.id)) == [qp.id, "aqa-7408-2-2023-06-ms", "aqa-7408-2-2023-06-er"])
        #expect(cat.downloadPlan(spec: spec, cached: [qp.id]).count == spec.docs.filter { $0.type != .spec }.count - 1)
        #expect(cat.search("aqa phys", level: .alevel).contains { $0.id == "aqa-7408" })
        #expect(cat.layout(for: "aqa").parts != true && cat.layout(for: "ocr") == PaperSplitter.genericLayout)
    }

    // TEST-DEV-010
    @Test func aPaperSplitsIntoQuestionsWithMarksAndMatchesItsScheme() throws {
        let layout = try Catalogue.decode(Data(contentsOf: Self.catalogueFolder.appendingPathComponent("index.json"))).layout(for: "aqa")
        // Written for this test in AQA's layout (no board text).
        func line(_ page: Int, _ x: Double, _ y: Double, _ t: String) -> PaperSplitter.Line { .init(page: page, x: x, y: y, width: 400, height: 12, text: t) }
        let paper = [
            line(0, 40, 80, "0 1       A trolley rolls down a ramp onto a cushion."),
            line(0, 40, 120, "0 1 . 1   State what is meant by momentum."),
            line(0, 480, 140, "[1 mark]"),
            line(0, 40, 300, "0 1 . 2   Calculate the trolley's momentum at the bottom."),
            line(0, 90, 320, "Figure 1 shows the speed against time."),
            line(0, 480, 600, "[3 marks]"),
            line(1, 40, 60, "0 2 . 1   Explain why the cushion reduces the force."),
            line(1, 90, 80, "Use the idea of impulse in your answer."),
            line(1, 480, 200, "[2 marks]"),
            line(1, 200, 820, "Turn over"),
        ]
        let qs = PaperSplitter.split(paper, layout: layout)
        #expect(qs.map(\.key) == ["1", "1.1", "1.2", "2.1"])
        #expect(qs.map(\.marks) == [nil, 1, 3, 2])
        #expect(qs.map(\.parent) == [nil, "1", "1", "2"])
        // 1.2's region runs from its first line to the end of its page, so Figure 1 comes with it, after
        // question 1's stem; 1.1 follows its stem directly, so the two join.
        #expect(qs[2].regions == [PageRegion(page: 0, rect: [0, 80, 595, 40]), PageRegion(page: 0, rect: [0, 300, 595, 542])])
        #expect(qs[1].regions == [PageRegion(page: 0, rect: [0, 80, 595, 220])])
        #expect(qs[2].text.hasPrefix("0 1       A trolley"))
        #expect(qs[0].regions == [PageRegion(page: 0, rect: [0, 80, 595, 40])])
        let scheme = PaperSplitter.scheme([
            line(0, 40, 100, "01.1   mass × velocity (product of)"),
            line(0, 40, 140, "01.2   v from the graph: 2.4 m s−1"),
            line(0, 60, 160, "p = 0.50 × 2.4 = 1.2 kg m s−1"),
            line(1, 40, 60, "02.1   increases the time of the collision"),
        ], layout: layout)
        #expect(Set(scheme.keys) == ["1.1", "1.2", "2.1"])
        #expect(scheme["1.2"]?.contains("1.2 kg m s−1") == true)
        #expect(scheme["1.1"]?.contains("velocity") == true)
    }

    // TEST-DEV-011 (TEST-CARD-010)
    @Test func ankiExportKeepsGuidsSoReimportUpdates() {
        let card = StudyCard(id: "card.note1.abc", noteId: "note1", noteTitle: "Momentum", front: "p = ?", back: "m × v\nin kg m s⁻¹", state: nil)
        let other = StudyCard(id: "card.note1.def", noteId: "note1", noteTitle: "Momentum", front: "Unit of impulse <N s>?", back: "N\ts", state: nil)
        let tsv = AnkiExport.tsv([other, card])
        let lines = tsv.split(separator: "\n").map(String.init)
        #expect(lines[0...4] == ["#separator:tab", "#html:true", "#guid column:1", "#tags column:4", "#deck:Trove"])
        #expect(lines.count == 7)
        #expect(lines[5] == "\(AnkiExport.guid("card.note1.abc"))\tp = ?\tm × v<br>in kg m s⁻¹\ttrove::momentum")
        #expect(lines[6].contains("Unit of impulse &lt;N s&gt;?\tN    s"))
        // The same card always gets the same GUID; editing the back doesn't change it.
        var edited = card
        edited.back = "mv"
        #expect(AnkiExport.tsv([edited]).contains(AnkiExport.guid(card.id)))
        #expect(AnkiExport.guid(card.id) == "trove-" + String(card.id.sha256Hex.prefix(12)))
    }

    // TEST-DEV-012: the thin slice end to end, with no AI (DEVELOP_PLAN §D phase 1).
    @Test func photoToConceptsToPracticeToMasteryToAnki() async throws {
        let engine = SyncEngine(device: "IPAD", keys: nil, encrypted: false)
        let lib = Library(engine: engine, now: { Date(timeIntervalSince1970: 1_700_000_000) })
        // A whiteboard photo's text (read on the device) suggests concepts by their names.
        let momentum = await lib.addConcept("Momentum", type: .concept, origin: .spec)
        let conservation = await lib.addConcept("Conservation of momentum", type: .skill, origin: .spec)
        await lib.setEdge(from: conservation, to: momentum, type: .requires, state: .accepted, origin: .spec)
        let photo = "item.whiteboard"
        for c in ConceptMatch.mentioned(in: "Today: momentum. Conservation of momentum in collisions.", concepts: await lib.concepts()) {
            await lib.setEdge(from: photo, to: c, type: .about, state: .suggested, origin: .rule)
        }
        // A catalogue question tests the skill.
        let problem = await lib.addProblem(sourceKey: "cat:aqa-7408-1-2023-06-qp", key: "2.1", pages: [PageRegion(page: 3, rect: [0, 100, 595, 300])],
                                           marks: 3, level: .alevel, label: "AQA 7408/1 June 2023 Q2.1", skills: [conservation])
        // Practise: picked, answered, self-marked 2 of 3 against the scheme.
        let problems = await lib.problems()
        let picked = Practice.pick(1, from: problems, attempts: [], skills: [:], now: 1_700_000_000_000, seed: 3)
        #expect(picked.map(\.id) == [problem])
        let p = picked[0]
        await lib.recordAttempt(Attempt(id: "attempt.1", problem: p.id, skills: p.skills, at: 1_700_000_000_000, hint: 0, marking: .selfMarked,
                                        score: 2.0 / 3, b: Difficulty.b(p), sourceKey: p.sourceKey, label: p.label))
        let skills = Mastery.evaluate(await lib.attempts())
        let state = try #require(skills[conservation])
        #expect(state.attempts == 1 && !state.proficient)
        #expect(state.mastery.map(Self.r4) == Self.r4(Mastery.sigmoid(0.8 * (2.0 / 3 - 0.5))))
        // The miss is a gap; a card is drafted from it, and the card points at its source.
        await lib.setEdge(from: "attempt.1", to: momentum, type: .gap, state: .suggested, origin: .rule)
        await lib.setEdge(from: "card.attempt.1", to: "attempt.1", type: .madeFrom, state: .accepted, origin: .user)
        let index = EdgeIndex(edges: await lib.edges(), concepts: await lib.concepts())
        #expect(Set(index.from(photo, type: .about).map(\.to)) == [momentum, conservation])
        #expect(index.to(conservation, type: .tests).map(\.from) == [problem])
        #expect(index.to(momentum, type: .gap).map(\.from) == ["attempt.1"])
        #expect(index.from("card.attempt.1", type: .madeFrom).map(\.to) == ["attempt.1"])
        let tsv = AnkiExport.tsv([StudyCard(id: "card.attempt.1", noteId: "attempt.1", noteTitle: "Momentum", front: "Is momentum a vector?", back: "Yes", state: nil)])
        #expect(tsv.contains(AnkiExport.guid("card.attempt.1")))
        // Nothing here is an item, so the library (and older apps) don't show Develop's records as notes.
        #expect(await lib.items().isEmpty)
    }
}

extension DevelopAI.Task {
    static let allCasesForTest: [DevelopAI.Task] = [.mark, .hint, .tagConcepts, .splitHelp, .explain, .plan]
}

/// Marking (docs/testing/develop.md TEST-DEV-013, 014).
@Suite struct DevelopMarkingTests {
    // TEST-DEV-013
    @Test func schemeLinesBecomeTickablePoints() {
        let entry = "01.2   v from the graph: 2.4 m s−1          1     AO3\n   p = 0.50 × 2.4 = 1.2 kg m s−1    1\nMarks\n"
        let points = DevelopMarking.points(fromScheme: entry)
        #expect(points.map(\.text) == ["v from the graph: 2.4 m s−1", "p = 0.50 × 2.4 = 1.2 kg m s−1"])
        #expect(DevelopMarking.selfMarkScore(ticked: 1, marks: 2, points: 2) == 0.5)
        #expect(DevelopMarking.selfMarkScore(ticked: 3, marks: 2, points: 3) == 1)
        #expect(DevelopMarking.selfMarkScore(ticked: 1, marks: nil, points: 4) == 0.25)
    }

    // TEST-DEV-014
    @Test func aiMarksQuoteTheSchemeOrGoToReview() {
        let prompt = DevelopMarking.prompt(question: "Calculate p.", scheme: "01.2 p = mv", answer: "p = 1.2", marks: 2)
        #expect(prompt.hasPrefix(DevelopMarking.instructions))
        #expect(prompt.contains("<mark_scheme>\n01.2 p = mv\n</mark_scheme>"))
        #expect(DevelopMarking.prompt(question: "Q", scheme: nil, answer: "A", marks: nil).contains("none was found"))
        let good = #"{"points":[{"point":"v from graph","got":true,"quote":"v = 2.4","why":""},{"point":"p = mv","got":false,"quote":"","why":"no product"}],"marksAwarded":1,"confidence":0.9,"rationale":"","schemeQuestioned":false}"#
        let r = DevelopMarking.parse(good, marks: 2, hadScheme: true)
        #expect(r?.score == 0.5 && r?.uncertain == false && r?.marking == .aiScheme)
        let unquoted = #"{"points":[{"point":"","got":true,"quote":"","why":""}],"marksAwarded":1,"confidence":0.95,"rationale":"","schemeQuestioned":false}"#
        #expect(DevelopMarking.parse(unquoted, marks: 1, hadScheme: true)?.uncertain == true)
        let unsure = #"{"points":[],"marksAwarded":0,"confidence":0.4,"rationale":"","schemeQuestioned":false}"#
        #expect(DevelopMarking.parse(unsure, marks: 1, hadScheme: true)?.uncertain == true)
        let noScheme = #"{"points":[{"point":"uses p = mv","got":true,"quote":"p = mv","why":""}],"marksAwarded":1,"confidence":0.9,"rationale":"no scheme","schemeQuestioned":false}"#
        #expect(DevelopMarking.parse(noScheme, marks: 1, hadScheme: false)?.marking == .aiNoScheme)
        #expect(DevelopMarking.parse("not json", marks: 1, hadScheme: true) == nil)
        // An uncertain AI mark counts for nothing in the mastery model.
        let s = Mastery.evaluate(skill: "s", [Attempt(id: "a", problem: "p", skills: ["s"], at: 0, hint: 0, marking: .aiScheme, score: 1, uncertain: true, b: 0, sourceKey: "x")])
        #expect(s.mastery == nil)
    }
}

/// The hint ladder (TEST-DEV-015).
@Suite struct DevelopHintTests {
    @Test func eachLevelAsksForOnlyThatMuch() {
        let one = DevelopHints.prompt(level: 1, question: "Find p.", scheme: "p = mv", workSoFar: "", earlier: [])
        #expect(one.contains("a nudge"))
        #expect(one.contains("never state the final answer"))
        #expect(one.contains("(nothing yet)"))
        let five = DevelopHints.prompt(level: 9, question: "Find p.", scheme: nil, workSoFar: "m = 2", earlier: ["Think about momentum.", "p = mv"])
        #expect(five.contains("a full worked solution"))
        #expect(five.contains("1. Think about momentum.\n2. p = mv"))
        #expect(!five.contains("<mark_scheme>"))
        #expect(DevelopHints.levels.count == MasteryConstants.standard.independence.count - 1)
    }
}

/// The Anki package (TEST-CARD-011).
@Suite struct AnkiPackageTests {
    @Test func aPackageHoldsTheCardsWithStableGuidsAndOpens() throws {
        let cards = [
            StudyCard(id: "card.n1.aaa", noteId: "n1", noteTitle: "Momentum", front: "p = ?", back: "m × v", state: nil),
            StudyCard(id: "card.n1.bbb", noteId: "n1", noteTitle: "Momentum", front: "Unit of <impulse>?", back: "N s", state: nil),
        ]
        let data = try AnkiPackage.make(cards, now: 1_700_000_000_000)
        let zip = try ZipArchive(data)
        #expect(Set(zip.entries.map(\.path)) == ["collection.anki2", "media"])
        let media = try zip.data(for: try #require(zip.entries.first { $0.path == "media" }))
        #expect(String(decoding: media, as: UTF8.self) == "{}")
        let db = try SQLiteReader(try zip.data(for: try #require(zip.entries.first { $0.path == "collection.anki2" })))
        let col = try db.rows(try #require(db.table("col")))
        #expect(col.count == 1 && col[0]["ver"].int == 11)
        let models = try #require(col[0]["models"].string)
        #expect(models.contains("\"\(AnkiPackage.modelId)\"") && models.contains("{{Front}}"))
        let notes = try db.rows(try #require(db.table("notes"))).sorted { ($0["id"].int ?? 0) < ($1["id"].int ?? 0) }
        #expect(notes.map { $0["guid"].string } == cards.map { AnkiExport.guid($0.id) })
        #expect(notes[0]["flds"].string == "p = ?\u{1F}m × v")
        #expect(notes[1]["sfld"].string == "Unit of <impulse>?")
        #expect(notes.allSatisfy { $0["mid"].int == AnkiPackage.modelId })
        let cardRows = try db.rows(try #require(db.table("cards")))
        #expect(cardRows.count == 2 && cardRows.allSatisfy { $0["did"].int == AnkiPackage.deckId })
        // A later export of the same cards has the same GUIDs, so Anki updates them.
        let again = try SQLiteReader(try ZipArchive(try AnkiPackage.make(cards, now: 1_800_000_000_000)).data(for: try #require(try ZipArchive(try AnkiPackage.make(cards, now: 1_800_000_000_000)).entries.first { $0.path == "collection.anki2" })))
        #expect(Set(try again.rows(try #require(again.table("notes"))).compactMap { $0["guid"].string }) == Set(notes.compactMap { $0["guid"].string }))
        // Anki's checksum: the first 8 hex digits of SHA-1 of the stripped first field.
        #expect(AnkiPackage.checksum("p = ?") == Int64(String(Data(Insecure.SHA1.hash(data: Data("p = ?".utf8))).hex.prefix(8)), radix: 16))
    }
}

/// Campaigns (TEST-CUR-002).
@Suite struct CampaignTests {
    @Test func diagnosticFirstThenWhatSlipsAndNeverWhatsSafe() async {
        let day = 86_400_000.0, now = 1_700_000_000_000.0
        // "strong": three hard solves recently (proficient, safe); "weak": one miss; "new": nothing yet.
        let strong = (0..<3).map { Attempt(id: "s\($0)", problem: "p\($0)", skills: ["strong"], at: now - Double(3 - $0) * day, hint: 0,
                                           marking: .selfMarked, score: 1, b: 1.5, sourceKey: "src\($0)") }
        let weak = [Attempt(id: "w", problem: "q", skills: ["weak"], at: now - 2 * day, hint: 0, marking: .selfMarked, score: 0.2, b: 0, sourceKey: "x")]
        let states = Mastery.evaluate(strong + weak)
        let goal = CampaignPlanner.Goal(id: "campaign.bpho", name: "BPhO Round 1", deadline: now + 8 * day, minutesPerDay: 16)
        let plan = CampaignPlanner.plan(goal, skills: ["new", "strong", "weak"], states: states, now: now)
        #expect(plan.days.count == 9)
        #expect(plan.days.allSatisfy { $0.skills.count <= 2 })
        #expect(plan.days[0].diagnostic && plan.days[0].skills.first == "new")
        #expect(plan.days[0].skills.contains("weak"))
        #expect(!plan.days.flatMap(\.skills).contains("strong"))
        #expect(plan.proficient == ["strong"] && plan.total == 3)
        #expect(plan.why.hasPrefix("1 of 3 skills shown"))
        #expect(plan == CampaignPlanner.plan(goal, skills: ["weak", "strong", "new"], states: states, now: now))
        // Saved and read back like any record.
        let lib = Library(engine: SyncEngine(device: "A", keys: nil, encrypted: false))
        await lib.saveCampaign(goal)
        #expect(await lib.campaigns() == [goal])
    }
}

/// Chosen courses sync as records (TEST-CUR-005).
@Suite struct CourseTests {
    @Test func coursesSyncAndRemovingKeepsTheRecord() async {
        let lib = Library(engine: SyncEngine(device: "A", keys: nil, encrypted: false))
        await lib.setCourse(Course(spec: "aqa-7408", name: "AQA A-level Physics (7408)"))
        await lib.setCourse(Course(spec: "ocr-j249", name: "OCR GCSE Physics A (J249)"))
        #expect(await lib.courses().map(\.spec) == ["aqa-7408", "ocr-j249"])
        await lib.setCourse(Course(spec: "ocr-j249", name: "OCR GCSE Physics A (J249)", active: false))
        #expect(await lib.courses().map(\.spec) == ["aqa-7408"])
        #expect(Course.id("aqa-7408") == "course.aqa-7408")
    }
}

/// Papers from boards without their own layout (OCR, WJEC, Eduqas, Cambridge) split by the generic one (TEST-CUR-004).
@Suite struct GenericSplitTests {
    @Test func lettteredPartsSplitWhereverTheyStart() {
        // Written for this test in the common "1 (a) (i)" style (no board text).
        func line(_ page: Int, _ x: Double, _ y: Double, _ t: String) -> PaperSplitter.Line { .init(page: page, x: x, y: y, width: 400, height: 12, text: t) }
        let paper = [
            line(0, 40, 80, "1 A student drops a ball from a window."),
            line(0, 40, 110, "(a) Define acceleration. [1]"),
            line(0, 70, 160, "(b) (i) Calculate the speed after 2.0 s."),
            line(0, 90, 260, "speed = ....................... m s−1 [2]"),
            line(0, 70, 300, "(ii) Explain why air resistance can be ignored. [2]"),
            line(1, 40, 60, "2 (a) State Newton's first law. [1]"),
            line(1, 70, 120, "(b) A 3 kg mass rests on a table."),
            line(1, 90, 140, "Describe the forces on it. [3]"),
        ]
        let qs = PaperSplitter.splitPaper(paper, layout: PaperSplitter.genericLayout)
        #expect(qs.map(\.key) == ["1", "1.1", "1.2.1", "1.2.2", "2.1", "2.2"])
        #expect(qs.map(\.marks) == [nil, 1, 2, 2, 1, 3])
        #expect(qs.map(\.parent) == [nil, "1", "1.2", "1.2", "2", "2"])
        // 1(b)(ii) carries the question's stem.
        #expect(qs[3].text.hasPrefix("1 A student drops a ball") && qs[3].text.contains("Explain why air resistance"))
        #expect(qs[5].text.contains("3 kg mass"), "a number inside the text stays text")
        // The best of the board's layout and the generic one.
        let aqa = Catalogue.Layout(question: #"^(\d \d)(?: \. (\d+))?(?:\s|$)"#, marks: #"\[(\d+) marks?\]"#, scheme: #"^(\d\d)\.(\d+)(?:\s|$)"#)
        #expect(PaperSplitter.splitBest(paper, layouts: [aqa, PaperSplitter.genericLayout]).layout == PaperSplitter.genericLayout)
        let scheme = PaperSplitter.schemePaper([
            line(0, 40, 100, "1 (a) rate of change of velocity B1"),
            line(0, 40, 140, "1(b)(i) v = u + at = 19.6 C1 A1"),
            line(0, 40, 200, "2a an object stays at rest or moves at constant velocity unless a resultant force acts"),
        ], layout: PaperSplitter.genericLayout)
        #expect(Set(scheme.keys) == ["1.1", "1.2.1", "2.1"])
        #expect(scheme["1.2.1"]?.contains("19.6") == true)
    }
}

/// Your own PDFs split into questions (TEST-DEV-028).
@Suite struct UploadSplitTests {
    @Test func numberedWorksheetsSplitAndStrayNumbersStayText() {
        func line(_ y: Double, _ t: String, page: Int = 0) -> PaperSplitter.Line { .init(page: page, x: 50, y: y, width: 400, height: 12, text: t) }
        let lines = PaperSplitter.numberParts([
            line(60, "1. A ball of mass 0.2 kg moves at 3 m/s."),
            line(80, "(a) Calculate its momentum. [2]"),
            line(120, "3 kg of water is then added to the cart."),
            line(160, "1(b) Explain why momentum is conserved. (3 marks)"),
            line(200, "Q2 A cart collides with a wall."),
            line(240, "2 c The force on the wall. [4]"),
            line(280, "7 apples were in the box."),
        ])
        let qs = PaperSplitter.split(lines, layout: PaperSplitter.uploadLayout)
        // "(a)" on its own line is part 1.1 of the question above it.
        #expect(qs.map(\.key) == ["1", "1.1", "1.2", "2", "2.3"])
        #expect(qs.map(\.marks) == [nil, 2, 3, nil, 4])
        #expect(qs[1].text.contains("3 kg of water"))
        #expect(qs.last?.text.contains("7 apples") == true)
    }
}

/// Real papers from each board, split as the apps would (TEST-CUR-004). Runs only with
/// TROVE_SPLIT_LINES set to a folder made by scripts/catalogue/split-sample.py (the papers aren't in the repo).
@Suite struct RealPaperSplitTests {
    struct Sample: Decodable {
        struct L: Decodable { var page: Int; var x, y, width, height: Double; var text: String }
        var doc: String
        var board: String
        var layout: Catalogue.Layout?
        var width, height: Double
        var lines: [L]
    }

    @Test func eachBoardsPaperSplitsIntoMarkedQuestions() throws {
        guard let folder = ProcessInfo.processInfo.environment["TROVE_SPLIT_LINES"] else { return }
        let files = try FileManager.default.contentsOfDirectory(atPath: folder).filter { $0.hasSuffix(".json") }.sorted()
        #expect(!files.isEmpty)
        for f in files {
            let s = try JSONDecoder().decode(Sample.self, from: Data(contentsOf: URL(fileURLWithPath: folder).appendingPathComponent(f)))
            let lines = s.lines.map { PaperSplitter.Line(page: $0.page, x: $0.x, y: $0.y, width: $0.width, height: $0.height, text: $0.text) }
            let qs = PaperSplitter.splitBest(lines, layouts: [s.layout, PaperSplitter.genericLayout].compactMap { $0 }, pageHeight: s.height, pageWidth: s.width).questions
            let total = qs.compactMap(\.marks).reduce(0, +)
            print("SPLIT \(s.doc): \(qs.count) questions, \(total) marks: \(qs.prefix(14).map { "\($0.key)[\($0.marks!)]" }.joined(separator: " "))")
            #expect(qs.count >= 5, "\(s.doc) split into only \(qs.count) marked questions")
        }
    }
}
