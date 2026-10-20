import CoreGraphics
import Foundation
import TroveCore

/// Handwriting search (PROTOCOL.md §10 `inkText`): an Apple device draws a sketch's ink on white
/// and reads it with Vision. It runs when the editor closes, and from enrichment for sketches drawn
/// on the website or another device, only when the ink changed since it was last read.
enum Handwriting {
    static let signatureField = "inkTextSig"

    static func read(_ itemId: String, library: Library) async {
        guard let item = await library.item(itemId), item.kind == .sketch else { return }
        let sig = await library.inkSignature(itemId)
        guard item.record[signatureField]?.string != sig else { return }
        var parts: [String] = []
        for spec in InkRenderer.sketchPages(item) {
            let strokes = await library.strokes(on: itemId, pageKey: spec.key)
            guard !strokes.isEmpty else { continue }
            // Plain white, no ruled lines: Vision reads handwriting best that way. Text boxes are
            // searchable already (`sketchText`).
            var plain = spec
            plain.background = .paper(.blank, color: nil)
            var area: InkGeometry.Rect?
            if spec.infinite, let b = await library.inkBounds(on: itemId, pageKey: spec.key) {
                area = InkGeometry.Rect(x: b.x - 16, y: b.y - 16, width: b.width + 32, height: b.height + 32)
            }
            let content = InkContent(strokes: strokes.map(InkLine.init))
            let width = Int(min(2400, max(800, (area?.width ?? spec.width) * 2)))
            let box = area
            guard let image = await Task.detached(priority: .utility, operation: {
                InkRenderer.render(plain, content: content, pixelWidth: width, area: box).map(InkImage.init)
            }).value else { continue }
            let text = await AppleEnricher.recognizeText(in: image.image).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { parts.append(text) }
        }
        await library.setInkText(itemId, parts.joined(separator: "\n"))
        await library.update(itemId, [signatureField: .string(sig)])
    }
}
