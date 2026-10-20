import Foundation

/// Where a new item is filed. Pure and deterministic, so every app and the website
/// (web/public/core/organize.js) file the same thing into the same folder. Both are checked
/// against `Fixtures/organize-cases.json`.
public enum Organizer {
    /// Folder names, so the apps and the website agree on spelling.
    public enum Name {
        public static let notes = "Notes", highlights = "Highlights", email = "Email", receipts = "Receipts"
        public static let recipes = "Recipes", shopping = "Shopping", places = "Places", videos = "Videos"
        public static let events = "Events", reading = "Reading", links = "Links", code = "Code"
        public static let bookmarks = "Bookmarks", documents = "Documents", spreadsheets = "Spreadsheets"
        public static let presentations = "Presentations", handwritten = "Handwritten", images = "Images"
        public static let screenshots = "Screenshots", scans = "Scans", audio = "Audio", voiceNotes = "Voice notes"
        public static let files = "Files", appleNotes = "Apple Notes", sketches = "Sketches"
    }

    static let maxDepth = 5

    static let documentExts: Set<String> = ["pdf", "doc", "docx", "pages", "odt", "rtf", "txt", "md", "markdown", "epub", "tex", "html", "htm"]
    static let spreadsheetExts: Set<String> = ["xls", "xlsx", "numbers", "ods", "csv", "tsv"]
    static let presentationExts: Set<String> = ["ppt", "pptx", "key", "odp"]
    static let codeExts: Set<String> = ["swift", "js", "mjs", "ts", "tsx", "jsx", "py", "rb", "go", "rs", "c", "h", "cpp", "hpp", "m", "java",
                                       "kt", "cs", "php", "sh", "zsh", "sql", "json", "yaml", "yml", "toml", "xml", "css", "scss", "ipynb"]
    static let handwrittenExts: Set<String> = ["goodnotes", "note", "notability", "nbn"]

    /// The folder path for a new item. `importPath` (folders the file sat in, from a dropped folder
    /// or a zip) wins; otherwise the item is filed by what it is.
    public static func path(kind: ItemKind, category: ItemCategory? = nil, source: ItemSource, fileName: String? = nil,
                            collection: String? = nil, importPath: [String] = []) -> [String] {
        let cleaned = clean(importPath)
        if !cleaned.isEmpty { return cleaned }
        let ext = fileName.map { ($0 as NSString).pathExtension.lowercased() } ?? ""
        let group = collection.map(cleanName).flatMap { $0.isEmpty ? nil : $0 }
        if source == .goodnotes || handwrittenExts.contains(ext) { return [Name.handwritten] }
        if category == .receipt { return [Name.receipts] }
        switch kind {
        case .note:
            if source == .appleNotes { return [Name.notes, Name.appleNotes] }
            return [Name.notes]
        case .highlight:
            return [Name.highlights] + (group.map { [$0] } ?? [])
        case .email:
            return [Name.email]
        case .sketch:
            return [Name.sketches]
        case .link:
            if source == .import { return [Name.bookmarks] + (group.map { [$0] } ?? []) }
            switch category {
            case .recipe: return [Name.recipes]
            case .product: return [Name.shopping]
            case .place: return [Name.places]
            case .video: return [Name.videos]
            case .event: return [Name.events]
            case .article: return [Name.reading]
            case .code: return [Name.code]
            default: return [Name.links]
            }
        case .image:
            if source == .screenshot { return [Name.images, Name.screenshots] }
            if source == .scan { return [Name.documents, Name.scans] }
            return [Name.images]
        case .audio:
            return source == .voice ? [Name.audio, Name.voiceNotes] : [Name.audio]
        case .video:
            return [Name.videos]
        case .pdf:
            return [Name.documents]
        case .file:
            if spreadsheetExts.contains(ext) { return [Name.documents, Name.spreadsheets] }
            if presentationExts.contains(ext) { return [Name.documents, Name.presentations] }
            if documentExts.contains(ext) { return [Name.documents] }
            if codeExts.contains(ext) { return [Name.code] }
            return [Name.files]
        }
    }

    /// Tidies folder names from imports: drops empty parts and export noise (Notion's 32-hex ids),
    /// collapses a folder repeated right inside itself ("Photos/Photos"), and caps the depth.
    public static func clean(_ path: [String]) -> [String] {
        var out: [String] = []
        for part in path.map(cleanName) where !part.isEmpty {
            if let last = out.last, last.caseInsensitiveCompare(part) == .orderedSame { continue }
            out.append(part)
        }
        return Array(out.prefix(maxDepth))
    }

    static func cleanName(_ name: String) -> String {
        var s = name.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        if s.range(of: #"^Export-[0-9a-fA-F-]{36}$"#, options: .regularExpression) != nil { return "Notion" }
        s = s.replacingOccurrences(of: #"\s+[0-9a-f]{32}$"#, with: "", options: .regularExpression)
        if s.hasPrefix(".") || s == "__MACOSX" { return "" }
        return String(s.prefix(80)).trimmingCharacters(in: .whitespaces)
    }

    /// The id a folder gets when it's made from its path, so two devices filing into "Documents"
    /// at once make the same folder record rather than two.
    public static func folderId(parent: String?, name: String) -> String {
        let part = cleanName(name).lowercased()
        guard let parent else { return "folder:" + part }
        return parent + "/" + part
    }
}

/// A folder record (`kind: "folder"`, PROTOCOL.md §9). Every item sits in at most one folder.
public struct Folder: Identifiable, Hashable, Sendable {
    public let record: Record
    public init(_ record: Record) { self.record = record }
    public var id: String { record.id }
    public var name: String { record["name"]?.string ?? "Untitled" }
    public var parent: String? { record["parent"]?.string }
    /// Made by the organiser rather than by hand.
    public var isAuto: Bool { record["auto"]?.bool ?? false }
    public var color: String? { record["color"]?.string }
}

extension Folder {
    /// The folder tree in display order: (folder, depth), children sorted by name. Folders whose
    /// parent is missing or deleted show at the top level; cycles are broken.
    public static func tree(_ folders: [Folder]) -> [(folder: Folder, depth: Int)] {
        let ids = Set(folders.map(\.id))
        let children = Dictionary(grouping: folders) { f in f.parent.flatMap { ids.contains($0) && $0 != f.id ? $0 : nil } ?? "" }
        var out: [(Folder, Int)] = []
        var seen: Set<String> = []
        func walk(_ key: String, _ depth: Int) {
            for f in (children[key] ?? []).sorted(by: { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) where seen.insert(f.id).inserted {
                out.append((f, depth))
                walk(f.id, depth + 1)
            }
        }
        walk("", 0)
        // Anything left is in a cycle; show it at the top.
        for f in folders where !seen.contains(f.id) { seen.insert(f.id); out.append((f, 0)); walk(f.id, 1) }
        return out
    }

    /// The names from the top folder down to this one.
    public static func path(of id: String, in folders: [Folder]) -> [Folder] {
        let byId = Dictionary(folders.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [Folder] = []
        var current = byId[id]
        while let f = current, !out.contains(where: { $0.id == f.id }) {
            out.insert(f, at: 0)
            current = f.parent.flatMap { byId[$0] }
        }
        return out
    }
}
