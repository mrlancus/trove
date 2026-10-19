import Foundation

/// What to do with one imported file. Exports become items (bookmarks, highlights, links), text
/// becomes notes, and everything else is kept as a file.
public enum ImportAction: Equatable, Sendable {
    case items([ImportedItem])
    case note(title: String, body: String, tags: [String])
    case file(name: String, data: Data, mime: String)
}

/// Decides how any dropped or chosen file is imported, opening zips (and zips inside zips) along
/// the way. Pure, so every app and the website (web/public/core/importer.js) route files the same.
public enum FileImport {
    /// Caps that keep a hostile or huge zip from eating the device.
    public static let maxNesting = 3
    public static let maxUnzippedBytes = 2_000_000_000
    static let maxTextNote = 1_000_000

    public static func actions(name: String, data: Data) -> [ImportAction] {
        var budget = maxUnzippedBytes
        return actions(name: name, data: data, depth: 0, budget: &budget)
    }

    static func actions(name: String, data: Data, depth: Int, budget: inout Int) -> [ImportAction] {
        let ext = (name as NSString).pathExtension.lowercased()
        let base = (name as NSString).deletingPathExtension
        let file = ImportAction.file(name: name, data: data, mime: mime(forExtension: ext))
        switch ext {
        case "zip":
            guard depth < maxNesting, let zip = try? ZipArchive(data) else { return [file] }
            var out: [ImportAction] = []
            for entry in zip.entries where !entry.isDirectory && !isJunk(entry.path) && !entry.isEncrypted {
                guard entry.size <= budget, let contents = try? zip.data(for: entry) else { continue }
                budget -= contents.count
                out += actions(name: entry.name, data: contents, depth: depth + 1, budget: &budget)
            }
            return out
        case "txt":
            guard let text = String(data: data, encoding: .utf8) else { return [file] }
            if name.lowercased().contains("clippings") {
                let highlights = KindleClippings.parse(text)
                if !highlights.isEmpty { return [.items(highlights)] }
            }
            guard data.count <= maxTextNote, !text.trimmed.isEmpty else { return [file] }
            return [.note(title: base, body: text, tags: [])]
        case "md", "markdown":
            guard let text = String(data: data, encoding: .utf8) else { return [file] }
            let note = ObsidianMirror.parse(text, fileName: name)
            return [.note(title: note.title, body: note.body, tags: note.tags)]
        case "html", "htm":
            let marks = NetscapeBookmarks.parse(String(decoding: data, as: UTF8.self))
            return marks.isEmpty ? [file] : [.items(marks)]
        case "csv":
            let links = CSVImport.importLinks(String(decoding: data, as: UTF8.self))
            return links.isEmpty ? [file] : [.items(links)]
        case "json":
            if let highlights = try? ReadwiseExport.parse(data), !highlights.isEmpty { return [.items(highlights)] }
            return [file]
        default:
            return [file]
        }
    }

    /// Hidden files and the clutter macOS and Windows add to archives.
    public static func isJunk(_ path: String) -> Bool {
        let parts = path.split(separator: "/")
        if parts.contains(where: { $0 == "__MACOSX" || $0.hasPrefix(".") }) { return true }
        return ["Thumbs.db", "desktop.ini"].contains(parts.last.map(String.init) ?? "")
    }

    public static func mime(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "pdf": "application/pdf"
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "heic": "image/heic"
        case "gif": "image/gif"
        case "webp": "image/webp"
        case "svg": "image/svg+xml"
        case "m4a": "audio/m4a"
        case "mp3": "audio/mpeg"
        case "wav": "audio/wav"
        case "mov": "video/quicktime"
        case "mp4": "video/mp4"
        case "txt": "text/plain"
        case "md", "markdown": "text/markdown"
        case "html", "htm": "text/html"
        case "csv": "text/csv"
        case "json": "application/json"
        case "zip": "application/zip"
        case "epub": "application/epub+zip"
        case "doc": "application/msword"
        case "docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        case "xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        case "pptx": "application/vnd.openxmlformats-officedocument.presentationml.presentation"
        case "key": "application/vnd.apple.keynote"
        case "pages": "application/vnd.apple.pages"
        case "numbers": "application/vnd.apple.numbers"
        default: "application/octet-stream"
        }
    }

    /// Counts what a set of actions adds, for progress and the summary.
    public static func count(_ actions: [ImportAction]) -> Int {
        actions.reduce(0) { n, a in
            if case .items(let items) = a { return n + items.count }
            return n + 1
        }
    }
}
