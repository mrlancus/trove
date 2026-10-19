import CoreSpotlight
import Foundation
import TroveCore
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

/// Makes Trove items show up in system Spotlight search; tapping one opens it in Trove.
enum SpotlightIndexer {
    static let domain = "com.mrlancus.trove.items"
    nonisolated(unsafe) private static var indexed: [String: String] = [:]   // id → updatedHLC

    static func index(_ items: [Item]) {
        let changed = items.filter { indexed[$0.id] != $0.record.updatedHLC }
        guard !changed.isEmpty else { return }
        let entries = changed.map { item -> CSSearchableItem in
            let attributes = CSSearchableItemAttributeSet(contentType: .text)
            attributes.title = item.displayTitle
            attributes.contentDescription = item.summary ?? String(item.body.prefix(300))
            attributes.keywords = item.tags + [item.category.rawValue]
            attributes.contentURL = item.url
            attributes.addedDate = item.createdAt
            return CSSearchableItem(uniqueIdentifier: item.id, domainIdentifier: domain, attributeSet: attributes)
        }
        CSSearchableIndex.default().indexSearchableItems(entries) { error in
            guard error == nil else { return }
            DispatchQueue.main.async { for item in changed { indexed[item.id] = item.record.updatedHLC } }
        }
    }

    static func remove(_ id: String) {
        indexed[id] = nil
        CSSearchableIndex.default().deleteSearchableItems(withIdentifiers: [id]) { _ in }
    }
}
