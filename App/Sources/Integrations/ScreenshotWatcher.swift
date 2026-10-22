import Foundation
import ImageIO
import TroveCore
import UniformTypeIdentifiers
#if os(iOS)
import Photos
#endif

/// New screenshots go into Trove as soon as they're taken (screenshots only, never other photos).
/// Mac: Spotlight's live query for screen captures (macOS tags them `kMDItemIsScreenCapture`).
/// iPhone/iPad: Photos tells the app about new pictures while it's open (iOS doesn't let apps watch
/// Photos in the background), and the app imports when it comes to the front.
@MainActor
final class ScreenshotWatcher: NSObject {
    private let changed: @MainActor () -> Void

    init(changed: @escaping @MainActor () -> Void) {
        self.changed = changed
        super.init()
        start()
    }

    #if os(iOS)
    private func start() { PHPhotoLibrary.shared().register(self) }
    func stop() { PHPhotoLibrary.shared().unregisterChangeObserver(self) }
    #else
    private var query: NSMetadataQuery?

    private func start() {
        let q = NSMetadataQuery()
        q.predicate = NSPredicate(format: "kMDItemIsScreenCapture == 1")
        q.searchScopes = [NSMetadataQueryLocalComputerScope]
        NotificationCenter.default.addObserver(self, selector: #selector(updated), name: .NSMetadataQueryDidUpdate, object: q)
        NotificationCenter.default.addObserver(self, selector: #selector(updated), name: .NSMetadataQueryDidFinishGathering, object: q)
        q.start()
        query = q
    }

    func stop() {
        query?.stop()
        if let query { NotificationCenter.default.removeObserver(self, name: nil, object: query) }
        query = nil
    }

    @objc private func updated(_ note: Notification) { changed() }

    /// Screenshots on this Mac taken after `since` (all of them from the last week when nil), oldest first.
    func screenshots(since: Date?) -> [(url: URL, takenAt: Date)] {
        guard let query else { return [] }
        let from = since ?? Date().addingTimeInterval(-7 * 86_400)
        query.disableUpdates()
        defer { query.enableUpdates() }
        var out: [(URL, Date)] = []
        for case let item as NSMetadataItem in query.results {
            guard let path = item.value(forAttribute: NSMetadataItemPathKey) as? String,
                  let date = (item.value(forAttribute: "kMDItemContentCreationDate") as? Date) ?? (item.value(forAttribute: NSMetadataItemFSCreationDateKey) as? Date),
                  date > from else { continue }
            out.append((URL(fileURLWithPath: path), date))
        }
        return out.sorted { $0.1 < $1.1 }
    }
    #endif

    /// A JPEG of a picture file (screenshots are big PNGs; the iPhone and iPad store JPEGs too).
    nonisolated static func jpeg(_ data: Data, quality: Double = 0.85) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }
}

#if os(iOS)
extension ScreenshotWatcher: PHPhotoLibraryChangeObserver {
    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor in self.changed() }
    }
}
#endif
