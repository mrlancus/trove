import Accelerate
import Foundation
import NaturalLanguage
import TroveCore

/// "Search by meaning" on every device (Tier 0): NLEmbedding sentence vectors, normalised once and
/// kept as Float32, scored with Accelerate (`vDSP_dotpr`). Cached on disk so a launch doesn't embed
/// the whole library again; rebuilt locally from synced content (never synced). Its ranking is fused
/// with keyword search by reciprocal rank fusion (`SearchIndex.search(_:semantic:)`).
actor SemanticIndex {
    private struct Entry: Codable {
        var v: String
        var vec: [Float]
    }

    private struct Saved: Codable {
        var format: Int
        var entries: [String: Entry]
    }

    private var entries: [String: Entry] = [:]
    private let embedding = NLEmbedding.sentenceEmbedding(for: .english)
    private var cacheURL: URL?
    private var loaded = false
    private var dirty = false

    var isAvailable: Bool { embedding != nil }

    /// Where the vectors are cached; loads what's there the first time.
    func useCache(_ url: URL) {
        guard cacheURL != url else { return }
        cacheURL = url
        loaded = false
        loadIfNeeded()
    }

    private func loadIfNeeded() {
        guard !loaded, let cacheURL else { return }
        loaded = true
        guard let data = try? Data(contentsOf: cacheURL), let saved = try? JSONDecoder().decode(Saved.self, from: data), saved.format == 1 else { return }
        for (id, e) in saved.entries where entries[id] == nil { entries[id] = e }
    }

    func update(_ items: [Item]) {
        guard let embedding else { return }
        loadIfNeeded()
        let live = Set(items.map(\.id))
        for id in entries.keys where !live.contains(id) {
            entries[id] = nil
            dirty = true
        }
        for item in items where entries[item.id]?.v != item.record.updatedHLC {
            let text = [item.title, item.summary ?? "", item.tags.joined(separator: " "), String(item.body.prefix(400)), String((item.ocrText ?? "").prefix(200))]
                .filter { !$0.isEmpty }.joined(separator: ". ")
            let vec = embedding.vector(for: text).map(Self.normalised) ?? []
            entries[item.id] = Entry(v: item.record.updatedHLC, vec: vec)
            dirty = true
        }
        save()
    }

    private func save() {
        guard dirty, let cacheURL else { return }
        dirty = false
        guard let data = try? JSONEncoder().encode(Saved(format: 1, entries: entries)) else { return }
        try? data.write(to: cacheURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    static func normalised(_ v: [Double]) -> [Float] {
        let f = v.map { Float($0) }
        var sumSquares: Float = 0
        vDSP_svesq(f, 1, &sumSquares, vDSP_Length(f.count))
        var norm = sumSquares.squareRoot()
        guard norm > 1e-9 else { return f }
        var out = [Float](repeating: 0, count: f.count)
        vDSP_vsdiv(f, 1, &norm, &out, 1, vDSP_Length(f.count))
        return out
    }

    static func dot(_ a: [Float], _ b: [Float]) -> Float {
        let n = min(a.count, b.count)
        guard n > 0 else { return 0 }
        var out: Float = 0
        a.withUnsafeBufferPointer { pa in
            b.withUnsafeBufferPointer { pb in
                vDSP_dotpr(pa.baseAddress!, 1, pb.baseAddress!, 1, &out, vDSP_Length(n))
            }
        }
        return out
    }

    /// Cosine similarity of every item to the query, only the meaningful ones.
    func scores(for query: String, minimum: Float = 0.3) -> [String: Double] {
        guard let embedding, query.count >= 3, let q = embedding.vector(for: query) else { return [:] }
        let qv = Self.normalised(q)
        var out: [String: Double] = [:]
        for (id, e) in entries {
            let sim = Self.dot(qv, e.vec)
            if sim >= minimum { out[id] = Double(sim) }
        }
        return out
    }

    /// Nearest neighbours for "Similar items".
    func similar(to id: String, limit: Int = 6) -> [String] {
        guard let v = entries[id]?.vec, !v.isEmpty else { return [] }
        var scored: [(String, Float)] = []
        scored.reserveCapacity(entries.count)
        for (other, e) in entries where other != id { scored.append((other, Self.dot(v, e.vec))) }
        scored.sort { $0.1 > $1.1 }
        return scored.prefix(limit).map(\.0)
    }
}
