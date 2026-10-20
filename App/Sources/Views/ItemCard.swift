import ImageIO
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
            return (dropped ? "Down to " : "") + PriceAlerts.price(price, w.currency)
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
        // From the cache straight away when this file has been shown before (searching, scrolling back).
        let shown = image ?? cacheKey.flatMap(ThumbnailCache.cached)
        Group {
            if let shown {
                Image(platformImage: shown).resizable().scaledToFill()
            } else if let s = item.record[Field.imageURL]?.string, let url = URL(string: s) {
                AsyncImage(url: url) { phase in
                    if let img = phase.image { img.resizable().scaledToFill() } else { placeholder }
                }
            } else if hasVisual || square != nil {
                placeholder
            }
        }
        .modifier(ThumbnailFrame(square: square, height: hasVisual ? 140 : 0))
        .task(id: cacheKey) { await loadAttachment() }
    }

    /// The file the picture comes from: the synced preview, else the first attachment if it can make one.
    private var source: Attachment? {
        if let thumb = item.thumbnail { return thumb }
        guard let a = item.attachments.first, ThumbnailCache.canPreview(a) else { return nil }
        return a
    }

    private var cacheKey: String? { source?.id }

    private var hasVisual: Bool {
        image != nil || item.thumbnail != nil || item.kind == .sketch || item.record[Field.imageURL]?.string != nil
            || item.attachments.contains(where: ThumbnailCache.canPreview)
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(colors: [ItemStyle.tint(for: item).opacity(0.35), ItemStyle.tint(for: item).opacity(0.1)], startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: ItemStyle.symbol(for: item)).font(square == nil ? .largeTitle : .title3).foregroundStyle(.white.opacity(0.85))
        }
    }

    private func loadAttachment() async {
        guard let source, let library = model.library else { image = nil; return }
        image = await ThumbnailCache.image(for: source, from: library)
    }
}

/// Card pictures, made once per file and kept in memory, so a card that shows again (search
/// results, scrolling back) appears at once instead of decrypting and decoding its file again.
/// Pictures are made off the main thread at card size, never full size.
@MainActor
enum ThumbnailCache {
    private static let cache: NSCache<NSString, PlatformImage> = {
        let cache = NSCache<NSString, PlatformImage>()
        cache.countLimit = 500
        return cache
    }()
    private static var loading: [String: Task<Decoded?, Never>] = [:]

    static func cached(_ key: String) -> PlatformImage? { cache.object(forKey: key as NSString) }

    nonisolated static func canPreview(_ a: Attachment) -> Bool {
        (a.mime.hasPrefix("image/") && a.mime != "image/svg+xml") || a.mime == "application/pdf" || a.name.lowercased().hasSuffix(".goodnotes")
    }

    static func image(for attachment: Attachment, from library: Library) async -> PlatformImage? {
        let key = attachment.id
        if let hit = cached(key) { return hit }
        let task = loading[key] ?? Task<Decoded?, Never> {
            guard let data = try? await library.attachmentData(attachment) else { return nil }
            return await Task.detached(priority: .utility) { decode(data, attachment) }.value
        }
        loading[key] = task
        let decoded = await task.value
        loading[key] = nil
        if let hit = cached(key) { return hit } // another card asking for the same file got there first
        guard let decoded else { return nil }
        let image = PlatformImage.make(decoded.cgImage)
        cache.setObject(image, forKey: key as NSString)
        return image
    }

    struct Decoded: @unchecked Sendable { let cgImage: CGImage }

    nonisolated static func decode(_ data: Data, _ a: Attachment) -> Decoded? {
        if a.mime == "application/pdf" {
            return PDFThumbnail.make(data)?.cgImageForVision.map(Decoded.init)
        }
        if a.name.lowercased().hasSuffix(".goodnotes") {
            return FilePreview.goodnotes(data)?.thumbnail.flatMap { downscaled($0) }.map(Decoded.init)
        }
        return downscaled(data).map(Decoded.init)
    }

    /// A card-sized picture straight from the file's bytes (ImageIO never decodes it full size).
    nonisolated static func downscaled(_ data: Data, maxPixels: Int = 700) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: maxPixels,
                                        kCGImageSourceCreateThumbnailWithTransform: true]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

extension PlatformImage {
    static func make(_ cgImage: CGImage) -> PlatformImage {
        #if canImport(UIKit)
        UIImage(cgImage: cgImage)
        #else
        NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
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
