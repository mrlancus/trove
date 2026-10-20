import Foundation

/// Connections between items: `[[wikilinks]]` in text plus links made by hand (`Field.links`).
/// The website's port is web/public/core/links.js; both run `Fixtures/links-cases.json`.
public enum Links {
    /// The targets of `[[Target]]`, `[[Target|label]]` and `[[Target#heading]]`, in order, without
    /// repeats. Code blocks and inline code are skipped.
    public static func wikilinks(in text: String) -> [String] {
        var out: [String] = []
        var fence = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { fence.toggle(); continue }
            if fence { continue }
            let plain = line.replacingOccurrences(of: "`[^`]*`", with: "", options: .regularExpression)
            var rest = plain[...]
            while let open = rest.range(of: "[[") {
                guard let close = rest[open.upperBound...].range(of: "]]") else { break }
                var target = String(rest[open.upperBound..<close.lowerBound])
                if let bar = target.firstIndex(of: "|") { target = String(target[..<bar]) }
                if let hash = target.firstIndex(of: "#") { target = String(target[..<hash]) }
                target = target.trimmingCharacters(in: .whitespaces)
                if !target.isEmpty, !target.contains("["), !out.contains(where: { $0.caseInsensitiveCompare(target) == .orderedSame }) {
                    out.append(target)
                }
                rest = rest[close.upperBound...]
            }
        }
        return out
    }

    public struct Graph: Sendable, Equatable {
        /// item id → ids it points to (wikilinks and hand-made links), sorted.
        public var outgoing: [String: [String]] = [:]
        /// item id → ids that point to it, sorted.
        public var incoming: [String: [String]] = [:]
        /// item id → `[[targets]]` that match no item yet.
        public var unresolved: [String: [String]] = [:]

        public func neighbours(of id: String) -> [String] {
            Array(Set((outgoing[id] ?? []) + (incoming[id] ?? []))).sorted()
        }
    }

    /// Maps lowercased titles to item ids. When two items share a title the newest wins (then the
    /// smallest id), so every device resolves `[[Title]]` the same way.
    public static func titleIndex(_ items: [Item]) -> [String: String] {
        var index: [String: (String, Date)] = [:]
        for item in items {
            let key = item.displayTitle.trimmingCharacters(in: .whitespaces).lowercased()
            guard !key.isEmpty else { continue }
            if let (id, date) = index[key], date > item.createdAt || (date == item.createdAt && id < item.id) { continue }
            index[key] = (item.id, item.createdAt)
        }
        return index.mapValues(\.0)
    }

    public static func graph(_ items: [Item]) -> Graph {
        let titles = titleIndex(items)
        let ids = Set(items.map(\.id))
        var out: [String: Set<String>] = [:]
        var unresolved: [String: [String]] = [:]
        for item in items {
            for target in wikilinks(in: item.body) {
                if let id = titles[target.lowercased()] {
                    if id != item.id { out[item.id, default: []].insert(id) }
                } else {
                    unresolved[item.id, default: []].append(target)
                }
            }
            for id in item.links where id != item.id && ids.contains(id) { out[item.id, default: []].insert(id) }
        }
        var graph = Graph()
        var incoming: [String: Set<String>] = [:]
        for (from, tos) in out {
            graph.outgoing[from] = tos.sorted()
            for to in tos { incoming[to, default: []].insert(from) }
        }
        graph.incoming = incoming.mapValues { $0.sorted() }
        graph.unresolved = unresolved
        return graph
    }

    /// Items that mention this one's title in plain text without linking it ("unlinked mentions").
    public static func mentions(of item: Item, in items: [Item], linked: Set<String> = []) -> [Item] {
        let title = item.displayTitle.trimmingCharacters(in: .whitespaces)
        guard title.count >= 4, title != "Untitled" else { return [] }
        return items.filter { other in
            other.id != item.id && !linked.contains(other.id)
                && (other.body.range(of: title, options: [.caseInsensitive, .diacriticInsensitive]) != nil)
        }
    }

    /// Items that look related: shared tags count most, then the same folder and the same site.
    public static func related(to item: Item, in items: [Item], limit: Int = 6) -> [Item] {
        let tags = Set(item.tags)
        let host = item.url?.host
        let scored: [(Item, Int)] = items.compactMap { other in
            guard other.id != item.id else { return nil }
            var score = 2 * tags.intersection(other.tags).count
            if let f = item.folder, f == other.folder, !tags.isEmpty || item.kind == other.kind { score += 1 }
            if let host, host == other.url?.host { score += 1 }
            return score >= 2 ? (other, score) : nil
        }
        return scored.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.createdAt > $1.0.createdAt }.prefix(limit).map(\.0)
    }
}

extension Library {
    /// Connects two items by hand (both directions show up as links).
    public func connect(_ a: String, _ b: String) async {
        guard a != b, let item = await item(a), !item.links.contains(b) else { return }
        await update(a, [Field.links: JSONValue(item.links + [b])])
    }

    public func disconnect(_ a: String, _ b: String) async {
        if let item = await item(a), item.links.contains(b) { await update(a, [Field.links: JSONValue(item.links.filter { $0 != b })]) }
        if let item = await item(b), item.links.contains(a) { await update(b, [Field.links: JSONValue(item.links.filter { $0 != a })]) }
    }
}
