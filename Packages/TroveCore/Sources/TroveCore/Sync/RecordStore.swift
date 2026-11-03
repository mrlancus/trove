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
    /// Ink by item, layer and page key (`inkPageKey`), so opening one page of a 500-page notebook
    /// reads that page's strokes, not the notebook's (docs/PERF_AUDIT.md B2).
    private var inkByPage: [String: Set<String>] = [:]
    /// The latest `createdAt` any ink on an item has had (never lowered, so a deleted stroke may keep
    /// it high): new ink goes after it without scanning the item's ink (docs/ROADMAP.md §3.7 item 8).
    private var newestInk: [String: Double] = [:]
    /// The checkpoint this store starts from, if any (PROTOCOL.md §3 "Checkpoints").
    public private(set) var base: Checkpoint.Base?

    // MARK: Change feed (docs/MASTER_PLAN.md P1)
    /// Goes up by one for every record an op touches. Readers keep the value they last saw and ask
    /// `changes(since:)` for what's different, instead of re-reading every record after each change.
    public private(set) var changeVersion = 0
    /// (version, record id), oldest first. Trimmed when long; asking from before `changeFloor` (or
    /// before a rebuild) answers "everything changed".
    private var changeLog: [(version: Int, id: String)] = []
    private var changeFloor = 0
    static let changeLogLimit = 200_000

    /// What changed since a reader last looked.
    public struct ChangeSet: Sendable, Equatable {
        /// Everything may have changed (first look, a rebuild, or the reader fell too far behind).
        public var all: Bool
        /// The ids of records that changed (deleted ones included), by kind. Empty when `all`.
        public var byKind: [String: Set<String>]
        /// Pass this to the next `changes(since:)`.
        public var token: Int

        public var isEmpty: Bool { !all && byKind.isEmpty }
        /// Whether any record of these kinds changed (always true when `all`).
        public func touches(_ kinds: Set<String>) -> Bool { all || kinds.contains { byKind[$0] != nil } }
        public func ids(_ kind: String) -> Set<String> { byKind[kind] ?? [] }
    }

    /// The records changed after `token` (a `changeVersion` the reader saw; -1 for the first look).
    public func changes(since token: Int) -> ChangeSet {
        if token < changeFloor || token > changeVersion { return ChangeSet(all: true, byKind: [:], token: changeVersion) }
        var byKind: [String: Set<String>] = [:]
        // The log is in version order: walk back from the end until reaching the token.
        var i = changeLog.count - 1
        while i >= 0, changeLog[i].version > token {
            let id = changeLog[i].id
            byKind[records[id]?.kind ?? "", default: []].insert(id)
            i -= 1
        }
        return ChangeSet(all: false, byKind: byKind, token: changeVersion)
    }

    private var rebuilding = false

    private mutating func noteChange(_ id: String) {
        if rebuilding { return }
        changeVersion += 1
        changeLog.append((changeVersion, id))
        if changeLog.count > Self.changeLogLimit {
            let drop = changeLog.count / 2
            changeFloor = changeLog[drop - 1].version
            changeLog.removeFirst(drop)
        }
    }

    /// Everything is new to every reader (after a rebuild or a new checkpoint).
    private mutating func noteEverythingChanged() {
        changeVersion += 1
        changeLog = []
        changeFloor = changeVersion
    }

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
        inkByPage = [:]
        newestInk = [:]
        lastApplied = ""
        if base != nil { applyBase() }
        rebuilding = true
        for op in ops { applyOne(op) }
        rebuilding = false
        noteEverythingChanged()
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
            if Self.inkKinds.contains(record.kind), let on = record.fields["on"]?.string {
                inkByItem[on, default: []].insert(b.id)
                inkByPage[Self.inkPageKey(record), default: []].insert(b.id)
                noteInkTime(record, on: on)
            }
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
    public func newestInkTime(on itemId: String) -> Double? { newestInk[itemId] }

    public func ink(on itemId: String) -> [Record] {
        (inkByItem[itemId] ?? []).compactMap { id in records[id].flatMap { $0.isDeleted ? nil : $0 } }
    }

    /// Strokes and elements on one page of an item's layer ("" = the sketch itself), not deleted.
    public func ink(on itemId: String, layer: String, pageKey: String) -> [Record] {
        (inkByPage[Self.inkPageKey(on: itemId, layer: layer, pageKey: pageKey)] ?? []).compactMap { id in
            records[id].flatMap { $0.isDeleted ? nil : $0 }
        }
    }

    static func inkPageKey(on: String, layer: String, pageKey: String) -> String { "\(on)\u{1F}\(layer)\u{1F}\(pageKey)" }
    static func inkPageKey(_ r: Record) -> String {
        inkPageKey(on: r.fields["on"]?.string ?? "", layer: r.fields["layer"]?.string ?? "", pageKey: InkPage.key(r.fields["page"]))
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
        let oldPage = records[op.record].flatMap { Self.inkKinds.contains($0.kind) && $0.fields["on"] != nil ? Self.inkPageKey($0) : nil }
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
        if Self.inkKinds.contains(record.kind), let on = record.fields["on"]?.string {
            inkByItem[on, default: []].insert(op.record)
            let page = Self.inkPageKey(record)
            if page != oldPage {
                if let oldPage { inkByPage[oldPage]?.remove(op.record) }
                inkByPage[page, default: []].insert(op.record)
            }
            noteInkTime(record, on: on)
        } else if let oldPage {
            inkByPage[oldPage]?.remove(op.record)
        }
        records[op.record] = record
        noteChange(op.record)
    }

    private mutating func noteInkTime(_ record: Record, on itemId: String) {
        guard let t = record.fields["createdAt"]?.number, t.isFinite, t > (newestInk[itemId] ?? -.infinity) else { return }
        newestInk[itemId] = t
    }
}
