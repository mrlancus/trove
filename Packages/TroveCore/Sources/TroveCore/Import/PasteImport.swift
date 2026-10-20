import Foundation

/// Import from Paste (pasteapp.io), which has no export: its Core Data database, read directly
/// (`SQLiteReader`, `BinaryPlist`), like web/public/core/pasteimport.js; both check the same test
/// databases. Newer Paste keeps `db.sqlite` (ZITEMENTITY rows, ZITEMDATAENTITY pasteboard blobs,
/// ZAPPLICATIONENTITY apps, ZLISTENTITY pinboards); older Paste `Paste.db` (ZSNIPPET). Neither
/// layout is documented, so tables and columns are found by their names and contents, and
/// anything that can't be read is skipped and counted.
public enum PasteImport {
    public struct Entry: Sendable, Equatable {
        public var text: String?
        public var image: Data?
        public var imageMime: String?
        public var url: String?
        public var createdAt: Date?
        public var app: String?
        public var bundle: String?
        public var title: String?
        public var pinboards: [String] = []
    }

    public struct Result: Sendable {
        public var entries: [Entry]
        public var skipped: Int
        public var tables: [String]
    }

    /// Where Paste keeps its database on this Mac (App Store, direct download and Setapp copies),
    /// newest first. Each is the database and its `-wal`, when there is one.
    public static func candidates(home: URL = URL(fileURLWithPath: NSHomeDirectory())) -> [(db: URL, wal: URL?)] {
        let fm = FileManager.default
        let library = home.appendingPathComponent("Library")
        var roots: [URL] = []
        for base in [library.appendingPathComponent("Containers"), library.appendingPathComponent("Application Support"),
                     library.appendingPathComponent("Group Containers")] {
            for name in (try? fm.contentsOfDirectory(atPath: base.path)) ?? [] where name.lowercased().contains("wiheads") || name == "Paste" {
                roots.append(base.appendingPathComponent(name))
            }
        }
        var found: [(URL, Date)] = []
        for root in roots {
            guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsPackageDescendants]) else { continue }
            for case let url as URL in walker {
                if walker.level > 7 { walker.skipDescendants(); continue }
                let name = url.lastPathComponent
                guard name == "db.sqlite" || name == "Paste.db" else { continue }
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                found.append((url, date))
            }
        }
        return found.sorted { $0.1 > $1.1 }.map { db, _ in
            let wal = URL(fileURLWithPath: db.path + "-wal")
            return (db, fm.fileExists(atPath: wal.path) ? wal : nil)
        }
    }

    /// Core Data dates are seconds since 2001; Unix seconds and milliseconds are taken too.
    public static func date(_ v: Double?) -> Date? {
        guard let v, v.isFinite, v > 0 else { return nil }
        if v > 1e12 { return Date(timeIntervalSince1970: (v / 1000).rounded(.toNearestOrEven)) }
        if v > 1.5e9 { return Date(timeIntervalSince1970: v) }
        return Date(timeIntervalSinceReferenceDate: v)
    }

    public static func imageMime(_ d: Data) -> String? {
        let b = [UInt8](d.prefix(4))
        if b.starts(with: [0x89, 0x50, 0x4e, 0x47]) { return "image/png" }
        if b.starts(with: [0xff, 0xd8, 0xff]) { return "image/jpeg" }
        if b.starts(with: [0x47, 0x49, 0x46]) { return "image/gif" }
        return nil
    }

    static let textTypes = ["public.utf8-plain-text", "public.plain-text", "nsstringpboardtype", "public.text", "public.utf16-plain-text", "public.utf16-external-plain-text"]
    static let urlTypes = ["public.url", "public.url-name", "nsurlpboardtype", "public.file-url", "nsfilenamespboardtype"]
    static let imageTypes = ["public.png", "public.jpeg", "apple png pasteboard type", "public.tiff", "nstiffpboardtype"]

    static func looksLikeType(_ s: String) -> Bool {
        guard s.count < 120 else { return false }
        let lower = s.lowercased()
        if lower.hasSuffix("pboardtype") || lower.contains("pasteboard type") { return true }
        let parts = lower.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count >= 2 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" } && $0.allSatisfy(\.isASCII) }
    }

    static func text(_ v: PlistValue, type: String = "") -> String? {
        switch v {
        case .string(let s): return s
        case .data(let d):
            if type.contains("utf16") {
                var units: [UInt16] = []
                var i = d.startIndex
                while i + 1 < d.endIndex { units.append(UInt16(d[i]) | UInt16(d[i + 1]) << 8); i += 2 }
                var s = String(decoding: units, as: UTF16.self)
                if s.hasPrefix("\u{feff}") { s.removeFirst() }
                return s
            }
            return String(data: d, encoding: .utf8)
        default: return nil
        }
    }

    /// Every (pasteboard type, value) pair found anywhere in a decoded value, and every string.
    static func flavours(_ value: PlistValue) -> (pairs: [(String, PlistValue)], strings: [String]) {
        var pairs: [(String, PlistValue)] = [], strings: [String] = []
        func walk(_ v: PlistValue, _ depth: Int) {
            guard depth < 40 else { return }
            switch v {
            case .string(let s): strings.append(s)
            case .data(let d): if let inner = BinaryPlist.decode(d) { walk(inner, depth + 1) }
            case .array(let a):
                var i = 0
                while i + 1 < a.count {
                    if let t = a[i].string, looksLikeType(t), !(a[i + 1].string.map(looksLikeType) ?? false) { pairs.append((t.lowercased(), a[i + 1])) }
                    i += 2
                }
                for x in a { walk(x, depth + 1) }
            case .dict(let d):
                var typeField: String?, dataField: PlistValue?
                for (k, x) in d.sorted(by: { $0.key < $1.key }) where k != "$class" {
                    if looksLikeType(k) { pairs.append((k.lowercased(), x)) }
                    if ["type", "uti", "identifier", "pasteboardtype"].contains(k.lowercased()), let t = x.string, looksLikeType(t) { typeField = t }
                    if ["data", "value", "content", "rawdata"].contains(k.lowercased()) { dataField = x }
                    walk(x, depth + 1)
                }
                if let typeField, let dataField { pairs.append((typeField.lowercased(), dataField)) }
            default: break
            }
        }
        walk(value, 0)
        return (pairs, strings)
    }

    /// What one pasteboard payload holds.
    static func read(_ value: SQLiteReader.Value) -> (text: String?, image: Data?, url: String?) {
        switch value {
        case .text(let s): return (s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : s, nil, nil)
        case .blob(let blob):
            if imageMime(blob) != nil { return (nil, blob, nil) }
            guard let decoded = BinaryPlist.decode(blob) else {
                guard let t = String(data: blob, encoding: .utf8), !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !t.unicodeScalars.contains(where: { $0.value < 9 || (14...31).contains($0.value) }) else { return (nil, nil, nil) }
                return (t, nil, nil)
            }
            let (pairs, strings) = flavours(decoded)
            var out: (text: String?, image: Data?, url: String?) = (nil, nil, nil)
            for want in textTypes {
                if let hit = pairs.first(where: { $0.0 == want && !(text($0.1, type: $0.0)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) }) {
                    out.text = text(hit.1, type: hit.0); break
                }
            }
            for want in urlTypes {
                if let hit = pairs.first(where: { $0.0 == want && !(text($0.1)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) }) {
                    out.url = text(hit.1)?.trimmingCharacters(in: .whitespacesAndNewlines); break
                }
            }
            for want in imageTypes {
                if let hit = pairs.first(where: { $0.0 == want && $0.1.data.flatMap(imageMime) != nil }) { out.image = hit.1.data; break }
            }
            if out.image == nil, let any = pairs.first(where: { $0.1.data.flatMap(imageMime) != nil }) { out.image = any.1.data }
            if out.text == nil, out.url == nil, out.image == nil {
                // No pasteboard types: the longest string that isn't a class or type name.
                out.text = strings.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !looksLikeType($0) && !$0.hasPrefix("NS") && !$0.hasPrefix("$") }
                    .max { $0.count < $1.count }
            }
            if out.text == nil, let url = out.url { out.text = url }
            return out
        default:
            return (nil, nil, nil)
        }
    }

    private static func column(_ row: SQLiteReader.Row, _ test: (String) -> Bool) -> String? {
        row.values.keys.sorted().first(where: test)
    }

    private static func table(_ db: SQLiteReader, _ test: (String) -> Bool) -> SQLiteReader.Table? {
        db.tables.filter { test($0.name.uppercased()) }.max { $0.columns.count < $1.columns.count }
    }

    /// Everything in a Paste database, oldest first, and how many rows couldn't be read.
    public static func read(_ data: Data, wal: Data? = nil) throws -> Result {
        let db = try SQLiteReader(data, wal: wal)
        let exact: Set<String> = ["ZITEM", "ZITEMENTITY", "ZSNIPPET", "ZCLIP", "ZCLIPENTITY", "ZENTRY", "ZENTRYENTITY"]
        guard let items = table(db, { exact.contains($0) })
                ?? table(db, { $0.hasPrefix("Z") && !$0.hasPrefix("Z_") && ($0.contains("ITEM") || $0.contains("SNIPPET") || $0.contains("CLIP"))
                    && !$0.contains("DATA") && !$0.contains("LIST") && !$0.contains("APP") }) else {
            throw SQLiteReader.Failure.damaged("no items table: this doesn't look like Paste's database")
        }
        let dataTable = table(db) { $0.hasPrefix("Z") && !$0.hasPrefix("Z_") && $0.contains("DATA") }
        let appTable = table(db) { $0.hasPrefix("Z") && !$0.hasPrefix("Z_") && $0.contains("APP") }
        let listTable = table(db) { $0.hasPrefix("Z") && !$0.hasPrefix("Z_") && ($0.contains("LIST") || $0.contains("PINBOARD") || $0.contains("BOARD")) }
        func pk(_ r: SQLiteReader.Row) -> Int64 { r["Z_PK"].int ?? r.rowid }

        var apps: [Int64: (name: String?, bundle: String?)] = [:]
        for r in try appTable.map(db.rows) ?? [] {
            let name = column(r) { $0.uppercased().contains("NAME") }.flatMap { r[$0].string }
            let bundle = column(r) { $0.uppercased().contains("BUNDLE") || $0.uppercased().contains("IDENTIFIER") }.flatMap { r[$0].string }
            apps[pk(r)] = (name, bundle)
        }
        var lists: [Int64: String] = [:]
        for r in try listTable.map(db.rows) ?? [] {
            if let n = column(r, { $0.uppercased().contains("NAME") || $0.uppercased().contains("TITLE") }).flatMap({ r[$0].string })?
                .trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty { lists[pk(r)] = n }
        }
        var blobs: [Int64: [Data]] = [:]
        for r in try dataTable.map(db.rows) ?? [] {
            guard let refColumn = column(r, { let u = $0.uppercased(); return (u.hasPrefix("Z") && u.contains("ITEM")) || u.hasPrefix("ZSNIPPET") || u.hasPrefix("ZOWNER") || u.hasPrefix("ZPARENT") }),
                  let ref = r[refColumn].int else { continue }
            for (k, v) in r.values.sorted(by: { $0.key < $1.key }) where !k.hasPrefix("Z_") { if let d = v.data { blobs[ref, default: []].append(d) } }
        }
        // Pinboards joined through a many-to-many table (Z_<n>ITEMS: two integer columns).
        var boards: [Int64: Set<String>] = [:]
        for t in db.tables where t.name.hasPrefix("Z_") && t.name.dropFirst(2).first?.isNumber == true {
            let listKey = t.columns.first { let u = $0.uppercased(); return u.contains("LIST") || u.contains("BOARD") }
            let itemKey = t.columns.first { let u = $0.uppercased(); return u.contains("ITEM") || u.contains("SNIPPET") || u.contains("CLIP") }
            guard let listKey, let itemKey else { continue }
            for r in try db.rows(t) {
                if let l = r[listKey].int, let name = lists[l], let i = r[itemKey].int { boards[i, default: []].insert(name) }
            }
        }

        var out: [Entry] = []
        var skipped = 0
        for r in try db.rows(items) {
            let id = pk(r)
            let dateColumns = r.values.keys.filter { let u = $0.uppercased(); return (u.contains("DATE") || u.contains("TIME")) && r[$0].number != nil }
            let dateColumn = dateColumns.sorted().sorted { a, b in
                let wa = ["CREAT", "COPY", "ADD"].contains { a.uppercased().contains($0) }, wb = ["CREAT", "COPY", "ADD"].contains { b.uppercased().contains($0) }
                return wa && !wb
            }.first
            let appRef = column(r) { let u = $0.uppercased(); return u.hasPrefix("ZAPP") || u.contains("APPLICATION") || u == "ZSOURCE" }.flatMap { r[$0].int }
            let app = appRef.flatMap { apps[$0] }
            let bundleColumn = column(r) { $0.uppercased().contains("BUNDLE") }.flatMap { r[$0].string }
            let appName = column(r) { let u = $0.uppercased(); return (u.contains("APP") && u.contains("NAME")) || (u.contains("SOURCE") && u.contains("NAME")) }.flatMap { r[$0].string }
            let title = column(r) { ["ZTITLE", "ZNAME", "ZCUSTOMTITLE"].contains($0.uppercased()) }.flatMap { r[$0].string }?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            var pins = boards[id] ?? []
            if let l = column(r, { let u = $0.uppercased(); return u.hasPrefix("ZLIST") || u.hasPrefix("ZPINBOARD") || u.hasPrefix("ZBOARD") }).flatMap({ r[$0].int }),
               let name = lists[l] { pins.insert(name) }

            var text: String?, image: Data?, url: String?
            for k in r.values.keys.sorted() where ["TEXT", "STRING", "CONTENT", "PLAIN", "PREVIEW", "VALUE"].contains(where: { k.uppercased().contains($0) }) {
                let p = read(r[k])
                text = text ?? p.text; image = image ?? p.image; url = url ?? p.url
                if text != nil { break }
            }
            let own = r.values.sorted(by: { $0.key < $1.key }).filter { k, v in v.data != nil && !k.hasPrefix("Z_") && !k.uppercased().contains("ICON") && !k.uppercased().contains("THUMB") }
                .compactMap(\.value.data)
            for blob in own + (blobs[id] ?? []) {
                if text != nil && image != nil { break }
                let p = read(.blob(blob))
                text = text ?? p.text; image = image ?? p.image; url = url ?? p.url
            }
            guard text != nil || image != nil else { skipped += 1; continue }
            out.append(Entry(text: text, image: text == nil ? image : nil, imageMime: text == nil ? image.flatMap(imageMime) : nil, url: url,
                             createdAt: date(dateColumn.flatMap { r[$0].number }),
                             app: app?.name ?? appName, bundle: app?.bundle ?? bundleColumn,
                             title: title?.isEmpty == false ? title : nil,
                             pinboards: pins.filter { !["clipboard", "clipboard history"].contains($0.lowercased()) }.sorted()))
        }
        out.sort { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }
        return Result(entries: out, skipped: skipped, tables: db.tables.map(\.name))
    }
}

extension Library {
    /// Clips from another clipboard app (`PasteImport` entries), like the website's `importClips`:
    /// original times, app and pinboards (as tags) are kept; ones already here just gain the tags.
    @discardableResult
    public func importClips(_ entries: [PasteImport.Entry], source: String = "Paste",
                            progress: (@Sendable (_ done: Int, _ added: Int, _ latest: String?) async -> Void)? = nil) async -> (added: Int, merged: Int) {
        var added = 0, merged = 0
        var byHash = Dictionary(await clips().map { ($0.hash, $0) }, uniquingKeysWith: { a, _ in a })
        await engine.hold()
        var done = 0
        for e in entries {
            done += 1
            if let progress, done % 25 == 0 || done == entries.count {
                await progress(done, added, e.title ?? e.text.map { String($0.prefix(60)) } ?? (e.image != nil ? "Image" : nil))
            }
            let tags = Self.cleanTags(e.pinboards.compactMap { Self.cleanTagName($0) })
            var hash: String
            var fields: [String: JSONValue] = [:]
            if let text = e.text {
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 256 * 1024, !SensitiveDetector.isSensitive(text) else { continue }
                hash = Clip.hash(text: text)
                // Insights only for clips that are new here (they're the slow part of a big import).
                if byHash[hash] == nil {
                    fields[Clip.Field.text] = .string(text)
                    fields.merge(ClipInsights.of(text).json) { _, b in b }
                    let rule = ClipInsights.ruleTags(text)
                    if !rule.isEmpty || !tags.isEmpty { fields[Clip.Field.tags] = JSONValue(Self.cleanTags(rule + tags)) }
                }
            } else if let image = e.image {
                hash = Clip.hash(image: image)
                if byHash[hash] == nil {
                    guard let blob = try? await engine.storeBlob(image) else { continue }
                    let mime = e.imageMime ?? "image/png"
                    let ext = mime == "image/jpeg" ? "jpg" : (mime.split(separator: "/").last.map(String.init) ?? "png")
                    fields[Clip.Field.image] = Attachment(id: blob, name: "Image.\(ext)", mime: mime, size: image.count).json
                    fields[Clip.Field.autoTitle] = "Image"
                    if !tags.isEmpty { fields[Clip.Field.tags] = JSONValue(tags) }
                }
            } else { continue }
            if let existing = byHash[hash] {
                if tags.contains(where: { !existing.tags.contains($0) }) {
                    await engine.set([Clip.Field.tags: JSONValue(Self.cleanTags(existing.tags + tags))], record: existing.id, kind: "clip")
                }
                merged += 1
                continue
            }
            let at = e.createdAt ?? now()
            let id = newId()
            fields[Clip.Field.hash] = .string(hash)
            fields[Clip.Field.createdAt] = JSONValue(at)
            fields[Clip.Field.lastUsedAt] = JSONValue(at)
            fields[Clip.Field.device] = .string(await engine.device)
            fields[Clip.Field.sourceDevice] = .string("\(source) import")
            // Text was worked out above; only pictures need reading (OCR). Marking thousands of text
            // clips kept devices busy writing one tiny change per clip for hours.
            fields[Clip.Field.needsEnrichment] = .bool(e.text == nil)
            if let app = e.app { fields[Clip.Field.sourceApp] = .string(app) }
            if let bundle = e.bundle { fields[Clip.Field.sourceBundle] = .string(bundle) }
            if let url = e.url, url != e.text { fields[Clip.Field.sourceURL] = .string(url) }
            if let title = e.title { fields[Clip.Field.title] = .string(title) }
            await engine.set(fields, record: id, kind: "clip")
            await recordClipEvent(id, .copy, app: e.app, bundle: e.bundle, at: at)
            if let c = await clip(id) { byHash[hash] = c }
            added += 1
        }
        await engine.release()
        return (added, merged)
    }
}
