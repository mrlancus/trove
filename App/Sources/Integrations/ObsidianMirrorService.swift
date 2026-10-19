#if os(macOS)
import Foundation
import TroveCore

/// Mac only. Two jobs:
///  1. `export`: a readable Markdown copy of every note in the iCloud vault's `Notes/` folder
///     (one-way; only the "mirror owner" device writes it, so iCloud never sees conflicts).
///  2. `sync`: two-way with an Obsidian vault folder the user chose. Trove writes `trove-id` in the
///     front matter; edits made in Obsidian come back as normal Trove edits (merged by TroveCore).
actor ObsidianMirrorService {
    static let shared = ObsidianMirrorService()

    /// path → (trove id, sha of what we last wrote/read), so we can tell who changed a file.
    private var known: [String: (id: String, hash: String)] = [:]
    private var exported: [String: String] = [:] // item id → updatedHLC already exported

    func export(items: [Item], to folder: URL, library: Library) async {
        let notes = items.filter { $0.kind == .note || $0.kind == .highlight || !$0.body.isEmpty }
        var taken = Set<String>()
        for item in notes {
            let relative = ObsidianMirror.relativePath(for: item, folder: "", taken: taken).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            taken.insert(relative)
            guard exported[item.id] != item.record.updatedHLC else { continue }
            let url = folder.appendingPathComponent(relative)
            write(ObsidianMirror.render(item), to: url)
            exported[item.id] = item.record.updatedHLC
        }
    }

    func sync(items: [Item], folder: URL, library: Library) async {
        let fm = FileManager.default
        let byId = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        // 1. Read the folder: pick up edits and new notes made in Obsidian.
        let enumerator = fm.enumerator(at: folder, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])
        var seenIds = Set<String>()
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "md", let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let path = url.path
            let hash = text.sha256Hex
            let parsed = ObsidianMirror.parse(text, fileName: url.lastPathComponent)
            if let id = parsed.troveId, let item = byId[id] {
                seenIds.insert(id)
                if known[path]?.hash != hash, parsed.body != item.body {
                    await library.setBody(id, parsed.body)
                    if !parsed.title.isEmpty, parsed.title != item.title { await library.update(id, [Field.title: .string(parsed.title)]) }
                }
                known[path] = (id, hash)
            } else if parsed.troveId == nil, known[path] == nil {
                // A note created in Obsidian: import it and stamp the id back into the file.
                let id = await library.addNote(title: parsed.title, body: parsed.body, tags: parsed.tags, source: .obsidian)
                if let item = await library.item(id) {
                    let rendered = ObsidianMirror.render(item)
                    write(rendered, to: url)
                    known[path] = (id, rendered.sha256Hex)
                    seenIds.insert(id)
                }
            }
        }

        // 2. Write Trove notes the folder doesn't have yet, or that changed in Trove.
        var taken = Set(known.keys.map { URL(fileURLWithPath: $0).path.replacingOccurrences(of: folder.path + "/", with: "") })
        for item in items where item.kind == .note && !item.body.isEmpty {
            let existingPath = known.first { $0.value.id == item.id }?.key
            let rendered = ObsidianMirror.render(item)
            if let existingPath {
                if known[existingPath]?.hash != rendered.sha256Hex, let current = try? String(contentsOfFile: existingPath, encoding: .utf8),
                   current.sha256Hex == known[existingPath]?.hash {
                    // Unchanged in Obsidian since we last looked, so Trove's version wins.
                    write(rendered, to: URL(fileURLWithPath: existingPath))
                    known[existingPath] = (item.id, rendered.sha256Hex)
                }
            } else if !seenIds.contains(item.id) {
                let relative = ObsidianMirror.relativePath(for: item, folder: "Trove", taken: taken)
                taken.insert(relative)
                let url = folder.appendingPathComponent(relative)
                write(rendered, to: url)
                known[url.path] = (item.id, rendered.sha256Hex)
            }
        }
    }

    private func write(_ text: String, to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}
#endif
