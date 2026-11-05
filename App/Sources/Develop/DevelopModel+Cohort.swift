import Foundation
import PDFKit
import TroveCore

/// How everyone else did (study-with-friends prompt §1): after you mark a past-paper question, the examiner
/// report's own figure for it, read on this device from the downloaded report (`ExaminerReport`). Only what the
/// report prints; nothing estimated, nothing shared, no AI.
extension DevelopModel {
    /// What the report says about a question, once its report has been read.
    enum Cohort: Equatable {
        /// The report's sentences with a figure for this question, and where they come from.
        case figures([String], source: String)
        /// The report is here but gives no figure for this question.
        case noFigure(source: String)
    }

    /// The cache file of a report's figures (bump the version when `ExaminerReport` changes).
    static func cohortCache(_ docId: String) -> URL {
        papersFolder.appendingPathComponent("\(docId)-cohort-v1.json")
    }

    /// The catalogue report paired with a question's paper, when it's on this device.
    func report(for p: Problem) -> Catalogue.Doc? {
        guard let docId = docId(p), let catalogue, let spec = spec(ofDoc: docId), let qp = spec.docs.first(where: { $0.id == docId }),
              let er = catalogue.companions(of: qp, in: spec).er, cached.contains(er.id) else { return nil }
        return er
    }

    /// Nil until the report has been read (`readReport(for:)`), or when there's no report for the question.
    func cohort(for p: Problem) -> Cohort? {
        guard let er = report(for: p), let figures = cohortFigures[er.id], let spec = spec(ofDoc: er.id) else { return nil }
        let source = reportSource(er, in: spec)
        if let quotes = figures[p.key], !quotes.isEmpty { return .figures(quotes, source: source) }
        return .noFigure(source: source)
    }

    /// "AQA examiner report, June 2025".
    func reportSource(_ er: Catalogue.Doc, in spec: Catalogue.Spec) -> String {
        let board = catalogue?.board(spec.board)?.name ?? spec.board.uppercased()
        let when = [er.series, er.year.map(String.init)].compactMap { $0 }.joined(separator: " ")
        return "\(board) examiner report" + (when.isEmpty ? "" : ", \(when)")
    }

    /// Reads the question's report into figures once per file, off the main thread, and caches them.
    func readReport(for p: Problem) async {
        guard let er = report(for: p), cohortFigures[er.id] == nil else { return }
        let file = Self.file(er.id), cache = Self.cohortCache(er.id)
        let figures = await Task.detached(priority: .utility) { () -> [String: [String]] in
            if let data = try? Data(contentsOf: cache), let saved = try? JSONDecoder().decode([String: [String]].self, from: data) { return saved }
            guard let pdf = PDFDocument(url: file) else { return [:] }
            let figures = ExaminerReport.figures(PaperPDF.lines(pdf).lines.map(\.text))
            if let data = try? JSONEncoder().encode(figures) { try? data.write(to: cache, options: .atomic) }
            return figures
        }.value
        cohortFigures[er.id] = figures
    }
}
