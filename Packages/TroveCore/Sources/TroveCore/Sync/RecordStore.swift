import Foundation

/// A materialised record: plain fields (last writer wins per field) plus merged text fields.
public struct Record: Sendable, Hashable, Identifiable {
    public let id: String
    public var kind: String
    public var fields: [String: JSONValue] = [:]
    public var texts: [String: String] = [:]
    /// Versions of a text field that couldn't be merged automatically, newest last.
    public var conflicts: [String: [String]] = [:]
    public var createdHLC: String
    public var updatedHLC: String

    public var isDeleted: Bool { fields["_deleted"]?.bool == true }
    /// An "item" made only by edits to an id that never was one (no kind, no date): shown as an
    /// empty "Untitled" from 1970 before, now left out everywhere (PROTOCOL.md §3).
    public var isStrayItem: Bool { kind == "item" && fields["kind"] == nil && fields["createdAt"] == nil }
    public subscript(field: String) -> JSONValue? { fields[field] }
}

/// Turns a set of ops into records. Deterministic: any device holding the same ops, received in
/// any order, computes identical records (PROTOCOL.md §3).
public struct RecordStore: Sendable {
    public private(set) var records: [String: Record] = [:]
    private var ops: [Op] = []
    private var opIds: Set<String> = []
    private var lastApplied: String = ""
    /// text history per record/field: sha256 → text, so later edits can find their base.
    private var history: [String: [String: String]] = [:]
    /// Record ids by kind (deleted ones too), so a screen reading one kind doesn't walk the whole vault.
    private var byKind: [String: Set<String>] = [:]
    /// Newest change per kind, for `stamp(of:)`.
    private var newestByKind: [String: String] = [:]
    /// Ink (strokes and elements) by the item it's on.
    private var inkByItem: [String: Set<String>] = [:]
    /// The checkpoint this store starts from, if any (PROTOCOL.md §3 "Checkpoints").
    public private(set) var base: Checkpoint.Base?

    public init() {}

    public var opCount: Int { ops.count }
    public var allOps: [Op] { ops }
    /// The newest HLC applied (the checkpoint's frontier at least).
    public var frontier: String { lastApplied }

    /// Adds ops (duplicates and ops the checkpoint holds are ignored). Applies incrementally when
    /// they're all newer than what's been applied, otherwise rebuilds in HLC order. Returns the ops
    /// that were new.
    @discardableResult
    public mutating func apply(_ incoming: [Op]) -> [Op] {
        var fresh: [Op] = []
        for op in incoming where !isCovered(op) && opIds.insert(op.id).inserted { fresh.append(op) }
        guard !fresh.isEmpty else { return [] }
        let sortedFresh = fresh.sorted(by: Self.order)
        ops.append(contentsOf: sortedFresh)
        if let first = sortedFresh.first, first.hlc > lastApplied {
            for op in sortedFresh { applyOne(op) }
        } else {
            rebuild()
        }
        return sortedFresh
    }

    /// Materialises again: the checkpoint's records (if any), then every op in order.
    private mutating func rebuild() {
        ops.sort(by: Self.order)
        records = [:]
        history = [:]
        byKind = [:]
        newestByKind = [:]
        inkByItem = [:]
        lastApplied = ""
        if base != nil { applyBase() }
        for op in ops { applyOne(op) }
    }

    // MARK: Checkpoints

    /// The checkpoint this store starts from already holds this op.
    public func isCovered(_ op: Op) -> Bool {
        guard let base else { return false }
        return Checkpoint.covers(base.covers, device: op.device, first: op.seq, last: op.seq)
    }

    /// Starts from a checkpoint: its records stand in for every op it covers, its text ops are kept
    /// (text merges replay them), and ops it doesn't cover stay. Returns false (and changes nothing)
    /// for one that doesn't cover the checkpoint already in use.
    @discardableResult
    public mutating func useBase(_ newBase: Checkpoint.Base) -> Bool {
        if let base, !Checkpoint.coversAll(newBase.covers, base.covers) { return false }
        let kept = ops.filter { !Checkpoint.covers(newBase.covers, device: $0.device, first: $0.seq, last: $0.seq) }
        base = newBase
        ops = newBase.texts + kept
        opIds = Set(ops.map(\.id))
        rebuild()
        return true
    }

    /// Ops the checkpoint doesn't hold: what a local copy keeps besides it.
    public var opsAfterBase: [Op] { base == nil ? ops : ops.filter { !isCovered($0) } }

    private mutating func applyBase() {
        guard let base else { return }
        for b in base.records {
            let record = Record(id: b.id, kind: b.kind, fields: b.fields, createdHLC: b.created, updatedHLC: b.updated)
            byKind[record.kind, default: []].insert(b.id)
            if (newestByKind[record.kind] ?? "") < b.updated { newestByKind[record.kind] = b.updated }
            if Self.inkKinds.contains(record.kind), let on = record.fields["on"]?.string { inkByItem[on, default: []].insert(b.id) }
            records[b.id] = record
        }
        lastApplied = max(lastApplied, base.frontier)
    }

    public var visible: [Record] { records.values.filter { !$0.isDeleted } }

    /// The records of one kind that aren't deleted.
    public func visible(kind: String) -> [Record] {
        (byKind[kind] ?? []).compactMap { id in records[id].flatMap { $0.isDeleted ? nil : $0 } }
    }

    /// Every record of one kind, deleted ones included.
    public func all(kind: String) -> [Record] { (byKind[kind] ?? []).compactMap { records[$0] } }

    /// Strokes and elements on an item that aren't deleted.
    public func ink(on itemId: String) -> [Record] {
        (inkByItem[itemId] ?? []).compactMap { id in records[id].flatMap { $0.isDeleted ? nil : $0 } }
    }

    /// Every record of these kinds, deleted ones included: their count and newest change.
    public func stamp(of kinds: Set<String>) -> (count: Int, newest: String) {
        var count = 0, newest = ""
        for k in kinds {
            count += byKind[k]?.count ?? 0
            if let n = newestByKind[k], n > newest { newest = n }
        }
        return (count, newest)
    }

    static let inkKinds: Set<String> = ["stroke", "element"]

    public func record(_ id: String) -> Record? { records[id] }

    static func order(_ a: Op, _ b: Op) -> Bool {
        a.hlc != b.hlc ? a.hlc < b.hlc : (a.device != b.device ? a.device < b.device : a.seq < b.seq)
    }

    private mutating func applyOne(_ op: Op) {
        lastApplied = max(lastApplied, op.hlc)
        var record = records[op.record] ?? Record(id: op.record, kind: op.recordKind ?? "item", createdHLC: op.hlc, updatedHLC: op.hlc)
        let oldKind = records[op.record]?.kind
        // An op older than what the checkpoint holds for a field (from a device that was offline) loses to it.
        let stamps = base?.stamps[op.record]
        if let kind = op.recordKind {
            let kindStamp = stamps?.kind ?? ""
            if kindStamp.isEmpty || op.hlc >= kindStamp { record.kind = kind }
        }
        if oldKind != record.kind {
            if let oldKind { byKind[oldKind]?.remove(op.record) }
            byKind[record.kind, default: []].insert(op.record)
        }
        if (newestByKind[record.kind] ?? "") < op.hlc { newestByKind[record.kind] = op.hlc }
        record.updatedHLC = max(record.updatedHLC, op.hlc)
        record.createdHLC = min(record.createdHLC, op.hlc)
        switch op.type {
        case .set:
            for (key, value) in op.fields ?? [:] {
                if let stamp = stamps?.fields[key], op.hlc < stamp { continue }
                record.fields[key] = value
            }
        case .text:
            guard let edit = op.text else { break }
            let key = "\(op.record)\u{1F}\(edit.field)"
            var versions = history[key] ?? [:]
            let current = record.texts[edit.field] ?? ""
            versions[current.sha256Hex] = current
            versions[edit.value.sha256Hex] = edit.value
            if edit.base == current.sha256Hex {
                record.texts[edit.field] = edit.value
            } else if let merged = TextMerge.merge(base: versions[edit.base] ?? "", ours: current, theirs: edit.value) {
                record.texts[edit.field] = merged
                versions[merged.sha256Hex] = merged
            } else {
                record.conflicts[edit.field, default: []].append(edit.value)
            }
            history[key] = versions
        }
        if Self.inkKinds.contains(record.kind), let on = record.fields["on"]?.string { inkByItem[on, default: []].insert(op.record) }
        records[op.record] = record
    }
}
