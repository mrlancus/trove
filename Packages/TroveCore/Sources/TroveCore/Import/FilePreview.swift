import Foundation

/// The readable parts of files that are zips inside: GoodNotes notebooks and Pages, Keynote and
/// Numbers documents. The website does the same in web/public/core/files.js.
public enum FilePreview {
    public struct Document: Sendable, Equatable {
        public var name: String
        public var mime: String
        public var data: Data
    }

    /// A GoodNotes notebook: its cover, its page count and the PDFs and images inside (the original
    /// documents; the handwriting itself is in GoodNotes' own format).
    public struct GoodNotes: Sendable, Equatable {
        public var thumbnail: Data?
        public var pages = 0
        public var documents: [Document] = []
    }

    public static func goodnotes(_ data: Data) -> GoodNotes? {
        guard let zip = try? ZipArchive(data) else { return nil }
        var out = GoodNotes()
        for entry in zip.entries where !entry.isDirectory {
            let lower = entry.path.lowercased()
            if out.thumbnail == nil, lower.range(of: #"(^|/)thumbnail\.(jpe?g|png)$"#, options: .regularExpression) != nil {
                out.thumbnail = try? zip.data(for: entry)
            } else if entry.path.hasPrefix("notes/") {
                out.pages += 1
            } else if entry.path.hasPrefix("attachments/"), entry.size < 200 * 1024 * 1024,
                      let bytes = try? zip.data(for: entry), let mime = sniff(bytes) {
                out.documents.append(Document(name: entry.name, mime: mime, data: bytes))
            }
        }
        return out
    }

    /// The preview image Pages, Keynote and Numbers save inside the file.
    public static func iworkPreview(_ data: Data) -> Data? {
        guard let zip = try? ZipArchive(data) else { return nil }
        for path in ["preview.jpg", "QuickLook/Preview.jpg", "preview-web.jpg", "QuickLook/Thumbnail.jpg", "preview-micro.jpg"] {
            if let entry = zip.entries.first(where: { $0.path == path }), let bytes = try? zip.data(for: entry) { return bytes }
        }
        return nil
    }

    /// What some bytes are, for files without a useful name.
    public static func sniff(_ data: Data) -> String? {
        let b = [UInt8](data.prefix(4))
        guard b.count >= 2 else { return nil }
        if b.count >= 4, b == [0x25, 0x50, 0x44, 0x46] { return "application/pdf" }
        if b.count >= 4, b == [0x89, 0x50, 0x4E, 0x47] { return "image/png" }
        if b[0] == 0xFF, b[1] == 0xD8 { return "image/jpeg" }
        if b.count >= 3, b[0] == 0x47, b[1] == 0x49, b[2] == 0x46 { return "image/gif" }
        return nil
    }
}
