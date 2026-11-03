import Foundation

/// Export as plain files (docs/MASTER_PLAN.md I5, S7): notes and links as Markdown with a small
/// front matter, files as themselves, in a zip that keeps the folder tree. Nothing Trove-specific
/// is needed to read it (Obsidian, Bear and Apple Notes import Markdown).
extension Library {
    public func exportPlain(_ ids: [String]) async -> (data: Data, count: Int) {
        let folders = await self.folders()
        let byId = Dictionary(folders.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        func path(of folderId: String?) -> String {
            var parts: [String] = []
            var current = folderId
            var guardCount = 0
            while let id = current, let f = byId[id], guardCount < 32 {
                parts.insert(Self.safeName(f.name), at: 0)
                current = f.parent
                guardCount += 1
            }
            return parts.isEmpty ? "" : parts.joined(separator: "/") + "/"
        }
        var used: Set<String> = []
        func unique(_ name: String) -> String {
            var n = name, i = 2
            let ext = (name as NSString).pathExtension, base = (name as NSString).deletingPathExtension
            while used.contains(n.lowercased()) { n = ext.isEmpty ? "\(base) \(i)" : "\(base) \(i).\(ext)"; i += 1 }
            used.insert(n.lowercased())
            return n
        }
        var entries: [(String, [UInt8])] = []
        let iso = ISO8601DateFormatter()
        for id in ids {
            guard let item = await item(id) else { continue }
            let dir = path(of: item.folder)
            var front = ["---", "title: \"\(item.displayTitle.replacingOccurrences(of: "\"", with: "'"))\"", "created: \(iso.string(from: item.createdAt))"]
            if !item.tags.isEmpty { front.append("tags: [\(item.tags.joined(separator: ", "))]") }
            if let url = item.url { front.append("url: \(url.absoluteString)") }
            front.append("---")
            if item.kind == .note || item.kind == .link || item.kind == .highlight || !item.body.isEmpty {
                let text = front.joined(separator: "\n") + "\n\n" + (item.body.isEmpty ? (item.summary ?? "") : item.body) + "\n"
                entries.append((dir + unique(Self.safeName(item.displayTitle) + ".md"), Array(text.utf8)))
            }
            for att in item.attachments {
                guard let data = try? await attachmentData(att) else { continue }
                entries.append((dir + unique(Self.safeName(att.name)), [UInt8](data)))
            }
        }
        return (Data(ZipWriter.stored(entries)), entries.count)
    }

    static func safeName(_ s: String) -> String {
        let cleaned = s.map { "/\\:*?\"<>|".contains($0) ? "-" : $0 }
        let out = String(cleaned).trimmingCharacters(in: .whitespacesAndNewlines)
        return out.isEmpty ? "Untitled" : String(out.prefix(120))
    }
}
