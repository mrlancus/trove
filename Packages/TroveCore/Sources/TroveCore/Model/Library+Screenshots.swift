import Foundation

/// Screenshots imported from Photos (iPhone/iPad). With iCloud Photos every device sees the same
/// screenshots, so each would import its own copy: they're keyed by when they were taken and their
/// exact bytes, and copies that match in both are removed.
extension Library {
    /// The same on every device for the same screenshot: its time (to the millisecond) and bytes.
    public static func screenshotId(takenAt: Date, original: Data) -> String {
        let ms = Int64((takenAt.timeIntervalSince1970 * 1000).rounded())
        return "screenshot-" + String((String(ms) + ":" + original.sha256Hex).sha256Hex.prefix(32))
    }

    /// Adds a screenshot unless another device already did. `original` is the photo's own bytes (for
    /// the id); `data` is what's stored. Returns the item id, or nil if it was there already.
    @discardableResult
    public func addScreenshot(_ data: Data, original: Data, takenAt: Date, name: String = "Screenshot.jpg", mime: String = "image/jpeg") async throws -> String? {
        let id = Self.screenshotId(takenAt: takenAt, original: original)
        if await engine.record(id) != nil { return nil } // there, or deleted on purpose
        return try await addFile(data, name: name, mime: mime, kind: .image, source: .screenshot, title: "Screenshot", createdAt: takenAt, id: id)
    }

    /// Removes screenshots saved twice: same time and the very same file. One with a different time,
    /// or different bytes, stays. Every device keeps the same one (the smallest id). Returns how many went.
    @discardableResult
    public func removeDuplicateScreenshots() async -> Int {
        var groups: [String: [Item]] = [:]
        for item in await items() where item.source == .screenshot {
            guard let file = item.attachments.first else { continue }
            let ms = Int64((item.createdAt.timeIntervalSince1970 * 1000).rounded())
            groups["\(ms)|\(file.id)|\(file.size)", default: []].append(item)
        }
        var removed = 0
        for group in groups.values where group.count > 1 {
            for extra in group.sorted(by: { $0.id < $1.id }).dropFirst() {
                await delete(extra.id)
                removed += 1
            }
        }
        return removed
    }
}

/// Where one device's screenshots go (PROTOCOL.md §8 `settings.screenshots`): into the library as
/// items, into clipboard history, both, or nowhere. Set from any device; each device imports its own.
public struct ScreenshotRoute: Sendable, Equatable {
    public var notes: Bool
    public var clipboard: Bool
    public init(notes: Bool = false, clipboard: Bool = false) { self.notes = notes; self.clipboard = clipboard }
    public var isOn: Bool { notes || clipboard }
}

extension Library {
    public static let screenshotSettingsId = "settings.screenshots"

    /// Every device's choice, by device id (uppercased). A device with no entry hasn't chosen yet.
    public func screenshotRoutes() async -> [String: ScreenshotRoute] {
        guard let r = await engine.record(Self.screenshotSettingsId), !r.isDeleted else { return [:] }
        var out: [String: ScreenshotRoute] = [:]
        for (key, value) in r.fields {
            let parts = key.split(separator: ".")
            guard parts.count == 2, let on = value.bool else { continue }
            let device = String(parts[0]).uppercased()
            var route = out[device] ?? ScreenshotRoute()
            if parts[1] == "notes" { route.notes = on } else if parts[1] == "clipboard" { route.clipboard = on } else { continue }
            out[device] = route
        }
        return out
    }

    public func setScreenshotRoute(_ route: ScreenshotRoute, for device: String) async {
        let d = device.uppercased()
        await engine.set(["\(d).notes": .bool(route.notes), "\(d).clipboard": .bool(route.clipboard)], record: Self.screenshotSettingsId, kind: "setting")
    }

    /// A screenshot into clipboard history (kept once however many devices see it, by its bytes).
    @discardableResult
    public func addScreenshotClip(_ data: Data, mime: String = "image/jpeg", device: String? = nil) async throws -> String? {
        try await addClip(image: data, mime: mime, sourceApp: "Screenshot", sourceDevice: device)
    }
}
