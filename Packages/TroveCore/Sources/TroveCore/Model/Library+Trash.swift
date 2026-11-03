import Foundation

/// Recently Deleted (docs/MASTER_PLAN.md N11): deleted items stay as tombstones in the journal, so
/// for 30 days they can be brought back, like Apple Notes. Restoring clears `_deleted` (a normal
/// last-writer-wins field), so it syncs like any edit.
extension Library {
    public static let trashDays = 30.0

    public struct Deleted: Identifiable, Sendable, Equatable {
        public var item: Item
        public var deletedAt: Date
        public var id: String { item.id }
    }

    /// Items deleted in the last `days`, most recent first.
    public func recentlyDeleted(days: Double = Library.trashDays, now: Date = Date()) async -> [Deleted] {
        let cutoff = now.addingTimeInterval(-days * 86_400)
        return await engine.store.all(kind: "item").filter { $0.isDeleted && !$0.isStrayItem }.compactMap { r in
            guard let hlc = HLC(r.updatedHLC) else { return nil }
            let when = Date(timeIntervalSince1970: Double(hlc.millis) / 1000)
            return when >= cutoff ? Deleted(item: Item(r), deletedAt: when) : nil
        }.sorted { $0.deletedAt > $1.deletedAt }
    }

    public func restore(_ id: String) async {
        guard let r = await engine.record(id), r.isDeleted else { return }
        await engine.set(["_deleted": false], record: id, kind: r.kind)
    }
}
