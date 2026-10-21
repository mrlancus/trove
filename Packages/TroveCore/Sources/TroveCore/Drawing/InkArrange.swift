import Foundation

/// The lasso's editing actions on the vault (PROTOCOL.md §10): bring to front and send to back,
/// groups, connectors that follow what they join, a shape's handles, and the elements library.
/// The same as web/public/core/vault.js (`reorderInk`, `setInkGroup`, `rerouteConnectors`, …).
extension Library {
    // MARK: Arranging

    /// Brings strokes and elements in front of everything else on the item (keeping their order),
    /// or sends them behind it: first − n … first − 1, first being the earliest on the item.
    public func reorderInk(_ ids: [String], front: Bool) async {
        var picked: [Record] = []
        for id in ids {
            if let r = await engine.record(id), r.kind == "stroke" || r.kind == "element", !r.isDeleted { picked.append(r) }
        }
        guard let on = picked.first?[InkStroke.Field.on]?.string else { return }
        let ordered = Self.drawOrder(picked, createdAt: { $0[InkStroke.Field.createdAt]?.number ?? 0 })
        var t: Double
        if front {
            t = await nextInkTime(on: on)
        } else {
            let times: [Double] = await engine.ink(on: on).compactMap { $0[InkStroke.Field.createdAt]?.number }
            t = (times.min() ?? 0) - Double(ordered.count)
        }
        for r in ordered {
            await engine.set([InkStroke.Field.createdAt: .number(t)], record: r.id, kind: r.kind)
            t += 1
        }
    }

    /// Puts strokes and elements in one new group (picked and moved together), or takes them out of
    /// theirs (`group` ""). Returns the group id.
    @discardableResult
    public func setInkGroup(_ ids: [String], group: String? = nil) async -> String {
        let g = group ?? newId()
        for id in ids {
            guard let r = await engine.record(id), r.kind == "stroke" || r.kind == "element", !r.isDeleted else { continue }
            await engine.set([InkStroke.Field.group: .string(g)], record: id, kind: r.kind)
        }
        return g
    }

    // MARK: Connectors

    /// Connectors on a page joined to any of `ids` (and not among them).
    public func connectors(on itemId: String, layer: String = "", pageKey: String, joinedTo ids: [String]) async -> [String] {
        let set = Set(ids)
        return await strokes(on: itemId, layer: layer, pageKey: pageKey)
            .filter { !set.contains($0.id) && (set.contains($0.from) || set.contains($0.to)) }
            .map(\.id)
    }

    /// The box a connector end follows: a stroke's line grown by half its width, or an element's
    /// box as drawn; nil when it's gone.
    public func inkBox(_ id: String) async -> InkGeometry.Rect? {
        guard let r = await engine.record(id), !r.isDeleted else { return nil }
        if r.kind == "element" { return InkEditing.bounds(InkElement(r).editFrame) }
        guard r.kind == "stroke" else { return nil }
        let s = InkStroke(r)
        return InkGeometry.bounds(s.points, pad: s.width / 2)
    }

    /// Moves connectors' joined ends onto what they join, wherever that is now.
    public func rerouteConnectors(_ ids: [String]) async {
        let compact = await inkSettings().compactPoints
        for id in ids {
            guard let r = await engine.record(id), r.kind == "stroke", !r.isDeleted else { continue }
            let s = InkStroke(r)
            let pts = s.points
            guard pts.count >= 2, let a = pts.first, let b = pts.last else { continue }
            let fromBox: InkGeometry.Rect? = s.from.isEmpty ? nil : await inkBox(s.from)
            let toBox: InkGeometry.Rect? = s.to.isEmpty ? nil : await inkBox(s.to)
            let (pa, pb) = InkEditing.connectorEnds(a, b, from: fromBox, to: toBox)
            if pa.x == a.x && pa.y == a.y && pb.x == b.x && pb.y == b.y { continue }
            var start = a, end = b
            start.x = pa.x; start.y = pa.y
            end.x = pb.x; end.y = pb.y
            await engine.set(InkPoints.fields([start, end], compact: compact, had: r), record: id, kind: "stroke")
        }
    }

    /// A clean shape's new outline after one of its handles was dragged (a bent line is a `curve`,
    /// a moved rectangle corner a `polygon`).
    public func setStrokeShape(_ id: String, shape: String?, points: [InkPoint]) async {
        guard !points.isEmpty, let r = await engine.record(id), r.kind == "stroke", !r.isDeleted else { return }
        let compact = await inkSettings().compactPoints
        var fields = InkPoints.fields(points, compact: compact, had: r)
        fields[InkStroke.Field.shape] = shape.map(JSONValue.string) ?? .null
        await engine.set(fields, record: id, kind: "stroke")
    }

    // MARK: The elements library

    /// Saved elements, newest first, then the ones Trove comes with.
    public func stickers() async -> [InkSticker] {
        let mine = await engine.records(kind: InkSticker.kind).map { InkStickers.view(id: $0.id, fields: $0.fields) }
        let sorted = mine.sorted { (a: InkSticker, b: InkSticker) -> Bool in
            if a.createdAt != b.createdAt { return a.createdAt > b.createdAt }
            return a.id < b.id
        }
        return sorted + InkStickers.builtIns
    }

    /// Saves strokes and elements (from a lasso selection) as a reusable element. Returns its id.
    @discardableResult
    public func addSticker(name: String, folder: String = "", strokes: [InkStroke], elements: [InkElement]) async -> String {
        let id = newId()
        let compact = await inkSettings().compactPoints
        var fields = InkStickers.fields(name: name, folder: folder, strokes: strokes.map(InkStickerStroke.init),
                                        elements: elements.map(InkStickerElement.init), compact: compact)
        fields["createdAt"] = .number((now().timeIntervalSince1970 * 1000).rounded())
        fields["device"] = .string(await engine.device)
        await engine.set(fields, record: id, kind: InkSticker.kind)
        return id
    }

    public func updateSticker(_ id: String, name: String? = nil, folder: String? = nil) async {
        var fields: [String: JSONValue] = [:]
        if let name { fields["name"] = .string(String(name.prefix(80))) }
        if let folder { fields["folder"] = .string(String(folder.prefix(80))) }
        if !fields.isEmpty { await engine.set(fields, record: id, kind: InkSticker.kind) }
    }

    public func deleteSticker(_ id: String) async {
        await engine.set(["_deleted": .bool(true)], record: id, kind: InkSticker.kind)
    }

    /// Puts a copy of a library element on a page, centred on `at`, as one new group. Returns the new ids.
    @discardableResult
    public func placeSticker(_ sticker: InkSticker, on itemId: String, layer: String = "", pageKey: String, at: InkPoint, scale: Double = 1) async -> [String] {
        let group = newId()
        let placed = InkStickers.place(sticker, at: at, scale: scale)
        var out: [String] = []
        for s in placed.strokes {
            if let id = await addStroke(on: itemId, layer: layer, pageKey: pageKey, tool: s.inkTool, color: s.color, width: s.width, points: s.points,
                                        shape: s.shape, style: s.style, group: group) { out.append(id) }
        }
        for e in placed.elements {
            let kind = InkElement.Kind(rawValue: e.kind) ?? .text
            let image = e.image.flatMap(Attachment.init(json:))
            let id = await addElement(on: itemId, layer: layer, pageKey: pageKey, kind: kind, frame: InkGeometry.Rect(x: e.x, y: e.y, width: e.w, height: e.h),
                                      text: e.text, size: e.size, color: e.color, image: image, rotate: e.rotate, flip: e.flip,
                                      textStyle: e.textStyle, group: group)
            out.append(id)
        }
        return out
    }
}
