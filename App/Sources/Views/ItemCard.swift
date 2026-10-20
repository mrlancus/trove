import SwiftUI
import TroveCore

/// A library card. Each content type gets a distinct, subtle treatment.
struct ItemCard: View {
    let item: Item
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Thumbnail(item: item)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: ItemStyle.symbol(for: item))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(ItemStyle.tint(for: item))
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if item.isPinned { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.orange) }
                    if item.enrichment?.tier == .cloud { Image(systemName: "cloud").font(.caption2).foregroundStyle(.secondary).help("Processed in the cloud") }
                    if item.hasConflicts { Image(systemName: "exclamationmark.triangle.fill").font(.caption2).foregroundStyle(.yellow) }
                }
                Text(item.displayTitle)
                    .font(.headline)
                    .lineLimit(3)
                    .foregroundStyle(.primary)
                if let snippet {
                    Text(snippet)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(item.kind == .highlight ? 6 : 3)
                }
                if let price = productPrice {
                    Text(price).font(.subheadline.weight(.semibold)).foregroundStyle(.pink)
                }
                if !item.tags.isEmpty {
                    HStack(spacing: 4) { ForEach(item.tags.prefix(3), id: \.self) { TagChip(tag: $0) } }
                        .tint(ItemStyle.tint(for: item))
                }
            }
            .padding(12)
        }
        .card()
        .contentShape(RoundedRectangle(cornerRadius: 18))
    }

    private var subtitle: String { Self.subtitle(item) }
    private var snippet: String? { Self.snippet(item) }

    static func subtitle(_ item: Item) -> String {
        let place = item.siteName ?? item.url?.host?.replacingOccurrences(of: "www.", with: "") ?? ItemStyle.sourceLabel(item.source)
        return "\(place) · \(item.createdAt.relative)"
    }

    static func snippet(_ item: Item) -> String? {
        if item.kind == .highlight { return item.body.replacingOccurrences(of: "> ", with: "") }
        if let s = item.summary, !s.isEmpty { return s }
        let body = item.body.trimmingCharacters(in: .whitespacesAndNewlines)
        if !body.isEmpty { return body }
        if let ocr = item.ocrText, !ocr.isEmpty { return ocr }
        return nil
    }

    private var productPrice: String? {
        if let w = item.priceWatch, let price = w.price {
            let dropped = w.previous.map { price < $0 } ?? false
            return (dropped ? "↓ " : "") + PriceAlerts.price(price, w.currency)
        }
        guard let p = item.extracted["product"]?.object, let price = p["price"]?.number else { return nil }
        let currency = p["currency"]?.string ?? "GBP"
        return price.formatted(.currency(code: currency))
    }
}

/// Image for a card: page preview image, an image attachment, or a tinted symbol. With `square`,
/// a small rounded tile for list rows that always shows something.
struct Thumbnail: View {
    let item: Item
    var square: CGFloat? = nil
    @Environment(AppModel.self) private var model
    @State private var image: PlatformImage?

    var body: some View {
        Group {
            if let image {
                Image(platformImage: image).resizable().scaledToFill()
            } else if let s = item.record[Field.imageURL]?.string, let url = URL(string: s) {
                AsyncImage(url: url) { phase in
                    if let img = phase.image { img.resizable().scaledToFill() } else { placeholder }
                }
            } else if hasVisual || square != nil {
                placeholder
            }
        }
        .modifier(ThumbnailFrame(square: square, height: hasVisual ? 140 : 0))
        .task(id: item.attachments.first?.id) { await loadAttachment() }
    }

    private var hasVisual: Bool {
        image != nil || item.record[Field.imageURL]?.string != nil || item.attachments.contains { $0.mime.hasPrefix("image/") || $0.mime == "application/pdf" }
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(colors: [ItemStyle.tint(for: item).opacity(0.35), ItemStyle.tint(for: item).opacity(0.1)], startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: ItemStyle.symbol(for: item)).font(square == nil ? .largeTitle : .title3).foregroundStyle(.white.opacity(0.85))
        }
    }

    private func loadAttachment() async {
        guard image == nil, let a = item.attachments.first, let library = model.library else { return }
        if a.mime.hasPrefix("image/"), let data = try? await library.attachmentData(a) {
            image = Self.downscale(data)
        } else if a.mime == "application/pdf", let data = try? await library.attachmentData(a) {
            image = PDFThumbnail.make(data)
        }
    }

    nonisolated static func downscale(_ data: Data) -> PlatformImage? {
        guard let img = PlatformImage(data: data) else { return nil }
        #if canImport(UIKit)
        return img.preparingThumbnail(of: CGSize(width: 600, height: 600 * img.size.height / max(img.size.width, 1))) ?? img
        #else
        return img
        #endif
    }
}

private struct ThumbnailFrame: ViewModifier {
    let square: CGFloat?
    let height: CGFloat

    func body(content: Content) -> some View {
        if let square {
            content.frame(width: square, height: square).clipShape(RoundedRectangle(cornerRadius: square / 5, style: .continuous))
        } else {
            content.frame(maxWidth: .infinity).frame(height: height).clipped()
        }
    }
}
