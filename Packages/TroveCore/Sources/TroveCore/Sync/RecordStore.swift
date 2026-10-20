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

    public init() {}

    public var opCount: Int { ops.count }
    public var allOps: [Op] { ops }

    /// Adds ops (duplicates ignored). Applies incrementally when they're all newer than what's
    /// been applied, otherwise rebuilds from scratch in HLC order.
    public mutating func apply(_ incoming: [Op]) {
        let fresh = incoming.filter { opIds.insert($0.id).inserted }
        guard !fresh.isEmpty else { return }
        let sortedFresh = fresh.sorted(by: Self.order)
        ops.append(contentsOf: sortedFresh)
        if let first = sortedFresh.first, first.hlc > lastApplied {
            for op in sortedFresh { applyOne(op) }
        } else {
            ops.sort(by: Self.order)
            records = [:]
            history = [:]
            lastApplied = ""
            for op in ops { applyOne(op) }
        }
    }

    public var visible: [Record] { records.values.filter { !$0.isDeleted } }

    public func record(_ id: String) -> Record? { records[id] }

    static func order(_ a: Op, _ b: Op) -> Bool {
        a.hlc != b.hlc ? a.hlc < b.hlc : (a.device != b.device ? a.device < b.device : a.seq < b.seq)
    }

    private mutating func applyOne(_ op: Op) {
        lastApplied = max(lastApplied, op.hlc)
        var record = records[op.record] ?? Record(id: op.record, kind: op.recordKind ?? "item", createdHLC: op.hlc, updatedHLC: op.hlc)
        if let kind = op.recordKind { record.kind = kind }
        record.updatedHLC = max(record.updatedHLC, op.hlc)
        switch op.type {
        case .set:
            for (key, value) in op.fields ?? [:] { record.fields[key] = value }
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
        records[op.record] = record
    }
}
