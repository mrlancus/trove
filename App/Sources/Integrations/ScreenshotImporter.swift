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
    static func importNew(since: Date?, into library: Library, route: ScreenshotRoute, limit: Int = 50) async -> Date? {
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
            guard let (original, data) = await imageData(for: asset) else { continue }
            // With iCloud Photos the other devices see this screenshot too: keyed by its time and
            // bytes, so it's saved once (`Library.addScreenshot`).
            if route.notes { _ = try? await library.addScreenshot(data, original: original, takenAt: asset.creationDate ?? Date()) }
            if route.clipboard { _ = try? await library.addScreenshotClip(data, device: DeviceInfo.name) }
            newest = asset.creationDate ?? newest
        }
        await library.removeDuplicateScreenshots()
        return newest
    }

    /// The photo's own bytes and a JPEG of it.
    private static func imageData(for asset: PHAsset) async -> (Data, Data)? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .highQualityFormat
            options.version = .current
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, _ in
                // Re-encode as JPEG (HEIC screenshots are rare, but keep one format for previews).
                if let data, let image = UIImage(data: data), let jpeg = image.jpegData(compressionQuality: 0.85) { continuation.resume(returning: (data, jpeg)) }
                else { continuation.resume(returning: nil) }
            }
        }
    }
}
#endif
