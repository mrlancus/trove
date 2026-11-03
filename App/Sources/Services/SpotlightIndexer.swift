import CoreSpotlight
import Foundation
import TroveCore
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

/// Makes Trove items show up in system Spotlight search; tapping one opens it in Trove.
///
/// What's been handed to Spotlight (id → updatedHLC) is saved in a small file, so a launch only
/// sends what changed since last time (it used to re-index every item on every launch), and items
/// deleted on another device are taken out too (docs/MASTER_PLAN.md P6). All of it runs off the
/// main thread, in batches.
enum SpotlightIndexer {
    static let domain = "com.mrlancus.trove.items"

    static func index(_ items: [Item]) {
        Task.detached(priority: .utility) { await SpotlightStore.shared.index(items) }
    }

    static func remove(_ id: String) {
        Task.detached(priority: .utility) { await SpotlightStore.shared.remove([id]) }
    }
}

actor SpotlightStore {
    static let shared = SpotlightStore()
    static let batch = 400

    private var indexed: [String: String]?
    private var saveTask: Task<Void, Never>?
    private let url: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("spotlight-indexed.plist")
    }()

    private func load() -> [String: String] {
        if let indexed { return indexed }
        let loaded = (try? Data(contentsOf: url)).flatMap { try? PropertyListDecoder().decode([String: String].self, from: $0) } ?? [:]
        indexed = loaded
        return loaded
    }

    func index(_ items: [Item]) async {
        var known = load()
        let live = Set(items.map(\.id))
        let gone = known.keys.filter { !live.contains($0) }
        let changed = items.filter { known[$0.id] != $0.record.updatedHLC }
        guard !changed.isEmpty || !gone.isEmpty else { return }
        if !gone.isEmpty {
            for chunk in gone.chunked(Self.batch) {
                try? await CSSearchableIndex.default().deleteSearchableItems(withIdentifiers: chunk)
            }
            for id in gone { known[id] = nil }
        }
        for chunk in changed.chunked(Self.batch) {
            let entries = chunk.map(Self.entry)
            do {
                try await CSSearchableIndex.default().indexSearchableItems(entries)
                for item in chunk { known[item.id] = item.record.updatedHLC }
            } catch {
                break
            }
            await Task.yield()
        }
        indexed = known
        saveSoon()
    }

    func remove(_ ids: [String]) async {
        var known = load()
        for id in ids { known[id] = nil }
        indexed = known
        try? await CSSearchableIndex.default().deleteSearchableItems(withIdentifiers: ids)
        saveSoon()
    }

    private func saveSoon() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .seconds(5), tolerance: .seconds(2))
            guard !Task.isCancelled else { return }
            self.save()
        }
    }

    private func save() {
        guard let indexed, let data = try? PropertyListEncoder().encode(indexed) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func entry(_ item: Item) -> CSSearchableItem {
        let attributes = CSSearchableItemAttributeSet(contentType: contentType(item))
        attributes.title = item.displayTitle
        attributes.contentDescription = item.summary ?? String(item.body.prefix(300))
        attributes.keywords = item.tags + [item.category.rawValue]
        attributes.contentURL = item.url
        attributes.addedDate = item.createdAt
        return CSSearchableItem(uniqueIdentifier: item.id, domainIdentifier: SpotlightIndexer.domain, attributeSet: attributes)
    }

    static func contentType(_ item: Item) -> UTType {
        switch item.kind {
        case .link: return .url
        case .image: return .image
        case .pdf: return .pdf
        default: return .text
        }
    }
}

private extension Array {
    func chunked(_ size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
