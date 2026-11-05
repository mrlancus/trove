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
        let request = QuestionRequest(board: board, spec: spec?.id ?? "upload", paper: paper, level: p.level.rawValue, examples: examples,
                                      specPoints: specPoints(for: p), questions: count, totalMarks: p.marks)
        let report = try await QuestionWriter.write(request, model: ai)
        let course = courseName(p.sourceKey)
        for made in report.made {
            let q = made.question
            let label = QuestionWriter.label(board: board, spec: spec?.code ?? "", paper: paper)
            let body = q.questionText + "\n\n**Answer:** " + q.schemeText
            let note = await library.addNote(title: "Trove-made: \(topic(skills: p.skills, label: p.label))", body: body,
                                             folder: ["Learn", "Trove-made", course])
            let id = await library.addProblem(sourceKey: "item:\(note)", key: "1", pages: [], marks: q.totalMarks, level: p.level,
                                              label: label, skills: p.skills, splitBy: "user")
            _ = await library.engine.set(["origin": "ai", "brief": .string(made.brief), "effort": .string(made.effort), "model": .string(made.model)],
                                     record: id, kind: Develop.problemKind)
            for e in examples {
                let parts = e.id.split(separator: "#", maxSplits: 1).map(String.init)
                if parts.count == 2 { _ = await library.setEdge(from: id, to: Develop.problemId(sourceKey: parts[0], key: parts[1]), type: .madeFrom, state: .accepted, origin: .ai) }
            }
            typedQuestions[note] = (q.questionText, q.schemeText)
        }
        await app?.reload()
        await reload()
        message = report.made.isEmpty
            ? "No new question passed its checks this time (\(report.dropped.count) dropped). Try again, or practise the real ones."
            : "\(report.made.count) new question\(report.made.count == 1 ? "" : "s") ready, in the style of \(board)" + (report.rewrites > 0 ? " (\(report.rewrites) rewritten once)." : ".")
        return report.made.count
    }

    /// "This is wrong" on a Trove-made question: it goes, and its note goes to Recently deleted.
    func reportWrong(_ p: Problem) async {
        guard let library = app?.library, let note = itemId(p) else { return }
        await library.removeProblems(sourceKey: p.sourceKey, keeping: [])
        await library.delete(note)
        await app?.reload()
        await reload()
        message = "Removed. Trove won't show it again."
    }
}
