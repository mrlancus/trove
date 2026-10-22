import CoreGraphics
import Foundation
import TroveCore

/// Handwriting search (PROTOCOL.md §10 `inkText`): an Apple device draws a sketch's ink on white
/// and reads it with Vision. It runs when the editor closes, and from enrichment for sketches drawn
/// on the website or another device, only when the ink changed since it was last read. Each page's
/// text is kept on this device with a signature of its strokes, so a stroke on page 3 re-reads page
/// 3, not the whole notebook (docs/ROADMAP.md §3.7 item 6).
enum Handwriting {
    static let signatureField = "inkTextSig"

    /// Reads what changed; returns how many pages went through Vision. `fast` in Low Power Mode or when hot.
    @discardableResult
    static func read(_ itemId: String, library: Library, fast: Bool = false) async -> Int {
        guard let item = await library.item(itemId), item.kind == .sketch else { return 0 }
        let sig = await library.inkSignature(itemId)
        guard item.record[signatureField]?.string != sig else { return 0 }
        let signpost = Perf.begin("Read handwriting")
        defer { Perf.end("Read handwriting", signpost) }
        let known = await HandwritingPages.shared.pages(of: itemId)
        var kept: [String: HandwritingPages.Page] = [:]
        var parts: [String] = []
        var read = 0
        for spec in InkRenderer.sketchPages(item) {
            let strokes = await library.strokes(on: itemId, pageKey: spec.key)
            guard !strokes.isEmpty else { continue }
            let latest = strokes.map(\.record.updatedHLC).max() ?? ""
            let pageSig = "\(strokes.count)-\(latest)-\(spec.width)x\(spec.height)"
            if let page = known[spec.key], page.sig == pageSig {
                kept[spec.key] = page
                if !page.text.isEmpty { parts.append(page.text) }
                continue
            }
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
            let text = await AppleEnricher.recognizeText(in: image.image, fast: fast).trimmingCharacters(in: .whitespacesAndNewlines)
            read += 1
            kept[spec.key] = HandwritingPages.Page(sig: pageSig, text: text)
            if !text.isEmpty { parts.append(text) }
        }
        await HandwritingPages.shared.set(kept, for: itemId)
        await library.setInkText(itemId, parts.joined(separator: "\n"))
        await library.update(itemId, [signatureField: .string(sig)])
        return read
    }
}

/// Each sketch page's recognised text and the signature of the strokes it was read from. Local to
/// this device (Caches; rebuilt if the system clears it), never synced.
actor HandwritingPages {
    static let shared = HandwritingPages()

    struct Page: Codable, Equatable {
        var sig: String
        var text: String
    }

    private var sketches: [String: [String: Page]]?
    private var saveTask: Task<Void, Never>?

    private var url: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("trove-handwriting-pages.json")
    }

    func pages(of itemId: String) -> [String: Page] {
        load()
        return sketches?[itemId] ?? [:]
    }

    func set(_ pages: [String: Page], for itemId: String) {
        load()
        guard sketches?[itemId] != pages else { return }
        sketches?[itemId] = pages
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            await self.save()
        }
    }

    private func load() {
        guard sketches == nil else { return }
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode([String: [String: Page]].self, from: data) {
            sketches = saved
        } else {
            sketches = [:]
        }
    }

    private func save() {
        guard let sketches, let data = try? JSONEncoder().encode(sketches) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
