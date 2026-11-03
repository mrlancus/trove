import CoreGraphics
import Foundation
import TroveCore
import Vision

/// Math Assist in the sketch editor (docs/MASTER_PLAN.md G7). Write `=` after a sum and the answer
/// appears after it; write `2x+3=7` and it solves for x; a wrong `2+2=5` gets a ✗ with the right value.
///
/// Built for battery first (the user found GoodNotes' Math Assist drains it):
/// - Nothing is recognised while writing. Each finished stroke gets a shape test against the one
///   before it (`EqualsDetector`, microseconds); only a real `=` goes further.
/// - It waits 0.4 s for the pen to stay up; another stroke cancels.
/// - Only that one line is read: its strokes drawn ~48 px tall and given to Vision once.
/// - Lines are cached by their strokes, so an untouched line is never read again.
/// - The answer is a plain text box, drawn once; nothing animates.
/// - In Low Power Mode or when hot it only runs when asked (`MathAssist.effectiveMode`).
@MainActor
final class MathAssistController {
    private weak var editor: InkEditorModel?
    private var cache = MathCache()
    private var pending: Task<Void, Never>?
    /// Solved lines: where the `=` is, the line's box, and the answer box drawn for it.
    private struct Solved {
        var pageKey: String
        var equals: InkGeometry.Rect
        var equalsIds: Set<String>
        var line: InkGeometry.Rect
        var answerId: String?
    }
    private var solved: [String: Solved] = [:]
    /// Letters defined on each page (`a = 5`), for the lines below.
    private var variables: [String: [String: Double]] = [:]

    static var setting: MathAssist.Mode {
        get { MathAssist.Mode(rawValue: UserDefaults.standard.string(forKey: "ink.math") ?? "") ?? .automatic }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "ink.math") }
    }

    init(editor: InkEditorModel) { self.editor = editor }

    /// A stroke was just added on `key`.
    func strokeAdded(_ line: InkLine, pageKey key: String) {
        pending?.cancel()
        guard let editor, let app = editor.app else { return }
        guard MathAssist.effectiveMode(Self.setting, policy: app.policy) == .automatic else { return }
        let strokes = editor.content[key]?.strokes ?? []
        guard strokes.count >= 2 else { return }
        let newest = Self.mathStroke(line)
        // Writing into a line that's already solved: read it again once the pen rests.
        if let (eqKey, entry) = solved.first(where: { $0.value.pageKey == key && Self.grow($0.value.line, by: 8).intersects(newest.bounds) && !$0.value.equalsIds.contains(line.id) }) {
            schedule { await self.solve(eqKey: eqKey, equals: entry.equals, equalsIds: entry.equalsIds, pageKey: key) }
            return
        }
        let before = Self.mathStroke(strokes[strokes.count - 2])
        guard let eq = EqualsDetector.equals(before, newest) else { return }
        let ids: Set<String> = [before.id, newest.id]
        let eqKey = ids.sorted().joined(separator: "+")
        schedule { await self.solve(eqKey: eqKey, equals: eq, equalsIds: ids, pageKey: key) }
    }

    /// Lasso → Solve: every `=` in the selection, whatever the setting (unless it's off).
    func solve(selection: InkSelection) {
        guard let editor, Self.setting != .off else { return }
        let strokes = (editor.content[selection.pageKey]?.strokes ?? []).filter { selection.strokes.contains($0.id) }.map(Self.mathStroke)
        for i in strokes.indices {
            for j in strokes.indices where j > i {
                guard let eq = EqualsDetector.equals(strokes[i], strokes[j]) else { continue }
                let ids: Set<String> = [strokes[i].id, strokes[j].id]
                Task { await solve(eqKey: ids.sorted().joined(separator: "+"), equals: eq, equalsIds: ids, pageKey: selection.pageKey) }
            }
        }
    }

    private func schedule(_ work: @escaping @MainActor () async -> Void) {
        pending = Task { @MainActor in
            try? await Task.sleep(for: .seconds(MathAssist.settleDelay), tolerance: .milliseconds(100))
            guard !Task.isCancelled else { return }
            await work()
        }
    }

    private func solve(eqKey: String, equals eq: InkGeometry.Rect, equalsIds: Set<String>, pageKey key: String) async {
        guard let editor, let content = editor.content[key] else { return }
        let all = content.strokes.map(Self.mathStroke)
        let line = MathLine.gather(equals: eq, excluding: equalsIds, from: all)
        guard !line.isEmpty, let lineBox = MathLine.bounds(line) else { return }
        let lineKey = MathLine.key(line)
        let env = variables[key] ?? [:]
        let reading: MathCandidates.Reading?
        if let cached = cache.reading(for: lineKey) {
            reading = cached
        } else {
            let ids = Set(line.map(\.id))
            var lineContent = InkContent()
            lineContent.strokes = content.strokes.filter { ids.contains($0.id) }
            let pad = max(4, lineBox.height * 0.15)
            let box = InkGeometry.Rect(x: lineBox.x - pad, y: lineBox.y - pad, width: lineBox.width + pad * 2, height: lineBox.height + pad * 2)
            let scale = MathLine.renderScale(for: box)
            let guesses = await Task.detached(priority: .userInitiated) { () -> [MathCandidates.Guess] in
                guard let image = InkRenderer.renderSelection(lineContent, box: box, scale: scale, whiteBackground: true) else { return [] }
                return Self.recognise(image)
            }.value
            // The `=` itself was left out of the picture; the parser wants it at the end.
            let found = MathCandidates.best(guesses.map { .init($0.text + "=", $0.confidence) }, env: env)
            reading = (found?.score ?? 0) >= MathCandidates.minimumScore ? found : nil
            cache.store(reading, for: lineKey)
        }
        var entry = solved[eqKey] ?? Solved(pageKey: key, equals: eq, equalsIds: equalsIds, line: lineBox, answerId: nil)
        entry.line = lineBox
        let outcome = reading?.outcome ?? .unsure
        if case .assignment(let name, let value) = outcome { variables[key, default: [:]][name] = value }
        await place(MathAssist.answerText(outcome), for: &entry, color: editor.color(for: .pen))
        solved[eqKey] = entry
    }

    /// Writes (or replaces) the answer box just right of the `=`.
    private func place(_ text: String?, for entry: inout Solved, color: String) async {
        guard let editor, let library = editor.app?.library else { return }
        if let old = entry.answerId {
            await library.deleteElements([old])
            entry.answerId = nil
        }
        guard let text else { await editor.reloadInk(); return }
        let lineHeight = max(entry.line.height, entry.equals.width * 1.4)
        let size = max(10, min(lineHeight * 0.75, 72))
        let frame = InkGeometry.Rect(x: entry.equals.maxX + entry.equals.width * 0.35, y: entry.equals.y + entry.equals.height / 2 - size * 0.62,
                                     width: max(size * Double(text.count) * 0.7, size * 2), height: size * 1.25)
        var style = InkTextStyle()
        style.font = .rounded
        let unsure = text == "?"
        entry.answerId = await library.addElement(on: editor.target.itemId, layer: editor.target.layer, pageKey: entry.pageKey, kind: .text,
                                                  frame: frame, text: text, size: size, color: unsure ? "#9AA0A6" : color, textStyle: style)
        await editor.reloadInk()
        editor.app?.inkChanged()
    }

    // MARK: Vision

    /// One accurate pass over the line's picture, no language correction (it "fixes" maths into
    /// words), up to 10 guesses per piece, combined left to right.
    nonisolated static func recognise(_ image: CGImage) -> [MathCandidates.Guess] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.customWords = ["sqrt", "sin", "cos", "tan", "log", "ln", "pi"]
        do { try VNImageRequestHandler(cgImage: image, options: [:]).perform([request]) } catch { return [] }
        let pieces = (request.results ?? []).sorted { $0.boundingBox.minX < $1.boundingBox.minX }
        guard !pieces.isEmpty else { return [] }
        let options = pieces.map { $0.topCandidates(10).map { MathCandidates.Guess($0.string, Double($0.confidence)) } }
        if options.count == 1 { return options[0] }
        // Several pieces: every piece's best, then each piece's alternatives with the others' best.
        let best = options.map { $0.first ?? .init("", 0) }
        var out = [MathCandidates.Guess(best.map(\.text).joined(), best.map(\.confidence).reduce(1, *))]
        for (i, alternatives) in options.enumerated() {
            for alt in alternatives.dropFirst().prefix(5) {
                var parts = best
                parts[i] = alt
                out.append(.init(parts.map(\.text).joined(), parts.map(\.confidence).reduce(1, *)))
            }
        }
        return out
    }

    // MARK: Helpers

    static func mathStroke(_ l: InkLine) -> MathStroke {
        MathStroke(id: l.id, version: "\(l.points.count)", points: l.points)
    }

    static func grow(_ r: InkGeometry.Rect, by d: Double) -> InkGeometry.Rect {
        InkGeometry.Rect(x: r.x - d, y: r.y - d, width: r.width + d * 2, height: r.height + d * 2)
    }
}

extension InkGeometry.Rect {
    func intersects(_ o: InkGeometry.Rect) -> Bool { x <= o.maxX && o.x <= maxX && y <= o.maxY && o.y <= maxY }
}
