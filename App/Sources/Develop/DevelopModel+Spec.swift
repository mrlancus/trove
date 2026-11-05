import Foundation
import PDFKit
import TroveCore

/// The specification with each course (learn-pivot plan §C6): downloaded first when the course is added, kept
/// and synced like a downloaded paper (decision 3), and read on the device into its statements (`SpecReader`;
/// decision 12: nothing is shipped). The statements are worked out once per file and cached next to the papers.
extension DevelopModel {
    /// The cache file of a specification's statements (bump the version when `SpecReader` changes).
    static func statementsCache(_ docId: String) -> URL {
        papersFolder.appendingPathComponent("\(docId)-statements-v1.json")
    }

    /// The course's statements, if its specification has been read on this device.
    func statements(_ spec: Catalogue.Spec) -> [SpecStatement] { specStatements[spec.id] ?? [] }

    /// Downloads the course's specification if it isn't here yet (Wi-Fi only, like papers; another device's copy
    /// in your trove first), then reads it. Quiet: a failure leaves the course as it was.
    func fetchSpecification(_ spec: Catalogue.Spec) async {
        guard let doc = catalogue?.specification(of: spec) else { return }
        if !cached.contains(doc.id) {
            if let data = await app?.library?.boardPaperData(doc.id) {
                try? data.write(to: Self.file(doc.id), options: .atomic)
            } else if let url = URL(string: doc.url) {
                let config = URLSessionConfiguration.default
                config.allowsExpensiveNetworkAccess = false
                config.allowsConstrainedNetworkAccess = false
                guard let (tmp, response) = try? await URLSession(configuration: config).download(from: url),
                      (response as? HTTPURLResponse)?.statusCode == 200 else { return }
                try? FileManager.default.removeItem(at: Self.file(doc.id))
                guard (try? FileManager.default.moveItem(at: tmp, to: Self.file(doc.id))) != nil else { return }
                if syncBoardPapers, let library = app?.library, let data = try? Data(contentsOf: Self.file(doc.id)) {
                    _ = try? await library.saveBoardPaper(data, docId: doc.id, title: paperName(doc, in: spec), folder: ["Practice papers", boardName(spec.board)])
                }
            }
            refreshCache()
        }
        await readSpecification(spec)
    }

    /// Reads the downloaded specification into statements, off the main thread, once per file.
    func readSpecification(_ spec: Catalogue.Spec) async {
        guard specStatements[spec.id] == nil, let doc = catalogue?.specification(of: spec), cached.contains(doc.id) else { return }
        let file = Self.file(doc.id), cache = Self.statementsCache(doc.id), course = spec.id
        let read = await Task.detached(priority: .utility) { () -> [SpecStatement] in
            if let data = try? Data(contentsOf: cache), let saved = try? JSONDecoder().decode([SpecStatement].self, from: data) { return saved }
            guard let pdf = PDFDocument(url: file) else { return [] }
            let statements = SpecReader.statements(PaperPDF.lines(pdf).lines, course: course)
            if let data = try? JSONEncoder().encode(statements) { try? data.write(to: cache, options: .atomic) }
            return statements
        }.value
        specStatements[spec.id] = read
        for s in read { specTopicNames[s.concept] = SpecReader.subtopic(of: s, in: read).label }
        await tagWithSpec(spec)
    }

    /// Tags the course's split questions with the statement each is about (learn-pivot plan §B4), once per
    /// question: Your work then groups by the specification's topics instead of the paper.
    func tagWithSpec(_ spec: Catalogue.Spec) async {
        guard let library = app?.library else { return }
        let statements = self.statements(spec)
        guard !statements.isEmpty else { return }
        let ids = Set(statements.map(\.concept))
        var changed = false
        for p in problems where p.sourceKey.hasPrefix("cat:\(spec.id)-") && p.skills.allSatisfy({ !ids.contains($0) }) {
            let q = text(of: p)
            guard !q.isEmpty, let s = SpecReader.best(for: q, in: statements) else { continue }
            await library.addSkills([s.concept], to: p.id)
            changed = true
        }
        if changed { await reload() }
    }

    /// The statement a question is about, among the course's (for a new split).
    func specConcept(for question: String, in spec: Catalogue.Spec) -> String? {
        SpecReader.best(for: question, in: statements(spec))?.concept
    }
}
