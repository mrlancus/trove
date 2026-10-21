import Foundation

/// Clips in a postings index, for when there are too many to scan their text on every keystroke
/// (ROADMAP §3.5; below that, scanning `searchText` stays the way). Every word may be the start of
/// one, `-word` excludes; `tag:`, `#`, `app:` and `is:pinned` filter as in `ClipQuery`. Mirrors
/// core/search.js CLIP_FIELDS / clipDoc / clipIndexQuery.
public struct ClipIndex: Sendable {
    struct Meta: Sendable { var tags: [String]; var app: String }
    var engine = TermIndex()
    private var meta: [String: Meta] = [:]

    public init() {}

    public var count: Int { engine.count }
    /// The version (updatedHLC) indexed for a clip, to update only what changed.
    public func version(_ id: String) -> String? { engine.docs[id]?.v }
    public var ids: [String] { Array(engine.docs.keys) }

    static func fields(_ clip: Clip) -> [(String, Double)] {
        let source = [clip.sourceApp, clip.sourceTitle, clip.sourceURL?.absoluteString, clip.sourceDevice].compactMap { $0 }.filter { !$0.isEmpty }
            + clip.files + [clip.image?.name].compactMap { $0 }
        return [([clip.displayTitle, clip.aiTitle ?? ""].joined(separator: " "), 3), (clip.tags.joined(separator: " "), 2.5), (clip.text, 1), (clip.note, 1),
                (clip.summary ?? "", 1), (clip.ocrText ?? "", 1), (source.joined(separator: " "), 1)]
    }

    public mutating func update(_ clip: Clip) {
        remove(clip.id)
        guard !clip.record.isDeleted else { return }
        let terms = TermIndex.weigh(Self.fields(clip))
        let created = clip.record[Clip.Field.createdAt]?.number ?? 0
        let used = clip.record[Clip.Field.lastUsedAt]?.number ?? created
        engine.insert(clip.id, TermIndex.Doc(v: clip.record.updatedHLC, terms: terms, length: TermIndex.length(terms), createdAt: max(created, used),
                                             pinned: clip.isPinned, title: []))
        meta[clip.id] = Meta(tags: clip.tags, app: ClipQuery.fold(clip.sourceApp ?? ""))
    }

    public mutating func remove(_ id: String) {
        engine.remove(id)
        meta[id] = nil
    }

    public mutating func prepare() { engine.prepare() }

    /// Clip ids matching `query`, best first.
    public func search(_ query: ClipQuery, limit: Int = .max, now: Date = Date()) -> (ids: [String], total: Int) {
        var words: [String] = [], exclude: [String] = []
        for w in query.words {
            if w.count > 1, w.hasPrefix("-") { exclude += Tokenizer.terms(String(w.dropFirst())) } else { words.append(w) }
        }
        let plan = engine.plan(text: words.joined(separator: " "), exclude: exclude, prefixAll: true)
        let meta = self.meta
        let passes: (String, TermIndex.Doc) -> Bool = { id, doc in
            for t in plan.exclude where doc.terms[t] != nil { return false }
            if query.pinnedOnly, !doc.pinned { return false }
            guard let m = meta[id] else { return false }
            for t in query.tags where !m.tags.contains(t) { return false }
            for a in query.apps where !m.app.contains(a) { return false }
            return true
        }
        let (ranked, total) = engine.search(plan, now: now.timeIntervalSince1970 * 1000, limit: limit, passes: passes, hasPhrase: { _, _ in false })
        return (ranked.map(\.id), total)
    }
}
