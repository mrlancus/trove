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
/// - The answer is written once, as light-blue handwriting (`InkHandwriting`, sized like the line):
///   real strokes, so the eraser and lasso treat it like any ink (docs/plans/sketch-2-plan.md A2).
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
        /// The answer's strokes, and the line (by its strokes) they answered.
        var answerIds: [String] = []
        var answeredKey = ""
    }
    private var solved: [String: Solved] = [:]
    /// Letters defined on each page (`a = 5`), for the lines below.
    private var variables: [String: [String: Double]] = [:]

    /// Math Assist's blue: light on a white page, a little lighter on the dark page (both ≥ 3:1).
    static let assistBlue = "#5aa9e6"
    static let assistBlueDark = "#7cc4f5"
    static let unsureGrey = "#9aa0a6"

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
        // Math Assist's own strokes are never read as input (its "=" would answer itself).
        let strokes = (editor.content[key]?.strokes ?? []).filter { $0.by.isEmpty || $0.id == line.id }
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
        var entry = solved[eqKey] ?? Solved(pageKey: key, equals: eq, equalsIds: equalsIds, line: lineBox)
        entry.line = lineBox
        let outcome = reading?.outcome ?? .unsure
        if case .assignment(let name, let value) = outcome { variables[key, default: [:]][name] = value }
        // You rubbed out (some of) its answer to this same line: it's yours now; no new answer
        // until the line itself changes.
        let present = Set((editor.content[key]?.strokes ?? []).map(\.id))
        if entry.answeredKey == lineKey, !entry.answerIds.isEmpty, entry.answerIds.contains(where: { !present.contains($0) }) {
            solved[eqKey] = entry
            return
        }
        await place(MathAssist.answerText(outcome), for: &entry, lineKey: lineKey)
        solved[eqKey] = entry
    }

    /// The ink changed (undo, erase, another device): an answer whose `=` is gone goes too, unless
    /// you've changed it.
    func contentChanged() {
        guard let editor, !solved.isEmpty else { return }
        for (eqKey, entry) in solved {
            let present = Set((editor.content[entry.pageKey]?.strokes ?? []).map(\.id))
            guard !entry.equalsIds.isSubset(of: present) else { continue }
            solved[eqKey] = nil
            let untouched = entry.answerIds.filter { present.contains($0) }
            if !untouched.isEmpty, untouched.count == entry.answerIds.count, let library = editor.app?.library {
                Task { await library.deleteStrokes(untouched); await editor.reloadInk() }
            }
        }
    }

    /// Writes (or replaces) the answer in light-blue handwriting after the line: right of its
    /// rightmost ink (after your own answer, if you wrote one), at the size of the writing there.
    private func place(_ text: String?, for entry: inout Solved, lineKey: String) async {
        guard let editor, let library = editor.app?.library else { return }
        if !entry.answerIds.isEmpty {
            await library.deleteStrokes(entry.answerIds)
            entry.answerIds = []
        }
        guard let text else { await editor.reloadInk(); return }
        let strokes = editor.content[entry.pageKey]?.strokes ?? []
        let eq = entry.equals
        let lineHeight = max(entry.line.height, eq.width * 1.4)
        let midY = eq.y + eq.height / 2
        let band = InkGeometry.Rect(x: eq.x, y: midY - lineHeight * 0.75, width: 100_000, height: lineHeight * 1.5)
        // Your own ink right of the "=" on this line (an answer you wrote, to check).
        let after = strokes.filter { $0.by.isEmpty && !entry.equalsIds.contains($0.id) }
            .compactMap(\.bounds).filter { $0.intersects(band) && $0.x >= eq.x }
        let right = max(eq.maxX, after.map(\.maxX).max() ?? eq.maxX)
        // The size of the writing on this line.
        let boxes = strokes.filter { $0.by.isEmpty }.compactMap(\.bounds)
        var o = InkHandwriting.Options()
        o.xHeight = InkHandwriting.sizeNear(InkGeometry.Rect(x: right, y: entry.line.y, width: lineHeight * 3, height: entry.line.height), strokes: boxes)
        o.xHeight = min(max(o.xHeight, 3), 40)
        o.seed = lineKey.stableHash
        o.style = InkHandwriting.Style(rawValue: UserDefaults.standard.string(forKey: "ink.handwriting") ?? "") ?? .neat
        let start = InkPoint(x: right + max(6, o.xHeight * 0.9), y: midY + o.xHeight * 0.5)
        let written = InkHandwriting.write(text, at: start, options: o)
        let unsure = text == "?"
        let dark = editor.darkPage && editor.isSketch
        let color = unsure ? Self.unsureGrey : (dark ? Self.assistBlueDark : Self.assistBlue)
        let width = min(4, max(1, o.xHeight * 0.2))
        let group = "assist-" + String(UUID().uuidString.prefix(8)).lowercased()
        var ids: [String] = []
        for points in written.strokes where !points.isEmpty {
            if let id = await library.addStroke(on: editor.target.itemId, layer: editor.target.layer, pageKey: entry.pageKey, tool: .pen,
                                                color: color, width: width, points: points, group: group, by: "assist") {
                ids.append(id)
            }
        }
        entry.answerIds = ids
        entry.answeredKey = lineKey
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
