import Foundation

/// `trove-gen` (docs/MASTER_PLAN.md Q2, docs/PERF_AUDIT.md step 0): a seeded generator for big vaults,
/// so performance work has the same before and after on Linux, in CI and in the apps' UI tests.
/// The same seed and size always give the same ops, byte for byte.
///
///     let ops = TroveGen.ops(.full)                     // raw ops for RecordStore/SearchIndex benchmarks
///     try await TroveGen.writeFolderVault(at: url, .small)   // a real (unencrypted) folder vault
///
/// Sizes: `.full` is the budget vault of docs/prompts/develop-perf-testing.md Part 2 step 0 (50k items,
/// 50k clips, a 500-page notebook, a 10k-stroke whiteboard, 200 PDFs, one 500-page PDF).
public enum TroveGen {
    public struct Size: Sendable, Equatable, Codable {
        public var items: Int
        public var clips: Int
        public var notebookPages: Int
        public var strokesPerPage: Int
        public var whiteboardStrokes: Int
        public var pdfs: Int
        public var pagesPerPDF: Int
        public var bigPDFPages: Int
        public var seed: UInt64

        public init(items: Int, clips: Int, notebookPages: Int, strokesPerPage: Int, whiteboardStrokes: Int,
                    pdfs: Int, pagesPerPDF: Int, bigPDFPages: Int, seed: UInt64 = 42) {
            self.items = items; self.clips = clips; self.notebookPages = notebookPages; self.strokesPerPage = strokesPerPage
            self.whiteboardStrokes = whiteboardStrokes; self.pdfs = pdfs; self.pagesPerPDF = pagesPerPDF; self.bigPDFPages = bigPDFPages
            self.seed = seed
        }

        /// The budget vault.
        public static let full = Size(items: 50_000, clips: 50_000, notebookPages: 500, strokesPerPage: 200,
                                      whiteboardStrokes: 10_000, pdfs: 200, pagesPerPDF: 3, bigPDFPages: 500)
        /// For simulator UI tests (seconds to build, still big enough to scroll).
        public static let small = Size(items: 2_000, clips: 2_000, notebookPages: 40, strokesPerPage: 120,
                                       whiteboardStrokes: 2_000, pdfs: 10, pagesPerPDF: 3, bigPDFPages: 60)
        /// For unit tests.
        public static let tiny = Size(items: 50, clips: 50, notebookPages: 3, strokesPerPage: 10,
                                      whiteboardStrokes: 30, pdfs: 2, pagesPerPDF: 2, bigPDFPages: 5)

        public static func named(_ name: String) -> Size? {
            switch name.lowercased() { case "full": .full; case "small": .small; case "tiny": .tiny; default: nil }
        }

        /// Every size scaled by `f` (at least one of each), e.g. `TROVE_BENCH_SCALE`.
        public func scaled(_ f: Double) -> Size {
            func s(_ n: Int) -> Int { max(1, Int((Double(n) * f).rounded())) }
            return Size(items: s(items), clips: s(clips), notebookPages: s(notebookPages), strokesPerPage: strokesPerPage,
                        whiteboardStrokes: s(whiteboardStrokes), pdfs: s(pdfs), pagesPerPDF: pagesPerPDF, bigPDFPages: s(bigPDFPages), seed: seed)
        }
    }

    /// Fixed ids, so tests and UI tests can open them directly.
    public static let device = "TROVEGEN"
    public static let notebookId = "gen-notebook"
    public static let whiteboardId = "gen-whiteboard"
    public static let bigPDFId = "gen-big-pdf"
    /// 2023-11-14, so dates are stable whatever day the vault is made.
    static let epochMs: Int64 = 1_700_000_000_000

    static let words = ["plum", "jam", "cardamom", "river", "map", "lecture", "limits", "physics", "draft", "budget",
                        "invoice", "recipe", "garden", "ticket", "train", "meeting", "notes", "idea", "sketch", "chapter",
                        "momentum", "energy", "vector", "force", "orbit", "photon", "matrix", "theorem", "essay", "poem"]

    /// Text follows Zipf's law like real writing: a 20,000-word vocabulary (the real words above are
    /// the commonest, the rest made-up words from syllables) where the word of rank r turns up in
    /// proportion to 1/(r+1)^1.07. So a common word matches many notes and most words match few.
    static let vocabulary: [String] = {
        let onsets = ["b", "c", "d", "f", "g", "h", "k", "l", "m", "n", "p", "r", "s", "t", "v", "w", "z", "br", "st", "tr", "pl", "gr"]
        let vowels = ["a", "e", "i", "o", "u", "ai", "ou", "ea"]
        var out = words
        var seen = Set(words)
        var r = Seeded(2024)
        while out.count < 20_000 {
            let n = 2 + r.int(2)
            let w = (0..<n).map { _ in onsets[r.int(onsets.count)] + vowels[r.int(vowels.count)] }.joined() + ["", "n", "s", "r", "l"][r.int(5)]
            if seen.insert(w).inserted { out.append(w) }
        }
        return out
    }()
    static let zipfCumulative: [Double] = {
        var total = 0.0
        return vocabulary.indices.map { i in total += 1 / pow(Double(i + 1), 1.07); return total }
    }()

    /// SplitMix64: small, fast, the same on every platform.
    public struct Seeded: Sendable {
        public var state: UInt64
        public init(_ seed: UInt64) { state = seed }
        public mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        public mutating func unit() -> Double { Double(next() >> 11) / Double(UInt64(1) << 53) }
        public mutating func int(_ n: Int) -> Int { Int(next() % UInt64(max(1, n))) }
        mutating func word() -> String {
            let c = TroveGen.zipfCumulative
            let target = unit() * c[c.count - 1]
            var lo = 0, hi = c.count - 1
            while lo < hi { let mid = (lo + hi) / 2; if c[mid] < target { lo = mid + 1 } else { hi = mid } }
            return TroveGen.vocabulary[lo]
        }
        mutating func words(_ n: Int) -> String { (0..<n).map { _ in word() }.joined(separator: " ") }
    }

    /// A PDF the generator attaches: its id (sha256, as an unencrypted vault stores it) and bytes.
    public struct Blob: Sendable {
        public var id: String
        public var name: String
        public var data: Data
    }

    /// Every op of the vault, in order (one device, contiguous sequence numbers from 1).
    public static func ops(_ size: Size) -> [Op] { build(size).ops }

    /// The ops and the PDFs they point at.
    public static func build(_ size: Size) -> (ops: [Op], blobs: [Blob]) {
        var random = Seeded(size.seed)
        var ops: [Op] = []
        ops.reserveCapacity(size.items * 2 + size.clips + size.notebookPages * size.strokesPerPage + size.whiteboardStrokes + size.pdfs + 8)
        var seq = 0
        func next() -> (Int, HLC) {
            seq += 1
            return (seq, HLC(millis: epochMs + Int64(seq), counter: 0, device: device))
        }
        func set(_ fields: [String: JSONValue], _ record: String, _ kind: String) {
            let (s, h) = next()
            ops.append(.set(fields, record: record, kind: kind, device: device, seq: s, hlc: h))
        }
        func text(_ field: String, _ value: String, _ record: String) {
            let (s, h) = next()
            ops.append(.text(field, value: value, base: "", record: record, kind: "item", device: device, seq: s, hlc: h))
        }
        let day = 86_400_000.0
        // Items: notes with bodies, and links, spread over two years.
        for i in 0..<size.items {
            let id = "gen-item-\(i)"
            let created = Double(epochMs) - Double(random.int(730)) * day - Double(random.int(86_400)) * 1000
            let isNote = i % 3 != 0
            var fields: [String: JSONValue] = [
                "kind": .string(isNote ? "note" : "link"), "title": .string(random.words(2 + random.int(4)).capitalized),
                "tags": .array([.string(random.word())]), "source": .string(isNote ? "app" : "web"), "createdAt": .number(created),
            ]
            if !isNote { fields["url"] = .string("https://example.com/\(random.word())/\(i)") }
            set(fields, id, "item")
            if isNote {
                let paragraphs = (0..<(1 + random.int(6))).map { _ in random.words(12 + random.int(40)) + "." }
                var body = paragraphs.joined(separator: "\n\n")
                if random.int(10) == 0 { body += "\n\nSee [[\(random.words(2).capitalized)]]." }
                text("body", body, id)
            }
        }
        // Clips.
        for i in 0..<size.clips {
            let t: String = switch i % 5 {
            case 0: "https://example.org/\(random.word())?id=\(i)"
            case 1: "\(random.int(1000)).\(random.int(100)) \(random.word())"
            default: random.words(3 + random.int(30))
            }
            var fields: [String: JSONValue] = [
                Clip.Field.text: .string(t), Clip.Field.hash: .string(Clip.hash(text: t + "#\(i)")),
                Clip.Field.createdAt: .number(Double(epochMs) - Double(i) * 60_000), Clip.Field.device: .string(device),
                Clip.Field.sourceApp: .string(["Safari", "Notes", "Xcode", "Mail"][i % 4]),
            ]
            fields.merge(ClipInsights.of(t).json) { a, _ in a }
            set(fields, "gen-clip-\(i)", "clip")
        }
        // A notebook of pages and a whiteboard (one endless page).
        set(["kind": .string("sketch"), "title": .string("Generated notebook"), "pages": .number(Double(size.notebookPages)),
             "createdAt": .number(Double(epochMs))], notebookId, "item")
        var stroke = 0
        func addStroke(on item: String, page: Int, width: Double, height: Double) {
            var x = random.unit() * (width - 60) + 30, y = random.unit() * (height - 60) + 30
            var points: [InkPoint] = []
            for k in 0..<(20 + random.int(40)) {
                x += random.unit() * 6 - 3
                y += random.unit() * 6 - 3
                points.append(InkPoint(x: x, y: y, pressure: 0.5 + random.unit() * 0.5, t: Double(k) * 0.008))
            }
            stroke += 1
            set(["on": .string(item), "layer": .string(""), "page": .string(String(page)), "tool": .string("pen"),
                 "color": .string("#1c1c1e"), "width": .number(2), "points": .string(InkPoints.encode(points)),
                 "createdAt": .number(Double(stroke))], "gen-stroke-\(stroke)", "stroke")
        }
        for page in 0..<size.notebookPages {
            for _ in 0..<size.strokesPerPage { addStroke(on: notebookId, page: page, width: 768, height: 1024) }
        }
        set(["kind": .string("sketch"), "title": .string("Generated whiteboard"), "canvas": .string("infinite"), "pages": .number(1),
             "createdAt": .number(Double(epochMs))], whiteboardId, "item")
        for _ in 0..<size.whiteboardStrokes { addStroke(on: whiteboardId, page: 0, width: 6000, height: 4000) }
        // PDFs.
        var blobs: [Blob] = []
        func addPDF(_ id: String, title: String, pages: Int) {
            let data = pdf(pages: pages, title: title, seed: random.next())
            let blob = Blob(id: data.sha256Hex, name: "\(title).pdf", data: data)
            blobs.append(blob)
            let att = Attachment(id: blob.id, name: blob.name, mime: "application/pdf", size: data.count)
            set(["kind": .string("pdf"), "title": .string(title), "attachments": .array([att.json]), "source": .string("import"),
                 "createdAt": .number(Double(epochMs))], id, "item")
        }
        for i in 0..<size.pdfs { addPDF("gen-pdf-\(i)", title: "Generated PDF \(i)", pages: size.pagesPerPDF) }
        addPDF(bigPDFId, title: "Generated \(size.bigPDFPages)-page PDF", pages: size.bigPDFPages)
        return (ops, blobs)
    }

    /// A valid PDF with `pages` A4 pages of text (Helvetica, no fonts embedded), deterministic.
    public static func pdf(pages: Int, title: String, seed: UInt64 = 1) -> Data {
        var random = Seeded(seed)
        var objects: [String] = []   // object n is objects[n - 1]
        let pageCount = max(1, pages)
        // 1 catalog, 2 pages tree, 3 font, then per page: page, content.
        objects.append("<< /Type /Catalog /Pages 2 0 R >>")
        let kids = (0..<pageCount).map { "\(4 + $0 * 2) 0 R" }.joined(separator: " ")
        objects.append("<< /Type /Pages /Kids [\(kids)] /Count \(pageCount) >>")
        objects.append("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
        for p in 0..<pageCount {
            var lines = ["BT /F1 16 Tf 56 790 Td (\(escape(title)) - page \(p + 1)) Tj ET"]
            for l in 0..<30 {
                lines.append("BT /F1 11 Tf 56 \(760 - l * 22) Td (\(escape(random.words(8 + random.int(6))))) Tj ET")
            }
            let stream = lines.joined(separator: "\n")
            objects.append("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Resources << /Font << /F1 3 0 R >> >> /Contents \(5 + p * 2) 0 R >>")
            objects.append("<< /Length \(stream.utf8.count) >>\nstream\n\(stream)\nendstream")
        }
        var out = "%PDF-1.4\n"
        var offsets: [Int] = []
        for (i, body) in objects.enumerated() {
            offsets.append(out.utf8.count)
            out += "\(i + 1) 0 obj\n\(body)\nendobj\n"
        }
        let xref = out.utf8.count
        out += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for o in offsets { out += String(format: "%010d 00000 n \n", o) }
        out += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        return Data(out.utf8)
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "(", with: "\\(").replacingOccurrences(of: ")", with: "\\)")
    }

    /// Cuts ops into segments of at most `Segment.maxPlaintextBytes` (each op's JSON line counted).
    public static func segments(_ ops: [Op]) throws -> [Segment] {
        var out: [Segment] = []
        var batch: [Op] = []
        var bytes = 0
        let encoder = JSONEncoder()
        for op in ops {
            let n = try encoder.encode(op).count + 1
            if !batch.isEmpty, bytes + n > Segment.maxPlaintextBytes - 1024 {
                out.append(try Segment(device: device, ops: batch))
                batch = []
                bytes = 0
            }
            batch.append(op)
            bytes += n
        }
        if !batch.isEmpty { out.append(try Segment(device: device, ops: batch)) }
        return out
    }

    /// Writes an unencrypted folder vault (vault.json, `.sync/TROVEGEN/…`, `.blobs`) that any device
    /// can open like an iCloud vault. Returns its vault id. Never point this at a real vault.
    @discardableResult
    public static func writeFolderVault(at root: URL, _ size: Size) async throws -> String {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let transport = FolderTransport(root: root, name: "trove-gen")
        if let info = try transport.readVaultInfo() { return info.vaultId }
        let (ops, blobs) = build(size)
        for segment in try segments(ops) {
            try await transport.pushSegment(SegmentRef(device: device, first: segment.first, last: segment.last), data: try segment.plaintext())
        }
        for blob in blobs where !(try await transport.hasBlob(blob.id)) { try await transport.pushBlob(blob.id, data: blob.data) }
        let vaultId = "trove-gen-\(size.seed)-\(size.items)"
        // Written last: a folder with vault.json is complete.
        try transport.writeVaultInfo(.init(vaultId: vaultId, vaultPublicKey: "", encrypted: false, createdAt: Date(timeIntervalSince1970: Double(epochMs) / 1000)))
        return vaultId
    }
}
