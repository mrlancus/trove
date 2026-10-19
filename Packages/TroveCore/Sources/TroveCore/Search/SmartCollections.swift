import Foundation

/// Collections that fill themselves (RESEARCH.md §6). Each is just a saved query.
public enum SmartCollection: String, CaseIterable, Identifiable, Sendable {
    case recent, pinned, toRead, recipes, places, thingsToBuy, events, videos, receipts, quotes, notes, handwriting, needsAttention

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .recent: "Recent"
        case .pinned: "Pinned"
        case .toRead: "To Read"
        case .recipes: "Recipes"
        case .places: "Places"
        case .thingsToBuy: "Things to Buy"
        case .events: "Events"
        case .videos: "Videos"
        case .receipts: "Receipts"
        case .quotes: "Quotes & Highlights"
        case .notes: "Notes"
        case .handwriting: "Handwriting"
        case .needsAttention: "Needs Attention"
        }
    }

    /// SF Symbol name for the sidebar.
    public var symbol: String {
        switch self {
        case .recent: "clock"
        case .pinned: "pin"
        case .toRead: "book"
        case .recipes: "fork.knife"
        case .places: "mappin.and.ellipse"
        case .thingsToBuy: "bag"
        case .events: "calendar"
        case .videos: "play.rectangle"
        case .receipts: "receipt"
        case .quotes: "quote.opening"
        case .notes: "note.text"
        case .handwriting: "pencil.and.scribble"
        case .needsAttention: "exclamationmark.triangle"
        }
    }

    public func contains(_ item: Item) -> Bool {
        switch self {
        case .recent: return -item.createdAt.timeIntervalSinceNow < 14 * 86_400
        case .pinned: return item.isPinned
        case .toRead: return item.readAt == nil && (item.category == .article || (item.kind == .link && item.category == .other))
        case .recipes: return item.category == .recipe
        case .places: return item.category == .place || item.extracted["place"] != nil
        case .thingsToBuy: return item.category == .product
        case .events: return item.category == .event
        case .videos: return item.category == .video || item.kind == .video
        case .receipts: return item.category == .receipt
        case .quotes: return item.kind == .highlight || item.category == .quote
        case .notes: return item.kind == .note
        case .handwriting: return item.source == .goodnotes
        case .needsAttention: return item.hasConflicts
        }
    }
}
