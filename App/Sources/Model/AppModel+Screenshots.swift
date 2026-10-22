import Foundation
import TroveCore

/// Screenshots from this device go into Trove as they're taken (only screenshots, never other
/// photos). With iCloud Photos the other devices may import the same one: it's saved once
/// (`Library.addScreenshot`).
extension AppModel {
    /// Starts or stops watching for screenshots, as the setting says.
    func watchScreenshots() {
        if config?.screenshotsImport == true, library != nil {
            guard screenshotWatcher == nil else { return }
            screenshotWatcher = ScreenshotWatcher { [weak self] in self?.importScreenshots() }
            importScreenshots()
        } else {
            screenshotWatcher?.stop()
            screenshotWatcher = nil
        }
    }

    /// Imports screenshots newer than the last one imported. One run at a time; a change during a
    /// run starts another after it.
    func importScreenshots() {
        guard config?.screenshotsImport == true, let library else { return }
        if screenshotImport != nil { screenshotsAgain = true; return }
        screenshotImport = Task { [weak self] in
            guard let self else { return }
            repeat {
                self.screenshotsAgain = false
                let since = self.config?.lastScreenshotImport
                var newest: Date?
                #if os(iOS)
                newest = await ScreenshotImporter.importNew(since: since, into: library)
                #else
                for (url, takenAt) in self.screenshotWatcher?.screenshots(since: since) ?? [] {
                    // Spotlight lists it before the file is complete now and then: wait for the bytes.
                    guard let original = try? Data(contentsOf: url), !original.isEmpty else { continue }
                    let name = url.deletingPathExtension().lastPathComponent + ".jpg"
                    let stored = await Task.detached(priority: .utility) { ScreenshotWatcher.jpeg(original) }.value
                    _ = try? await library.addScreenshot(stored ?? original, original: original, takenAt: takenAt,
                                                         name: stored == nil ? url.lastPathComponent : name,
                                                         mime: stored == nil ? "image/png" : "image/jpeg")
                    newest = takenAt
                }
                #endif
                if let newest, newest != since {
                    self.updateConfig { $0.lastScreenshotImport = newest }
                    await self.reload()
                    // Out to the other devices now, not at the next sync.
                    Task { await self.syncNow() }
                }
            } while self.screenshotsAgain
            self.screenshotImport = nil
        }
    }
}
