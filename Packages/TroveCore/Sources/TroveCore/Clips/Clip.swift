import Foundation

/// Clipboard history (PROTOCOL.md §8). Every copy on a device with clipboard history on becomes a
/// `clip` record, synced and encrypted like everything else, kept apart from library items.
public struct Clip: Identifiable, Hashable, Sendable {
    public let record: Record
    public init(_ record: Record) { self.record = record }

    public enum Field {
        public static let text = "text", image = "image", files = "files", hash = "hash"
        public static let sourceApp = "sourceApp", sourceDevice = "sourceDevice", device = "device"
        public static let createdAt = "createdAt", lastUsedAt = "lastUsedAt", pinned = "pinned", savedItem = "savedItem"
        // Where it came from, beyond the app (Mac): the page or document, and the app's bundle id.
        public static let sourceURL = "sourceURL", sourceTitle = "sourceTitle", sourceBundle = "sourceBundle"
        // Worked out on copy (ClipInsights), then by AI enrichment, then by you.
        public static let autoTitle = "autoTitle", stats = "stats", entities = "entities"
        public static let aiTitle = "aiTitle", summary = "summary", ocrText = "ocrText", enrichment = "enrichment", needsEnrichment = "needsEnrichment"
        public static let title = "title", tags = "tags", note = "note", editedAt = "editedAt", uses = "uses"
    }

    public var id: String { record.id }
    public var text: String { record[Field.text]?.string ?? "" }
    /// An image clip's attachment (encrypted blob, like item attachments).
    public var image: Attachment? {
        guard let o = record[Field.image]?.object, let id = o["id"]?.string else { return nil }
        return Attachment(id: id, name: o["name"]?.string ?? "image.png", mime: o["mime"]?.string ?? "image/png", size: Int(o["size"]?.number ?? 0))
    }
    /// File paths, when files were copied (Mac).
    public var files: [String] { record[Field.files]?.stringArray ?? [] }
    public var hash: String { record[Field.hash]?.string ?? "" }
    public var sourceApp: String? { record[Field.sourceApp]?.string }
    public var sourceDevice: String? { record[Field.sourceDevice]?.string }
    public var device: String? { record[Field.device]?.string }
    public var createdAt: Date { record[Field.createdAt]?.date ?? Date(timeIntervalSince1970: 0) }
    public var lastUsedAt: Date { record[Field.lastUsedAt]?.date ?? createdAt }
    public var isPinned: Bool { record[Field.pinned]?.bool ?? false }
    /// The library item this clip was saved as, if any.
    public var savedItem: String? { record[Field.savedItem]?.string }
    public var sourceURL: URL? { record[Field.sourceURL]?.string.flatMap(URL.init(string:)) }
    /// The window, page or document title it was copied from (Mac).
    public var sourceTitle: String? { record[Field.sourceTitle]?.string.flatMap { $0.isEmpty ? nil : $0 } }
    public var sourceBundle: String? { record[Field.sourceBundle]?.string }
    /// The name you gave it.
    public var title: String? { record[Field.title]?.string.flatMap { $0.isEmpty ? nil : $0 } }
    public var aiTitle: String? { record[Field.aiTitle]?.string.flatMap { $0.isEmpty ? nil : $0 } }
    public var autoTitle: String { record[Field.autoTitle]?.string ?? ClipInsights.of(text, kind: kind).autoTitle }
    /// Your name for it, else the AI's, else one worked out from the text.
    public var displayTitle: String {
        if let title { return title }
        if let aiTitle { return aiTitle }
        if kind == .image { return image?.name ?? "Image" }
        if kind == .file { return preview }
        let auto = autoTitle
        return auto.isEmpty ? "Clip" : auto
    }
    public var summary: String? { record[Field.summary]?.string.flatMap { $0.isEmpty ? nil : $0 } }
    public var tags: [String] { record[Field.tags]?.stringArray ?? [] }
    public var note: String { record[Field.note]?.string ?? "" }
    /// Other clips and library items this one is connected to.
    public var links: [String] { record["links"]?.stringArray ?? [] }
    /// Text found in a copied image.
    public var ocrText: String? { record[Field.ocrText]?.string.flatMap { $0.isEmpty ? nil : $0 } }
    public var editedAt: Date? { record[Field.editedAt]?.date }
    /// How many times it was copied again or pasted from history.
    public var uses: Int { Int(record[Field.uses]?.number ?? 0) }
    public var needsEnrichment: Bool { record[Field.needsEnrichment]?.bool ?? false }
    public var enrichment: Enrichment? { record[Field.enrichment].flatMap(Enrichment.init(json:)) }
    public var insights: ClipInsights {
        let stats = record[Field.stats]?.object, e = record[Field.entities]?.object
        guard let stats, let e else { return ClipInsights.of(text, kind: kind) }
        return ClipInsights(autoTitle: autoTitle, chars: Int(stats["chars"]?.number ?? 0), words: Int(stats["words"]?.number ?? 0),
                            lines: Int(stats["lines"]?.number ?? 0), links: e["links"]?.stringArray ?? [], emails: e["emails"]?.stringArray ?? [],
                            phones: e["phones"]?.stringArray ?? [], colors: e["colors"]?.stringArray ?? [], hashtags: e["hashtags"]?.stringArray ?? [])
    }

    /// Most recent activity: copied again or pasted from history moves a clip to the top.
    public var sortDate: Date { max(createdAt, lastUsedAt) }
    public var kind: ClipKind { image != nil ? .image : !files.isEmpty ? .file : ClipClassifier.classify(text) }

    /// One line for lists.
    public var preview: String {
        switch kind {
        case .image: return image?.name ?? "Image"
        case .file: return files.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
        default:
            let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
            return String(line.trimmingCharacters(in: .whitespaces).prefix(200))
        }
    }

    /// Searches everything known about the clip. `tag:x` (or `#x`), `app:x` and `is:pinned` narrow it down.
    public func matches(_ query: String) -> Bool {
        ClipQuery(query).matches(self, haystack: searchText)
    }

    /// Everything searchable about the clip in one folded (lowercase, no accents) string. Lists keep
    /// it per clip so each keystroke is only `contains` checks (`ClipQuery`).
    public var searchText: String {
        // Built up in typed pieces: one long literal of `?? ""` is too much for the type checker.
        var parts: [String] = [text, displayTitle, autoTitle, note, tags.joined(separator: " "), files.joined(separator: " ")]
        let optional: [String?] = [aiTitle, summary, ocrText, sourceApp, sourceDevice, sourceTitle, sourceURL?.absoluteString, image?.name]
        parts += optional.compactMap { $0 }
        return ClipQuery.fold(parts.joined(separator: "\n"))
    }

    /// Stable content hash for de-duplication: the same text copied twice is one clip.
    public static func hash(text: String) -> String { "t:" + text.sha256Hex }
    public static func hash(image: Data) -> String { "i:" + image.sha256Hex }
    public static func hash(files: [String]) -> String { "f:" + files.joined(separator: "\n").sha256Hex }
}

public enum ClipKind: String, CaseIterable, Sendable {
    case text, link, email, phone, color, code, json, number, path, image, file

    public var title: String {
        switch self {
        case .text: "Text"
        case .link: "Links"
        case .email: "Emails"
        case .phone: "Phone numbers"
        case .color: "Colors"
        case .code: "Code"
        case .json: "JSON"
        case .number: "Numbers"
        case .path: "Paths"
        case .image: "Images"
        case .file: "Files"
        }
    }

    public var symbol: String {
        switch self {
        case .text: "text.alignleft"
        case .link: "link"
        case .email: "envelope"
        case .phone: "phone"
        case .color: "paintpalette"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .json: "curlybraces"
        case .number: "number"
        case .path: "folder"
        case .image: "photo"
        case .file: "doc"
        }
    }
}

/// Works out what a copied string is, so the history can show a swatch for a color, a host for a
/// link, monospace for code and so on. Kept in step with web/public/core/clips.js.
public enum ClipClassifier {
    public static func classify(_ raw: String) -> ClipKind {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return .text }
        let oneLine = !s.contains("\n")
        if oneLine, color(s) != nil { return .color }
        if oneLine, !s.contains(" "), let url = URL(string: s), let scheme = url.scheme?.lowercased(),
           ["http", "https"].contains(scheme), url.host != nil { return .link }
        if oneLine, s.wholeMatch(of: /[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/) != nil { return .email }
        if oneLine, s.wholeMatch(of: /\+?[0-9][0-9 ()\-.]{6,}[0-9]/) != nil, s.filter(\.isNumber).count >= 7 { return .phone }
        if oneLine, s.wholeMatch(of: /[-+]?[0-9]{1,3}(,?[0-9]{3})*(\.[0-9]+)?%?/) != nil { return .number }
        if oneLine, s.wholeMatch(of: /(~|\/)[^\s]*/) != nil, s.count > 1 { return .path }
        if (s.hasPrefix("{") && s.hasSuffix("}")) || (s.hasPrefix("[") && s.hasSuffix("]")),
           let data = s.data(using: .utf8), (try? JSONSerialization.jsonObject(with: data)) != nil { return .json }
        if looksLikeCode(s) { return .code }
        return .text
    }

    /// RGB(A) 0…1 for `#rgb`, `#rrggbb`, `#rrggbbaa`, `rgb(…)`/`rgba(…)` and `hsl(…)`/`hsla(…)`.
    public static func color(_ s: String) -> (r: Double, g: Double, b: Double, a: Double)? {
        let t = s.trimmingCharacters(in: .whitespaces).lowercased()
        if let m = t.wholeMatch(of: /#([0-9a-f]{3}|[0-9a-f]{6}|[0-9a-f]{8})/) {
            var hex = String(m.1)
            if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
            guard let v = UInt64(hex, radix: 16) else { return nil }
            if hex.count == 8 {
                return (Double((v >> 24) & 255) / 255, Double((v >> 16) & 255) / 255, Double((v >> 8) & 255) / 255, Double(v & 255) / 255)
            }
            return (Double((v >> 16) & 255) / 255, Double((v >> 8) & 255) / 255, Double(v & 255) / 255, 1)
        }
        if let m = t.wholeMatch(of: /rgba?\(\s*(\d{1,3})\s*,\s*(\d{1,3})\s*,\s*(\d{1,3})\s*(?:,\s*([0-9.]+)\s*)?\)/),
           let r = Double(m.1), let g = Double(m.2), let b = Double(m.3), r <= 255, g <= 255, b <= 255 {
            return (r / 255, g / 255, b / 255, m.4.flatMap { Double($0) } ?? 1)
        }
        if let m = t.wholeMatch(of: /hsla?\(\s*(\d{1,3})\s*,\s*(\d{1,3})%\s*,\s*(\d{1,3})%\s*(?:,\s*([0-9.]+)\s*)?\)/),
           let h = Double(m.1), let sat = Double(m.2), let l = Double(m.3) {
            let (r, g, b) = hslToRGB(h / 360, sat / 100, l / 100)
            return (r, g, b, m.4.flatMap { Double($0) } ?? 1)
        }
        return nil
    }

    static func hslToRGB(_ h: Double, _ s: Double, _ l: Double) -> (Double, Double, Double) {
        guard s > 0 else { return (l, l, l) }
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s
        let p = 2 * l - q
        func hue(_ t0: Double) -> Double {
            var t = t0
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1 / 6 { return p + (q - p) * 6 * t }
            if t < 1 / 2 { return q }
            if t < 2 / 3 { return p + (q - p) * (2 / 3 - t) * 6 }
            return p
        }
        return (hue(h + 1 / 3), hue(h), hue(h - 1 / 3))
    }

    static func looksLikeCode(_ s: String) -> Bool {
        let lines = s.split(whereSeparator: \.isNewline)
        let signals = [";\n", "{\n", "}\n", "=>", "func ", "def ", "const ", "let ", "var ", "import ", "return ", "class ", "#include",
                       "</", "/>", "SELECT ", "fn ", "console.", "print(", "&&", "||", "!=", "==="]
        let hits = signals.filter { s.contains($0) }.count
        let indented = lines.filter { $0.hasPrefix("    ") || $0.hasPrefix("\t") }.count
        let symbols = s.filter { "{}();=<>[]".contains($0) }.count
        if lines.count >= 2 { return hits >= 2 || (indented >= 1 && hits >= 1) || Double(symbols) / Double(max(s.count, 1)) > 0.06 }
        return hits >= 2 && Double(symbols) / Double(max(s.count, 1)) > 0.05
    }
}

/// Looks for things that shouldn't sit in a synced history: passwords, API keys, private keys and
/// one-time codes. Those clips stay on the device and expire after a couple of minutes.
public enum SensitiveDetector {
    public static func isSensitive(_ raw: String) -> Bool {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, s.count <= 4_000 else { return false }
        if s.contains("PRIVATE KEY-----") { return true }
        let oneToken = !s.contains(where: \.isWhitespace)
        guard oneToken else { return false }
        // One-time codes: 4–8 digits on their own.
        if s.count >= 4, s.count <= 8, s.allSatisfy(\.isNumber) { return true }
        // Well-known token shapes.
        let prefixes = ["sk-", "sk_live_", "sk_test_", "rk_live_", "ghp_", "gho_", "ghu_", "ghs_", "github_pat_", "xoxb-", "xoxp-", "xoxa-",
                        "AKIA", "ASIA", "AIza", "ya29.", "glpat-", "npm_", "pypi-", "SG.", "shpat_", "cfut_", "eyJ"]
        if s.count >= 16, prefixes.contains(where: { s.hasPrefix($0) }) { return true }
        if URL(string: s)?.scheme != nil, s.contains("://") { return false }
        // Password-like: 8–64 chars with a digit, mixing at least three of lower, upper, digits, symbols.
        // (Only for plain text: compact JSON, colors and paths mix character classes too. Words with
        // punctuation, like "Tuesday," or "Hello-World", and file names aren't passwords.)
        if s.count >= 8, s.count <= 64, ClipClassifier.classify(s) == .text, s.contains(where: \.isNumber),
           s.range(of: #"^[\w\- ]+\.[A-Za-z0-9]{2,4}$"#, options: .regularExpression) == nil {
            let classes = [s.contains(where: \.isLowercase), s.contains(where: \.isUppercase), true,
                           s.contains(where: { !$0.isLetter && !$0.isNumber })].filter { $0 }.count
            if classes >= 3, !s.contains("@"), !s.hasPrefix("/"), !s.hasPrefix("~") { return true }
        }
        // Long random-looking tokens.
        if s.count >= 24, s.count <= 200, entropy(s) > 4.0 { return true }
        return false
    }

    static func entropy(_ s: String) -> Double {
        var counts: [Character: Double] = [:]
        for c in s { counts[c, default: 0] += 1 }
        let n = Double(s.count)
        return counts.values.reduce(0) { $0 - ($1 / n) * log2($1 / n) }
    }
}

/// Quick rewrites offered when pasting from history.
public enum ClipTransform: String, CaseIterable, Sendable {
    case trimmed, singleLine, uppercase, lowercase, titleCase, cleanLink, prettyJSON, minifiedJSON

    public var title: String {
        switch self {
        case .trimmed: "Trim whitespace"
        case .singleLine: "Join into one line"
        case .uppercase: "UPPERCASE"
        case .lowercase: "lowercase"
        case .titleCase: "Title Case"
        case .cleanLink: "Remove link tracking"
        case .prettyJSON: "Pretty JSON"
        case .minifiedJSON: "Minify JSON"
        }
    }

    /// Transforms that make sense for this text (and change it).
    public static func available(for text: String) -> [ClipTransform] {
        allCases.filter { t in t.apply(text).map { $0 != text } ?? false }
    }

    public func apply(_ text: String) -> String? {
        switch self {
        case .trimmed: return text.trimmingCharacters(in: .whitespacesAndNewlines)
        case .singleLine:
            return text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
        case .uppercase: return text.uppercased()
        case .lowercase: return text.lowercased()
        case .titleCase: return text.capitalized
        case .cleanLink:
            guard ClipClassifier.classify(text) == .link, let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
            return URLCleaner.clean(url).absoluteString
        case .prettyJSON, .minifiedJSON:
            guard let data = text.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
                  object is [Any] || object is [String: Any] else { return nil }
            let options: JSONSerialization.WritingOptions = self == .prettyJSON ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
            return (try? JSONSerialization.data(withJSONObject: object, options: options)).map { String(decoding: $0, as: UTF8.self) }
        }
    }
}

/// A parsed clipboard search: free words (all must appear), `tag:x` / `#x`, `app:x`, `is:pinned`.
public struct ClipQuery: Sendable, Equatable {
    public var words: [String] = []
    public var tags: [String] = []
    public var apps: [String] = []
    public var pinnedOnly = false
    public var isEmpty: Bool { words.isEmpty && tags.isEmpty && apps.isEmpty && !pinnedOnly }

    public init(_ query: String) {
        for token in query.split(whereSeparator: \.isWhitespace) {
            let w = String(token)
            let lower = w.lowercased()
            if lower.hasPrefix("tag:"), lower.count > 4 { tags.append(String(lower.dropFirst(4)).replacingOccurrences(of: "#", with: "")) }
            else if lower.hasPrefix("#"), lower.count > 1 { tags.append(String(lower.dropFirst())) }
            else if lower.hasPrefix("app:"), lower.count > 4 { apps.append(Self.fold(String(w.dropFirst(4)))) }
            else if lower == "is:pinned" { pinnedOnly = true }
            else { words.append(Self.fold(w)) }
        }
    }

    public static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// `haystack` is the clip's `searchText`, kept by the caller.
    public func matches(_ clip: Clip, haystack: String) -> Bool {
        if pinnedOnly, !clip.isPinned { return false }
        if !tags.isEmpty {
            let have = clip.tags
            for t in tags where !have.contains(t) { return false }
        }
        if !apps.isEmpty {
            let app = Self.fold(clip.sourceApp ?? "")
            for a in apps where !app.contains(a) { return false }
        }
        for w in words where !haystack.contains(w) { return false }
        return true
    }
}
