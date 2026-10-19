import Foundation
import NaturalLanguage
import TroveCore

/// "Search by meaning" on every device (Tier 0): NLEmbedding sentence vectors, kept in memory and
/// rebuilt locally from synced content (never synced). Blended into keyword search scores.
actor SemanticIndex {
    private var vectors: [String: [Double]] = [:]
    private var versions: [String: String] = [:]
    private let embedding = NLEmbedding.sentenceEmbedding(for: .english)

    var isAvailable: Bool { embedding != nil }

    func update(_ items: [Item]) {
        guard let embedding else { return }
        let live = Set(items.map(\.id))
        for id in vectors.keys where !live.contains(id) {
            vectors[id] = nil
            versions[id] = nil
        }
        for item in items where versions[item.id] != item.record.updatedHLC {
            let text = [item.title, item.summary ?? "", item.tags.joined(separator: " "), String(item.body.prefix(400)), String((item.ocrText ?? "").prefix(200))]
                .filter { !$0.isEmpty }.joined(separator: ". ")
            if let v = embedding.vector(for: text) { vectors[item.id] = v }
            versions[item.id] = item.record.updatedHLC
        }
    }

    /// Cosine similarity of every item to the query, 0…1, only the meaningful ones.
    func scores(for query: String, minimum: Double = 0.3) -> [String: Double] {
        guard let embedding, query.count >= 3, let q = embedding.vector(for: query) else { return [:] }
        let qn = sqrt(q.reduce(0) { $0 + $1 * $1 })
        var out: [String: Double] = [:]
        for (id, v) in vectors {
            var dot = 0.0, vn = 0.0
            for i in 0..<min(q.count, v.count) {
                dot += q[i] * v[i]
                vn += v[i] * v[i]
            }
            let sim = dot / max(qn * sqrt(vn), 1e-9)
            if sim >= minimum { out[id] = sim }
        }
        return out
    }

    /// Nearest neighbours for "Similar items".
    func similar(to id: String, limit: Int = 6) -> [String] {
        guard let v = vectors[id] else { return [] }
        let vn = sqrt(v.reduce(0) { $0 + $1 * $1 })
        return vectors.filter { $0.key != id }.map { other -> (String, Double) in
            var dot = 0.0, on = 0.0
            for i in 0..<min(v.count, other.value.count) {
                dot += v[i] * other.value[i]
                on += other.value[i] * other.value[i]
            }
            return (other.key, dot / max(vn * sqrt(on), 1e-9))
        }.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }
}
