import Foundation

/// This device's outgoing op log. Ops are numbered contiguously and cut into segments.
/// `State` is persisted locally on the device (not in iCloud) so numbering survives restarts.
public struct Journal: Sendable {
    public struct State: Codable, Sendable, Equatable {
        public var device: String
        public var nextSeq: Int = 1
        /// First sequence number not yet written to any transport.
        public var unflushedFrom: Int = 1
        public var lastHLC: String?

        public init(device: String) { self.device = device }
    }

    public private(set) var state: State
    public private(set) var pending: [Op] = []
    public private(set) var clock: HLCClock

    public init(state: State, pending: [Op] = [], now: (@Sendable () -> Int64)? = nil) {
        self.state = state
        self.pending = pending
        let last = state.lastHLC.flatMap(HLC.init)
        if let now { clock = HLCClock(device: state.device, last: last, now: now) }
        else { clock = HLCClock(device: state.device, last: last) }
    }

    public var device: String { state.device }

    public mutating func observe(_ hlc: String) {
        if let h = HLC(hlc) { clock.observe(h) }
    }

    /// Records a field change.
    public mutating func set(_ fields: [String: JSONValue], record: String, kind: String? = nil) -> Op {
        let device = self.device
        return append { seq, hlc in Op.set(fields, record: record, kind: kind, device: device, seq: seq, hlc: hlc) }
    }

    /// Records a text edit. `previous` is the text the user started editing from.
    public mutating func text(_ field: String, value: String, previous: String, record: String, kind: String? = nil) -> Op {
        let device = self.device
        return append { seq, hlc in
            Op.text(field, value: value, base: previous.sha256Hex, record: record, kind: kind, device: device, seq: seq, hlc: hlc)
        }
    }

    private mutating func append(_ make: (Int, HLC) -> Op) -> Op {
        let op = make(state.nextSeq, clock.tick())
        state.nextSeq += 1
        state.lastHLC = op.hlc
        pending.append(op)
        return op
    }

    /// Cuts pending ops into segments (each ≤ 512 KiB) and clears them.
    public mutating func takeSegments() throws -> [Segment] {
        guard !pending.isEmpty else { return [] }
        var segments: [Segment] = []
        var batch: [Op] = []
        var size = 0
        let encoder = JSONEncoder()
        for op in pending {
            let opSize = (try encoder.encode(op)).count + 1
            if !batch.isEmpty, size + opSize > Segment.maxPlaintextBytes {
                segments.append(try Segment(device: device, ops: batch))
                batch = []
                size = 0
            }
            batch.append(op)
            size += opSize
        }
        segments.append(try Segment(device: device, ops: batch))
        pending = []
        state.unflushedFrom = state.nextSeq
        return segments
    }
}
