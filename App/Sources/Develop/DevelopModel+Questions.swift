import Foundation
import TroveCore

/// New questions in the style of real papers (learn-pivot plan §C2.3): only when you tap, through your own key.
/// Real questions on the same topic, with their real schemes, are the examples; the specification statement is
/// what the new question tests. What passes the checks is saved as a Trove-made note, labelled honestly, and
/// practised like any other question.
extension DevelopModel {
    /// Real questions to learn from: the same statement or skill first, in the same course, with text and scheme.
    func examples(like p: Problem, limit: Int = 4) -> [QuestionRequest.Example] {
        let course = p.sourceKey.hasPrefix("cat:") ? spec(ofDoc: String(p.sourceKey.dropFirst(4)))?.id : nil
        let mine = Set(p.skills)
        func usable(_ q: Problem) -> QuestionRequest.Example? {
            let text = self.text(of: q), scheme = self.scheme(of: q) ?? ""
            guard text.count > 20, scheme.count > 5, !q.label.hasPrefix("Trove-made") else { return nil }
            return .init(id: q.sourceKey + "#" + q.key, label: q.label, question: text, scheme: scheme, marks: q.marks)
        }
        var out: [QuestionRequest.Example] = []
        if let e = usable(p) { out.append(e) }
        let ranked = practisable.filter { $0.id != p.id }.sorted { a, b in
            let sa = mine.intersection(a.skills).count, sb = mine.intersection(b.skills).count
            let ca = course.map { a.sourceKey.hasPrefix("cat:\($0)-") } ?? false, cb = course.map { b.sourceKey.hasPrefix("cat:\($0)-") } ?? false
            return sa != sb ? sa > sb : ca != cb ? ca : a.id < b.id
        }
        for q in ranked where out.count < limit && !mine.isDisjoint(with: q.skills) {
            if let e = usable(q) { out.append(e) }
        }
        return out
    }

    /// The specification statements a question tests (its spec concept), else its topic's name.
    func specPoints(for p: Problem) -> [String] {
        let all = specStatements.values.flatMap { $0 }
        let points = all.filter { p.skills.contains($0.concept) }.map { "\($0.label): \($0.text.prefix(400))" }
        return points.isEmpty ? [topic(skills: p.skills, label: p.label)] : points
    }

    /// "More like this": writes `count` questions like `p`, checks them, and saves what passes. Returns how many.
    func makeQuestions(like p: Problem, count: Int = 2) async throws -> Int {
        guard let ai = app?.ownAI, let library = app?.library else {
            throw DevelopError("New questions are written by your AI: set it up in Settings → AI.")
        }
        let examples = examples(like: p)
        let spec = p.sourceKey.hasPrefix("cat:") ? spec(ofDoc: String(p.sourceKey.dropFirst(4))) : nil
        let board = spec.map { boardName($0.board) } ?? "Your papers"
        let paper = docId(p).flatMap { id in spec?.docs.first { $0.id == id }?.paper }
        let points = specPoints(for: p)
        let course = courseName(p.sourceKey)
        // The shared bank first (plan §C7): unseen questions others' devices wrote for the same spec point cost nothing.
        var fromBank = 0
        if let spec, let relay = app?.vault.relayClient, let file = try? await relay.bank(spec.id) {
            for e in QuestionBank.pick(file, specPoints: points, seen: Self.bankSeen, count: count) {
                await save(e.question, brief: e.brief, effort: e.effort, model: e.model, skills: p.skills, level: p.level, topic: topic(skills: p.skills, label: p.label), board: board, code: spec.code, paper: paper,
                           course: course, examples: [], bank: (e.id, spec.id))
                fromBank += 1
            }
        }
        guard fromBank < count else {
            await app?.reload()
            await reload()
            message = "\(fromBank) question\(fromBank == 1 ? "" : "s") from the shared bank, in the style of \(board)."
            return fromBank
        }
        let request = QuestionRequest(board: board, spec: spec?.id ?? "upload", paper: paper, level: p.level.rawValue, examples: examples,
                                      specPoints: points, questions: count - fromBank, totalMarks: p.marks)
        let report = try await QuestionWriter.write(request, model: ai)
        let share = spec != nil && QuestionBank.shareable(request) && app?.isOn(.shareQuestions) == true
        for made in report.made {
            var bank: (String, String)?
            if share, let spec, let relay = app?.vault.relayClient,
               let id = try? await relay.addToBank(made.question, spec: spec.id, brief: made.brief, model: made.model, effort: made.effort) {
                bank = (id, spec.id)
            }
            await save(made.question, brief: made.brief, effort: made.effort, model: made.model, skills: p.skills, level: p.level, topic: topic(skills: p.skills, label: p.label), board: board, code: spec?.code ?? "",
                       paper: paper, course: course, examples: examples, bank: bank)
        }
        await app?.reload()
        await reload()
        message = report.made.isEmpty && fromBank == 0
            ? "No new question passed its checks this time (\(report.dropped.count) dropped). Try again, or practise the real ones."
            : "\(report.made.count + fromBank) new question\(report.made.count + fromBank == 1 ? "" : "s") ready, in the style of \(board)"
              + (fromBank > 0 ? " (\(fromBank) from the shared bank)" : "") + (report.rewrites > 0 ? " (\(report.rewrites) rewritten once)." : ".")
        return report.made.count + fromBank
    }

    /// Bank questions this device has taken (bank id), and which note holds each (note id → bank id, course).
    static var bankSeen: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "bank.seen") ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "bank.seen") }
    }
    static var bankNotes: [String: [String]] {
        get { (UserDefaults.standard.dictionary(forKey: "bank.notes") as? [String: [String]]) ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "bank.notes") }
    }

    /// The bank question behind a problem, if it came from (or went to) the bank.
    func bankRef(_ p: Problem) -> (id: String, spec: String)? {
        guard let note = itemId(p), let v = Self.bankNotes[note], v.count == 2 else { return nil }
        return (v[0], v[1])
    }

    /// Saves one question as a Trove-made note and its problem, labelled honestly, linked to its examples.
    private func save(_ q: GeneratedQuestion, brief: String, effort: String, model: String, skills: [String], level: ProblemLevel, topic: String, board: String, code: String,
                      paper: String?, course: String, examples: [QuestionRequest.Example], bank: (String, String)?, source: String? = nil) async {
        guard let library = app?.library else { return }
        let label = QuestionWriter.label(board: board, spec: code, paper: paper)
        let body = q.questionText + "\n\n**Answer:** " + q.schemeText
        let note = await library.addNote(title: "Trove-made: \(topic)", body: body, folder: ["Learn", "Trove-made", course])
        let id = await library.addProblem(sourceKey: "item:\(note)", key: "1", pages: [], marks: q.totalMarks, level: level,
                                          label: label, skills: skills, splitBy: "user")
        _ = await library.engine.set(["origin": "ai", "brief": .string(brief), "effort": .string(effort), "model": .string(model)],
                                     record: id, kind: Develop.problemKind)
        for e in examples {
            let parts = e.id.split(separator: "#", maxSplits: 1).map(String.init)
            if parts.count == 2 { _ = await library.setEdge(from: id, to: Develop.problemId(sourceKey: parts[0], key: parts[1]), type: .madeFrom, state: .accepted, origin: .ai) }
        }
        // Made from your own item: it's the source you can open (plan §C2.3, "labelled honestly").
        if let source { _ = await library.setEdge(from: id, to: source, type: .madeFrom, state: .accepted, origin: .ai) }
        typedQuestions[note] = (q.questionText, q.schemeText)
        if let (bankId, spec) = bank {
            Self.bankSeen.insert(bankId)
            Self.bankNotes[note] = [bankId, spec]
        }
    }

    /// "This is wrong" on a Trove-made question: it goes, and its note goes to Recently deleted.
    func reportWrong(_ p: Problem) async {
        guard let library = app?.library, let note = itemId(p) else { return }
        if let ref = bankRef(p) { try? await app?.vault.relayClient?.bankFlag(ref.id, spec: ref.spec) }
        await library.removeProblems(sourceKey: p.sourceKey, keeping: [])
        await library.delete(note)
        await app?.reload()
        await reload()
        message = "Removed. Trove won't show it again."
    }

    // MARK: Practise this (learn-pivot plan §6)

    /// Makes questions from any note, PDF, sketch or lecture, with the item as their source; real questions on the
    /// same topic (an `about` edge) are the style to copy when there are some. Never shared. Starts practising them.
    func practiseThis(_ item: Item, count: Int = 3) async throws {
        guard let ai = app?.ownAI, let library = app?.library else {
            throw DevelopError("Practise this writes questions with your AI: set it up in Settings → AI.")
        }
        let material = LearningMaterial.text(of: item)
        guard material.count > 40 else { throw DevelopError("There isn't enough here to make questions from yet.") }
        let topics = Set(await library.edges().filter { $0.from == item.id && $0.type == .about && $0.state == .accepted }.map(\.to))
        let like = practisable.first { !topics.isDisjoint(with: $0.skills) }
        let realOnes = like.map { self.examples(like: $0) } ?? []
        let spec = like.flatMap { $0.sourceKey.hasPrefix("cat:") ? self.spec(ofDoc: String($0.sourceKey.dropFirst(4))) : nil }
        let board = spec.map { boardName($0.board) } ?? "Your notes"
        let request = QuestionRequest(board: board, spec: spec?.id ?? "notes", level: like?.level.rawValue ?? "other", examples: realOnes,
                                      specPoints: like.map { specPoints(for: $0) } ?? [item.displayTitle], material: material, questions: count)
        let report = try await QuestionWriter.write(request, model: ai)
        let before = Set(problems.map(\.id))
        let skills = like?.skills ?? Array(topics)
        for made in report.made {
            await save(made.question, brief: made.brief, effort: made.effort, model: made.model, skills: skills, level: like?.level ?? .other, topic: item.displayTitle, board: board, code: spec?.code ?? "",
                       paper: nil, course: like.map { courseName($0.sourceKey) } ?? "My notes", examples: realOnes, bank: nil, source: item.id)
        }
        await app?.reload()
        await reload()
        let new = problems.filter { !before.contains($0.id) }
        guard !new.isEmpty else { message = "No question passed its checks this time. Try again."; return }
        session = Session(problems: Practice.interleave(new), seed: 1)
        message = "\(new.count) question\(new.count == 1 ? "" : "s") from \(item.displayTitle)."
    }
}
