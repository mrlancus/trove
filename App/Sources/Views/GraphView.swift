import SwiftUI
import TroveCore

/// The Connections screen: the whole graph, with the same look as the website's (web/public/graph.js).
struct GraphScreen: View {
    @Environment(AppModel.self) private var model
    @AppStorage("graph.tags") private var showTags = true
    @AppStorage("graph.unlinked") private var showUnlinked = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Toggle("Tags", isOn: $showTags).toggleStyle(.button)
                Toggle("Unconnected items", isOn: $showUnlinked).toggleStyle(.button)
                Spacer()
                ForEach(model.folders.filter { $0.parent == nil }.sorted { $0.name < $1.name }.prefix(8)) { folder in
                    Label { Text(folder.name) } icon: { Circle().fill(FolderStyle.color(for: folder.id)).frame(width: 8, height: 8) }
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .controlSize(.small)
            GraphCanvas(focus: nil, compact: false, showTags: showTags, showUnlinked: showUnlinked)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.separator))
            Text("Drag to move around, pinch to zoom, tap a point to open it. Colours are your top folders.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .navigationTitle("Connections")
    }
}

/// Items as glowing points sized by how connected they are, coloured by top folder; links as lines,
/// shared tags as small diamonds. `focus` shows only what's within two steps of one item.
struct GraphCanvas: View {
    var focus: String?
    var compact = false
    var showTags = true
    var showUnlinked = false
    @Environment(AppModel.self) private var model
    @State private var sim: GraphSimulation?
    @State private var tick = 0
    @State private var offset: CGSize = .zero
    @State private var dragStart: CGSize?
    @State private var scale: CGFloat = 1
    @State private var pinchStart: CGFloat?

    var body: some View {
        let snapshot = sim?.snapshot() ?? .init(nodes: [], edges: [])
        let tick = tick
        GeometryReader { geo in
            let center = CGPoint(x: geo.size.width / 2 + offset.width, y: geo.size.height / 2 + offset.height)
            Canvas { gc, _ in
                _ = tick
                func point(_ n: GraphSimulation.Node) -> CGPoint { CGPoint(x: center.x + n.x * scale, y: center.y + n.y * scale) }
                for e in snapshot.edges {
                    var path = Path()
                    path.move(to: point(snapshot.nodes[e.a]))
                    path.addLine(to: point(snapshot.nodes[e.b]))
                    gc.stroke(path, with: .color(.secondary.opacity(e.isLink ? 0.5 : 0.22)),
                              style: StrokeStyle(lineWidth: 1, dash: e.isLink ? [] : [3, 4]))
                }
                for n in snapshot.nodes {
                    let p = point(n), r = n.radius * sqrt(scale)
                    if n.isTag {
                        var diamond = Path()
                        diamond.move(to: CGPoint(x: p.x, y: p.y - r)); diamond.addLine(to: CGPoint(x: p.x + r, y: p.y))
                        diamond.addLine(to: CGPoint(x: p.x, y: p.y + r)); diamond.addLine(to: CGPoint(x: p.x - r, y: p.y)); diamond.closeSubpath()
                        gc.fill(diamond, with: .color(.secondary))
                    } else {
                        gc.fill(Path(ellipseIn: CGRect(x: p.x - r * 2.6, y: p.y - r * 2.6, width: r * 5.2, height: r * 5.2)),
                                with: .radialGradient(Gradient(colors: [n.color.opacity(0.4), n.color.opacity(0)]), center: p, startRadius: 0, endRadius: r * 2.6))
                        gc.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)), with: .color(n.color))
                        if n.id == focus { gc.stroke(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)), with: .color(.primary), lineWidth: 2) }
                    }
                    if snapshot.nodes.count <= (compact ? 14 : 40) || scale > 1.7 || n.degree >= 3 || n.id == focus {
                        gc.draw(Text(n.label).font(.caption2.weight(n.isTag ? .regular : .medium)).foregroundStyle(n.isTag ? .secondary : .primary),
                                at: CGPoint(x: p.x, y: p.y + r + 3), anchor: .top)
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(SpatialTapGesture().onEnded { value in
                guard let hit = snapshot.nodes.min(by: { distance($0, value.location, center) < distance($1, value.location, center) }),
                      distance(hit, value.location, center) < max(14, hit.radius * scale + 8), !hit.isTag, hit.id != focus else { return }
                model.selectedItemID = hit.id
            })
            .simultaneousGesture(DragGesture(minimumDistance: 4)
                .onChanged { v in
                    let start = dragStart ?? offset
                    dragStart = start
                    offset = CGSize(width: start.width + v.translation.width, height: start.height + v.translation.height)
                }
                .onEnded { _ in dragStart = nil })
            .simultaneousGesture(MagnifyGesture()
                .onChanged { v in
                    let start = pinchStart ?? scale
                    pinchStart = start
                    scale = min(4, max(0.25, start * v.magnification))
                }
                .onEnded { _ in pinchStart = nil })
            .overlay {
                if let sim, sim.nodes.isEmpty, !compact {
                    EmptyState(symbol: "point.3.connected.trianglepath.dotted", title: "No connections yet",
                               message: "Link notes by typing [[ and a title, or use Connect to… on any item. Shared #tags show up here too.")
                }
            }
        }
        .background(RadialGradient(colors: [Color.orange.opacity(0.08), .clear], center: .center, startRadius: 0, endRadius: 500))
        .task(id: signature) {
            let s = GraphSimulation(items: model.items, links: model.links, folders: model.folders, focus: focus, tags: showTags, unlinked: showUnlinked)
            sim = s
            scale = compact ? 1.1 : 1
            while s.alpha > 0.004, !Task.isCancelled {
                s.step()
                self.tick &+= 1
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    private var signature: String {
        "\(focus ?? "")|\(showTags)|\(showUnlinked)|\(model.items.count)|\(model.links.outgoing.count)|\(model.links.incoming.values.reduce(0) { $0 + $1.count })|\(model.folders.count)"
    }

    private func distance(_ n: GraphSimulation.Node, _ p: CGPoint, _ center: CGPoint) -> CGFloat {
        hypot(center.x + n.x * scale - p.x, center.y + n.y * scale - p.y)
    }
}

/// A small force layout: nodes push apart, links pull together, everything drifts to the middle.
@MainActor
final class GraphSimulation {
    struct Node {
        var id: String
        var label: String
        var color: Color
        var isTag: Bool
        var degree = 0
        var x: CGFloat = 0, y: CGFloat = 0, vx: CGFloat = 0, vy: CGFloat = 0
        var radius: CGFloat { isTag ? 3.5 : 4 + min(10, sqrt(CGFloat(degree)) * 2.4) }
    }
    struct Edge { var a: Int; var b: Int; var isLink: Bool }
    struct Snapshot { var nodes: [Node]; var edges: [Edge] }

    private(set) var nodes: [Node] = []
    private(set) var edges: [Edge] = []
    private(set) var alpha: CGFloat = 1

    init(items: [Item], links: Links.Graph, folders: [Folder], focus: String?, tags: Bool, unlinked: Bool) {
        var index: [String: Int] = [:]
        let byId = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        func add(_ item: Item) -> Int {
            if let i = index[item.id] { return i }
            let top = item.folder.map { Folder.path(of: $0, in: folders).first?.id } ?? nil
            nodes.append(Node(id: item.id, label: String(item.displayTitle.prefix(34)), color: FolderStyle.color(for: top), isTag: false))
            index[item.id] = nodes.count - 1
            return nodes.count - 1
        }
        var raw: [Edge] = []
        for (from, tos) in links.outgoing {
            guard let a = byId[from] else { continue }
            for to in tos { if let b = byId[to] { raw.append(Edge(a: add(a), b: add(b), isLink: true)) } }
        }
        if tags {
            var byTag: [String: [Item]] = [:]
            for item in items { for t in item.tags { byTag[t, default: []].append(item) } }
            for (tag, members) in byTag.sorted(by: { $0.key < $1.key }) where members.count >= 2 {
                nodes.append(Node(id: "#" + tag, label: "#" + tag, color: .secondary, isTag: true))
                let t = nodes.count - 1
                for m in members { raw.append(Edge(a: add(m), b: t, isLink: false)) }
            }
        }
        if unlinked { for item in items { _ = add(item) } }
        if let focus {
            if let item = byId[focus] { _ = add(item) }
            var keep: Set<String> = [focus]
            var frontier: Set<String> = [focus]
            for _ in 0..<2 {
                var next: Set<String> = []
                for e in raw {
                    let a = nodes[e.a].id, b = nodes[e.b].id
                    if frontier.contains(a), !keep.contains(b) { next.insert(b) }
                    if frontier.contains(b), !keep.contains(a) { next.insert(a) }
                }
                keep.formUnion(next)
                frontier = next
            }
            let kept = nodes.indices.filter { keep.contains(nodes[$0].id) }
            let remap = Dictionary(uniqueKeysWithValues: kept.enumerated().map { ($1, $0) })
            nodes = kept.map { nodes[$0] }
            raw = raw.compactMap { e in remap[e.a].flatMap { a in remap[e.b].map { Edge(a: a, b: $0, isLink: e.isLink) } } }
        }
        edges = raw
        for e in edges { nodes[e.a].degree += 1; nodes[e.b].degree += 1 }
        for i in nodes.indices {
            let angle = CGFloat(i) * 2.399963, r = 30 * sqrt(CGFloat(i + 1))
            nodes[i].x = cos(angle) * r
            nodes[i].y = sin(angle) * r
        }
    }

    func snapshot() -> Snapshot { Snapshot(nodes: nodes, edges: edges) }

    func step() {
        let n = nodes.count
        for i in 0..<n {
            for j in (i + 1)..<max(i + 1, n) {
                var dx = nodes[i].x - nodes[j].x, dy = nodes[i].y - nodes[j].y
                var d2 = dx * dx + dy * dy
                if d2 > 90_000 { continue }
                if d2 < 1 { dx = .random(in: -0.5...0.5); dy = .random(in: -0.5...0.5); d2 = 1 }
                let f = 900 * alpha / d2
                nodes[i].vx += dx * f; nodes[i].vy += dy * f
                nodes[j].vx -= dx * f; nodes[j].vy -= dy * f
            }
        }
        for e in edges {
            let dx = nodes[e.b].x - nodes[e.a].x, dy = nodes[e.b].y - nodes[e.a].y
            let d = max(hypot(dx, dy), 1)
            let f = (d - (e.isLink ? 70 : 45)) / d * (e.isLink ? 0.06 : 0.035) * alpha
            nodes[e.a].vx += dx * f; nodes[e.a].vy += dy * f
            nodes[e.b].vx -= dx * f; nodes[e.b].vy -= dy * f
        }
        for i in nodes.indices {
            nodes[i].vx -= nodes[i].x * 0.004 * alpha
            nodes[i].vy -= nodes[i].y * 0.004 * alpha
            nodes[i].vx *= 0.6; nodes[i].vy *= 0.6
            nodes[i].x += nodes[i].vx; nodes[i].y += nodes[i].vy
        }
        alpha = max(0, alpha * 0.985 - 0.0005)
    }
}
