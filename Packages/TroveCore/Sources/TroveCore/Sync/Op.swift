import Foundation

/// One change to one record (PROTOCOL.md §3). Ops are immutable and identified by (device, seq).
public struct Op: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case set, text }

    public struct TextEdit: Codable, Hashable, Sendable {
        public var field: String
        public var value: String
        /// sha256 hex of the text this edit was based on ("" for the first version).
        public var base: String
    }

    public var device: String
    public var seq: Int
    public var hlc: String
    public var record: String
    public var recordKind: String?
    public var type: Kind
    public var fields: [String: JSONValue]?
    public var text: TextEdit?

    enum CodingKeys: String, CodingKey {
        case device = "d", seq = "s", hlc = "h", record = "r", recordKind = "k", type = "t", fields = "f", text = "x"
    }

    public static func set(_ fields: [String: JSONValue], record: String, kind: String? = nil, device: String, seq: Int, hlc: HLC) -> Op {
        Op(device: device, seq: seq, hlc: hlc.description, record: record, recordKind: kind, type: .set, fields: fields, text: nil)
    }

    public static func text(_ field: String, value: String, base: String, record: String, kind: String? = nil, device: String, seq: Int, hlc: HLC) -> Op {
        Op(device: device, seq: seq, hlc: hlc.description, record: record, recordKind: kind, type: .text,
           fields: nil, text: TextEdit(field: field, value: value, base: base))
    }

    public var id: String { "\(device):\(seq)" }
}
