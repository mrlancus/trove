import CoreGraphics
import Foundation
import PDFKit
import TroveCore

/// Practising a question in a real sketch (docs/prompts/practice-space-home.md): a page or an
/// endless whiteboard with the question on it as a picture, kept in Sketches → Practice → course →
/// topic, linked from the attempt so you can come back to it.
extension DevelopModel {
    /// Page or whiteboard: your choice, remembered.
    static var workKind: PracticeWork.Kind {
        get { PracticeWork.Kind(rawValue: UserDefaults.standard.string(forKey: "develop.workKind") ?? "") ?? .page }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "develop.workKind") }
    }

    /// The course a problem or attempt is from ("My papers" for your uploads).
    func courseName(_ sourceKey: String) -> String {
        if sourceKey.hasPrefix("cat:"), let spec = spec(ofDoc: String(sourceKey.dropFirst(4))) {
            return courses.first { $0.spec == spec.id }?.name ?? "\(boardName(spec.board)) \(spec.subject)"
        }
        return "My papers"
    }

    func topic(skills: [String], label: String) -> String {
        PracticeWork.topic(skills: skills, label: label) { id in self.concepts.first { $0.id == id }?.name }
    }

    /// Every attempt with a score or working, by course and topic (Develop → Your work).
    var yourWork: [PracticeWork.Course] {
        PracticeWork.group(attempts, course: { self.courseName($0.sourceKey) }, topic: { self.topic(skills: $0.skills, label: $0.label) })
    }

    /// The question and mark scheme for the tutor.
    func practiceContext(_ p: Problem) -> PracticeContext {
        PracticeContext(label: p.label, question: text(of: p), scheme: scheme(of: p), marks: p.marks)
    }

    /// The problem a sketch is the working for: this session's, or a past attempt's.
    func problem(forWork itemId: String) -> Problem? {
        if let pid = workInProgress.first(where: { $0.value == itemId })?.key, let p = problems.first(where: { $0.id == pid }) { return p }
        guard let a = attempts.first(where: { $0.work == itemId }) else { return nil }
        return problems.first { $0.id == a.problem }
    }

    /// Opens the working sketch for a question, making it the first time: the question's picture
    /// across the top (unlocked: move it, or lock it from the lasso), the rest of the page to write on.
    func openWork(_ p: Problem, kind: PracticeWork.Kind? = nil) async {
        guard let app, let library = app.library else { return }
        if let id = workInProgress[p.id], let item = await library.item(id) {
            app.inkTarget = InkTarget(itemId: id, layer: "", title: item.displayTitle)
            return
        }
        let kind = kind ?? Self.workKind
        Self.workKind = kind
        var choice = NewSketchChoice.load(UserDefaults.standard.data(forKey: "sketch.new"))
        choice.kind = kind == .page ? .notebook : .whiteboard
        if kind == .page { choice.paper = .blank }
        let title = PracticeWork.title(label: p.label)
        let id = await library.addSketch(choice, title: title)
        let path = ["Sketches"] + PracticeWork.folder(course: courseName(p.sourceKey), topic: topic(skills: p.skills, label: p.label))
        if let folder = await library.ensureFolder(path, auto: false) { await library.move(id, to: folder) }
        // The question as a picture, like a section of a PDF in GoodNotes.
        if let item = await library.item(id), let page = item.sketchPageList.first,
           let data = await pdfData(p), let region = p.pages.first {
            let image = await Task.detached(priority: .userInitiated) { () -> (Data, Int, Int)? in
                guard let pdf = PDFDocument(data: data), let cg = PaperPDF.image(pdf, region), let png = InkRenderer.png(cg) else { return nil }
                return (png, cg.width, cg.height)
            }.value
            if let (png, w, h) = image {
                let width = kind == .page ? choice.dimensions.first : nil
                let frame = PracticeWork.questionFrame(imageWidth: Double(w), imageHeight: Double(h), pageWidth: width)
                _ = try? await library.addPicture(png, mime: "image/png", on: id, pageKey: page.id, frame: frame)
            }
        }
        workInProgress[p.id] = id
        await app.reload()
        app.inkTarget = InkTarget(itemId: id, layer: "", title: title)
    }

    /// Opens a past attempt's working.
    func openWork(of a: Attempt) async {
        guard let app, !a.work.isEmpty, let item = await app.library?.item(a.work) else {
            app?.toast = "That working was deleted"
            return
        }
        app.inkTarget = InkTarget(itemId: a.work, layer: "", title: item.displayTitle)
    }

    /// What's handwritten in a working sketch (read on the device, cached), for hints and marking.
    func workText(_ itemId: String) async -> String {
        guard let library = app?.library else { return "" }
        _ = await Handwriting.read(itemId, library: library, forChat: true)
        let pages = await HandwritingPages.shared.pages(of: itemId)
        guard let item = await library.item(itemId) else { return "" }
        return item.sketchPageList.compactMap { pages[$0.id]?.text }.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// The working's ink as a JPEG (the question picture left out), for AI marking on a tap.
    func workImage(_ itemId: String) async -> Data? {
        guard let library = app?.library, let item = await library.item(itemId) else { return nil }
        for spec in InkRenderer.sketchPages(item) {
            let strokes = await library.strokes(on: itemId, pageKey: spec.key)
            guard !strokes.isEmpty else { continue }
            var area: InkGeometry.Rect?
            if let b = await library.inkBounds(on: itemId, pageKey: spec.key) {
                area = InkGeometry.Rect(x: b.x - 16, y: b.y - 16, width: b.width + 32, height: b.height + 32)
            }
            let content = InkContent(strokes: strokes.map(InkLine.init))
            let box = area
            return await Task.detached(priority: .userInitiated) {
                InkRenderer.render(spec, content: content, pixelWidth: 1400, area: box).flatMap { InkRenderer.jpeg($0) }
            }.value
        }
        return nil
    }

    /// The working sketch made for this question in this session, if any.
    func work(for p: Problem) -> String? { workInProgress[p.id] }
}
