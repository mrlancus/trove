import Foundation

/// Keeps the relay's price watches in line with the items that have "Track price drops" on, then
/// copies prices back onto those items (PROTOCOL.md §5). The item field is the source of truth, so
/// an iCloud-only device can switch tracking on and a relay device sets up the watch.
public enum PriceWatchSync {
    public struct Result: Sendable, Equatable {
        public var added = 0
        public var removed = 0
        public var drops: [PriceDrop] = []
        public var errors: [String] = []
    }

    public static func run(client: RelayClient, library: Library) async -> Result {
        var result = Result()
        let remote: [RelayClient.Watch]
        do { remote = try await client.watches() } catch {
            result.errors.append("list: \(error)")
            return result
        }
        let wanted = Dictionary(uniqueKeysWithValues: await library.items().compactMap { item in
            item.priceWatch.map { (item.id, $0.url) }
        })
        let existing = Dictionary(remote.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        for (id, url) in wanted where existing[id]?.url != url {
            do {
                try await client.putWatch(id: id, url: url, itemId: id)
                result.added += 1
            } catch { result.errors.append("\(id): \(error)") }
        }
        for watch in remote where wanted[watch.id] == nil {
            do {
                try await client.deleteWatch(id: watch.id)
                result.removed += 1
            } catch { result.errors.append("\(watch.id): \(error)") }
        }
        result.drops = await library.applyWatches(remote.filter { wanted[$0.id] == $0.url })
        return result
    }
}
