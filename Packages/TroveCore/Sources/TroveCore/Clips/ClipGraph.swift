import Foundation

/// The clipboard as a graph, like core/clipmap.js `clipFacts` and `buildClipGraph`: clips joined to
/// the apps and sites they were copied from, the apps they were pasted into, the places and days, and
/// their tags. Clips connected to each other or to library items (`links`) are joined too.
public struct ClipGraph: Sendable {
    public enum Group: String, CaseIterable, Sendable {
        case from, to, place, day, tag
        public var title: String {
            switch self {
            case .from: "Copied from"
            case .to: "Pasted into"
            case .place: "Places"
            case .day: "Days"
            case .tag: "Tags"
            }
        }
    }

    public struct Node: Sendable, Hashable {
        public enum Role: Sendable, Hashable { case clip(ClipKind), item, group(Group) }
        public var id: String
        public var label: String
        public var role: Role
        public var degree = 0
    }

    public struct Edge: Sendable, Hashable {
        public enum Kind: String, Sendable { case flow, group, link }
        public var a: String, b: String, kind: Kind
    }

    /// What a clip is known for: where it was copied from and pasted into, places and days.
    public struct Facts: Sendable {
        public var from: [(key: String, label: String)] = []
        public var to: [(key: String, label: String)] = []
        public var places: [(key: String, label: String)] = []
        public var days: [String] = []
        public var last: Date

        mutating func add(_ pair: (key: String, label: String), to list: WritableKeyPath<Facts, [(key: String, label: String)]>) {
            if !self[keyPath: list].contains(where: { $0.key == pair.key }) { self[keyPath: list].append(pair) }
        }
    }

    public var nodes: [Node]
    public var edges: [Edge]

    /// The local day of a time, as YYYY-MM-DD.
    public static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    public static func facts(_ clips: [Clip], events: [ClipEvent]) -> [String: Facts] {
        var out: [String: Facts] = [:]
        for c in clips {
            var f = Facts(days: [dayKey(c.createdAt)], last: c.sortDate)
            if let own = ClipEvent.appKey(app: c.sourceApp, url: c.sourceURL?.absoluteString) { f.add(own, to: \.from) }
            out[c.id] = f
        }
        for e in events {
            guard let id = e.clip, var f = out[id] else { continue }
            if let w = e.whereKey { if e.type == .copy { f.add(w, to: \.from) } else if e.type == .paste { f.add(w, to: \.to) } }
            if let p = e.place?.key { f.add(p, to: \.places) }
            if e.at.timeIntervalSince1970 > 0 {
                let d = dayKey(e.at)
                if !f.days.contains(d) { f.days.append(d) }
                f.last = max(f.last, e.at)
            }
            out[id] = f
        }
        return out
    }

    /// Groups with one clip are left out unless `singles`. With nothing joined, the newest 200 clips
    /// show on their own.
    public static func build(_ clips: [Clip], facts: [String: Facts], groups: Set<Group> = [.from, .to, .place],
                             items: [Item] = [], singles: Bool = false) -> ClipGraph {
        var nodes: [Node] = [], index: [String: Int] = [:], edges: [Edge] = []
        func label(_ s: String) -> String { s.count > 40 ? String(s.prefix(39)) + "…" : s }
        func addClip(_ c: Clip) {
            guard index[c.id] == nil else { return }
            index[c.id] = nodes.count
            nodes.append(Node(id: c.id, label: label(c.displayTitle), role: .clip(c.kind)))
        }
        var order: [String] = []
        var members: [String: (group: Group, label: String, clips: [Clip])] = [:]
        func join(_ group: Group, _ key: String, _ text: String, _ c: Clip) {
            let id = "\(group.rawValue)|\(key)"
            if members[id] == nil { members[id] = (group, text, []); order.append(id) }
            members[id]!.clips.append(c)
        }
        for c in clips {
            guard let f = facts[c.id] else { continue }
            if groups.contains(.from) { for p in f.from { join(.from, p.key, p.label, c) } }
            if groups.contains(.to) { for p in f.to { join(.to, p.key, p.label, c) } }
            if groups.contains(.place) { for p in f.places { join(.place, p.key, p.label, c) } }
            if groups.contains(.day) { for d in f.days { join(.day, d, d, c) } }
            if groups.contains(.tag) { for t in c.tags { join(.tag, t, "#" + t, c) } }
        }
        for id in order {
            let m = members[id]!
            guard m.clips.count >= 2 || singles else { continue }
            index[id] = nodes.count
            nodes.append(Node(id: id, label: m.group == .to ? "→ " + m.label : m.label, role: .group(m.group)))
            for c in m.clips {
                addClip(c)
                edges.append(Edge(a: c.id, b: id, kind: m.group == .from || m.group == .to ? .flow : .group))
            }
        }
        let byId = Dictionary(clips.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let itemsById = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for c in clips {
            for other in c.links {
                if let o = byId[other] {
                    addClip(c); addClip(o)
                    edges.append(Edge(a: c.id, b: other, kind: .link))
                } else if let item = itemsById[other] {
                    addClip(c)
                    if index[item.id] == nil { index[item.id] = nodes.count; nodes.append(Node(id: item.id, label: label(item.displayTitle), role: .item)) }
                    edges.append(Edge(a: c.id, b: item.id, kind: .link))
                }
            }
        }
        if edges.isEmpty { for c in clips.prefix(200) { addClip(c) } }
        for e in edges {
            if let a = index[e.a] { nodes[a].degree += 1 }
            if let b = index[e.b] { nodes[b].degree += 1 }
        }
        return ClipGraph(nodes: nodes, edges: edges)
    }
}
