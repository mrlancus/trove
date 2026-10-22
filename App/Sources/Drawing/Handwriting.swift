import CoreGraphics
import Foundation
import PDFKit
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
    static func read(_ itemId: String, library: Library, fast: Bool = false, ai: AIClient? = nil) async -> Int {
        guard let item = await library.item(itemId), item.kind == .sketch else { return 0 }
        // Read by your AI or by Vision: switching to AI reads everything again, once.
        let reader = ai == nil ? "" : "|ai"
        let sig = await library.inkSignature(itemId) + reader
        guard item.record[signatureField]?.string != sig else { return 0 }
        let signpost = Perf.begin("Read handwriting")
        defer { Perf.end("Read handwriting", signpost) }
        let known = await HandwritingPages.shared.pages(of: itemId)
        var kept: [String: HandwritingPages.Page] = [:]
        var parts: [String] = []
        var read = 0
        var aiFailed = false
        for spec in InkRenderer.sketchPages(item) {
            let strokes = await library.strokes(on: itemId, pageKey: spec.key)
            guard !strokes.isEmpty else { continue }
            let latest = strokes.map(\.record.updatedHLC).max() ?? ""
            let pageSig = "\(strokes.count)-\(latest)-\(spec.width)x\(spec.height)\(reader)"
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
            let w = area?.width ?? spec.width, h = area?.height ?? spec.height
            // Your AI sees at most ~1568 px on the long side; Vision likes it bigger.
            let width = ai != nil ? Self.aiWidth(w, h) : Int(min(2400, max(800, w * 2)))
            let box = area
            guard let image = await Task.detached(priority: .utility, operation: {
                InkRenderer.render(plain, content: content, pixelWidth: width, area: box).map(InkImage.init)
            }).value else { continue }
            var text = ""
            var stamp = pageSig
            if let ai, let jpeg = InkRenderer.jpeg(image.image, quality: 0.85), let read = try? await ai.readPage(jpeg, mime: "image/jpeg") {
                text = read
            } else {
                text = await AppleEnricher.recognizeText(in: image.image, fast: fast).trimmingCharacters(in: .whitespacesAndNewlines)
                // Your AI didn't answer (offline, out of credit): Vision's reading for now, AI next time.
                if ai != nil { aiFailed = true; stamp = String(pageSig.dropLast(reader.count)) }
            }
            read += 1
            kept[spec.key] = HandwritingPages.Page(sig: stamp, text: text)
            if !text.isEmpty { parts.append(text) }
        }
        await HandwritingPages.shared.set(kept, for: itemId)
        await library.setInkText(itemId, parts.joined(separator: "\n"))
        if !aiFailed { await library.update(itemId, [signatureField: .string(sig)]) }
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

extension Handwriting {
    /// Pixels wide for a page sent to your AI: ~1568 on the long side (what vision models read at).
    static func aiWidth(_ width: Double, _ height: Double) -> Int {
        let long = max(1, width, height)
        return max(200, Int((width * 1568 / long).rounded()))
    }

    // MARK: Files: GoodNotes, PDFs, photos of pages (your AI only)

    /// What the files were read from (attachments and their ink), so they're read again only when it changes.
    static let filesField = "aiReadSig"
    static let maxPagesPerItem = 60

    static func readable(_ a: Attachment) -> Bool {
        a.name.lowercased().hasSuffix(".goodnotes") || a.mime == "application/pdf" || a.mime.hasPrefix("image/")
    }

    /// Items whose files your AI should read: not sketches (above) and not screenshots (typed text,
    /// which Vision reads well).
    static func wantsFileRead(_ item: Item) -> Bool {
        item.kind != .sketch && !item.id.hasPrefix("screenshot-") && item.attachments.contains(where: readable)
    }

    static func fileSignature(_ item: Item, ink: String) -> String {
        item.attachments.filter(readable).map(\.id).joined(separator: ",") + "|" + ink
    }

    /// Reads a file item's handwriting with your AI, as soon as it arrives from anywhere: every page of
    /// a GoodNotes notebook, scanned PDFs (typed ones only where there's ink on them), pictures, and
    /// ink written on any of them. Returns how many pages were read.
    @discardableResult
    static func readFiles(_ itemId: String, library: Library, ai: AIClient) async -> Int {
        guard let item = await library.item(itemId), wantsFileRead(item) else { return 0 }
        let sig = fileSignature(item, ink: await library.inkSignature(itemId))
        guard item.record[filesField]?.string != sig else { return 0 }
        var parts: [String] = []
        var read = 0, failed = 0
        for att in item.attachments.prefix(3) where readable(att) {
            guard let data = try? await library.attachmentData(att) else { continue }
            if att.name.lowercased().hasSuffix(".goodnotes") {
                // The notebook as GoodNotes drew it, every layer (its ink may not be in Trove yet).
                guard let notebook = await Task.detached(priority: .utility, operation: { try? GoodNotesInk.read(data) }).value else { continue }
                for page in notebook.pages.prefix(maxPagesPerItem - read) {
                    let width = CGFloat(aiWidth(Double(page.width), Double(page.height)))
                    guard let image = await Task.detached(priority: .utility, operation: {
                        NotebookRenderer.render(page, of: notebook, width: width, scale: 1).map { InkImage(image: $0.cgImage) }
                    }).value else { continue }
                    if let text = await readImage(image.image, ai: ai) { if !text.isEmpty { parts.append(text) } } else { failed += 1 }
                    read += 1
                }
                continue
            }
            let name = att.name, mime = att.mime
            let specs = await Task.detached(priority: .utility, operation: { InkRenderer.pages(for: data, mime: mime, name: name) }).value
            let typed = mime == "application/pdf" && !(PDFDocument(data: data)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            for spec in specs {
                guard read < maxPagesPerItem else { break }
                let strokes = await library.strokes(on: itemId, layer: att.id, pageKey: spec.key)
                // A typed PDF's text is searchable already: only pages written on are read.
                if typed && strokes.isEmpty { continue }
                let content = InkContent(strokes: strokes.map(InkLine.init))
                let width = aiWidth(spec.width, spec.height)
                guard let image = await Task.detached(priority: .utility, operation: {
                    InkRenderer.render(spec, content: content, pixelWidth: width).map(InkImage.init)
                }).value else { continue }
                if let text = await readImage(image.image, ai: ai) { if !text.isEmpty { parts.append(text) } } else { failed += 1 }
                read += 1
            }
        }
        // Nothing read (offline, out of credit): try again next time rather than keep an empty result.
        if failed > 0 && parts.isEmpty { return read }
        await library.setInkText(itemId, parts.joined(separator: "\n\n"))
        await library.update(itemId, [filesField: .string(sig)])
        return read
    }

    private static func readImage(_ image: CGImage, ai: AIClient) async -> String? {
        guard let jpeg = InkRenderer.jpeg(image, quality: 0.85) else { return nil }
        return try? await ai.readPage(jpeg, mime: "image/jpeg")
    }
}
