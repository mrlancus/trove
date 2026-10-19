#if os(iOS)
import Photos
import TroveCore
import UIKit

/// iPhone/iPad: imports new screenshots (opt-in) so their text becomes searchable.
enum ScreenshotImporter {
    static func requestAccess() async -> Bool {
        await PHPhotoLibrary.requestAuthorization(for: .readWrite) == .authorized
    }

    /// Imports screenshots taken after `since`; returns the newest date imported.
    static func importNew(since: Date?, into library: Library, limit: Int = 50) async -> Date? {
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else { return nil }
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "(mediaSubtypes & %d) != 0 AND creationDate > %@",
                                        PHAssetMediaSubtype.photoScreenshot.rawValue, (since ?? Date().addingTimeInterval(-7 * 86_400)) as NSDate)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        options.fetchLimit = limit
        let assets = PHAsset.fetchAssets(with: .image, options: options)
        var newest = since
        var list: [PHAsset] = []
        assets.enumerateObjects { asset, _, _ in list.append(asset) }
        for asset in list {
            guard let data = await imageData(for: asset) else { continue }
            _ = try? await library.addFile(data, name: "Screenshot.jpg", mime: "image/jpeg", kind: .image, source: .screenshot,
                                           title: "Screenshot", createdAt: asset.creationDate)
            newest = asset.creationDate ?? newest
        }
        return newest
    }

    private static func imageData(for asset: PHAsset) async -> Data? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .highQualityFormat
            options.version = .current
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, _ in
                // Re-encode as JPEG (HEIC screenshots are rare, but keep one format for previews).
                if let data, let image = UIImage(data: data) { continuation.resume(returning: image.jpegData(compressionQuality: 0.85)) }
                else { continuation.resume(returning: nil) }
            }
        }
    }
}
#endif
