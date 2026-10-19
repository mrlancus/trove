import AppIntents
import SwiftUI
import WidgetKit

/// Home Screen / Lock Screen / desktop widgets, fed by the snapshot the app writes to the App Group.

struct TroveEntry: TimelineEntry {
    let date: Date
    let snapshot: SharedConfig.WidgetSnapshot?
}

struct TroveProvider: TimelineProvider {
    func placeholder(in context: Context) -> TroveEntry {
        TroveEntry(date: Date(), snapshot: .init(updated: Date(), recent: [
            .init(id: "1", title: "Best ever ramen", subtitle: "Recipe", symbol: "fork.knife", pinned: true),
            .init(id: "2", title: "Trip ideas", subtitle: "Note", symbol: "note.text", pinned: false),
        ], pinned: [], counts: ["toRead": 4]))
    }
    func getSnapshot(in context: Context, completion: @escaping (TroveEntry) -> Void) {
        completion(TroveEntry(date: Date(), snapshot: SharedConfig.loadWidget()) )
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<TroveEntry>) -> Void) {
        let entry = TroveEntry(date: Date(), snapshot: SharedConfig.loadWidget())
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(30 * 60))))
    }
}

struct RecentWidgetView: View {
    let entry: TroveEntry
    var pinnedOnly = false
    @Environment(\.widgetFamily) private var family

    var body: some View {
        let items = (pinnedOnly ? entry.snapshot?.pinned : entry.snapshot?.recent) ?? []
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "shippingbox.fill").foregroundStyle(.orange)
                Text(pinnedOnly ? "Pinned" : "Trove").font(.headline)
                Spacer()
                Link(destination: URL(string: "trove://capture")!) { Image(systemName: "plus.circle.fill").font(.title3) }
            }
            if items.isEmpty {
                Text(pinnedOnly ? "Pin items to see them here." : "Things you save appear here.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(items.prefix(family == .systemSmall ? 2 : family == .systemMedium ? 3 : 6)) { item in
                Link(destination: URL(string: "trove://item/\(item.id)")!) {
                    HStack(spacing: 8) {
                        Image(systemName: item.symbol).frame(width: 18).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(item.title).font(.subheadline.weight(.medium)).lineLimit(1)
                            if family != .systemSmall { Text(item.subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

struct RecentWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "TroveRecent", provider: TroveProvider()) { RecentWidgetView(entry: $0) }
            .configurationDisplayName("Recent")
            .description("Your latest saves, one tap away.")
            .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct PinnedWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "TrovePinned", provider: TroveProvider()) { RecentWidgetView(entry: $0, pinnedOnly: true) }
            .configurationDisplayName("Pinned")
            .description("Things you keep coming back to.")
            .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

#if os(iOS)
/// Control Center / Lock Screen / Action Button: open Trove ready to capture.
struct CaptureControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "TroveCaptureControl") {
            ControlWidgetButton(action: OpenCaptureIntent()) {
                Label("Capture", systemImage: "shippingbox")
            }
        }
        .displayName("Capture in Trove")
    }
}
#endif

@main
struct TroveWidgetBundle: WidgetBundle {
    var body: some Widget {
        RecentWidget()
        PinnedWidget()
        #if os(iOS)
        CaptureControl()
        #endif
    }
}
