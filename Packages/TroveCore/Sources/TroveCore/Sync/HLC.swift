import Foundation

/// Hybrid logical clock: `"<millis 13 digits>-<counter 4 digits>-<deviceId>"`, sortable as a string
/// (PROTOCOL.md §3). Each device's clock never goes backwards and stays ahead of every clock it has seen.
public struct HLC: Comparable, Hashable, Sendable, CustomStringConvertible {
    public let millis: Int64
    public let counter: Int
    public let device: String

    public init(millis: Int64, counter: Int, device: String) {
        self.millis = millis
        self.counter = counter
        self.device = device
    }

    public init?(_ text: String) {
        let parts = text.split(separator: "-", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, let m = Int64(parts[0]), let c = Int(parts[1]) else { return nil }
        self.init(millis: m, counter: c, device: String(parts[2]))
    }

    public var description: String {
        let m = String(millis)
        let c = String(counter)
        return String(repeating: "0", count: max(0, 13 - m.count)) + m + "-" +
            String(repeating: "0", count: max(0, 4 - c.count)) + c + "-" + device
    }

    public static func < (a: HLC, b: HLC) -> Bool { a.description < b.description }
}

/// Issues strictly increasing HLCs for one device.
public struct HLCClock: Sendable {
    public let device: String
    public private(set) var last: HLC
    private let now: @Sendable () -> Int64

    public init(device: String, last: HLC? = nil, now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        self.device = device
        self.last = last ?? HLC(millis: 0, counter: 0, device: device)
        self.now = now
    }

    public mutating func tick() -> HLC {
        let wall = now()
        if wall > last.millis {
            last = HLC(millis: wall, counter: 0, device: device)
        } else {
            last = HLC(millis: last.millis, counter: last.counter + 1, device: device)
        }
        return last
    }

    /// Call with every remote HLC so local edits always sort after what this device has seen.
    public mutating func observe(_ remote: HLC) {
        if remote.millis > last.millis || (remote.millis == last.millis && remote.counter > last.counter) {
            last = HLC(millis: remote.millis, counter: remote.counter, device: device)
        }
    }
}
