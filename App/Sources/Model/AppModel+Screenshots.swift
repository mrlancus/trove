import Foundation
import TroveCore

/// Screenshots from this device go into Trove as they're taken (only screenshots, never other
/// photos). With iCloud Photos the other devices may import the same one: it's saved once
/// (`Library.addScreenshot`).
extension AppModel {
    /// Where this device's screenshots go. Before routes existed it was one switch for the library.
    var myScreenshotRoute: ScreenshotRoute {
        screenshotRoutes[(config?.deviceId ?? "").uppercased()] ?? ScreenshotRoute(notes: config?.screenshotsImport == true)
    }

    /// Picks up changes from any device (each device's row can be set from another).
    func loadScreenshotRoutes() async {
        guard let library, let me = config?.deviceId.uppercased() else { return }
        var routes = await library.screenshotRoutes()
        if routes[me] == nil, config?.screenshotsImport == true {
            // The old switch becomes this device's row, once.
            await library.setScreenshotRoute(ScreenshotRoute(notes: true), for: me)
            routes[me] = ScreenshotRoute(notes: true)
        }
        guard routes != screenshotRoutes else { return }
        screenshotRoutes = routes
        watchScreenshots()
    }

    func setScreenshotRoute(_ route: ScreenshotRoute, for device: String) async {
        guard let library else { return }
        screenshotRoutes[device.uppercased()] = route
        await library.setScreenshotRoute(route, for: device)
        if device.uppercased() == config?.deviceId.uppercased() {
            updateConfig { $0.screenshotsImport = route.isOn }
            watchScreenshots()
        }
        Task { await syncNow() }
    }

    /// Starts or stops watching for screenshots, as the setting says.
    func watchScreenshots() {
        if myScreenshotRoute.isOn, library != nil {
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
        let route = myScreenshotRoute
        guard route.isOn, let library else { return }
        if screenshotImport != nil { screenshotsAgain = true; return }
        screenshotImport = Task { [weak self] in
            guard let self else { return }
            repeat {
                self.screenshotsAgain = false
                let since = self.config?.lastScreenshotImport
                var newest: Date?
                #if os(iOS)
                newest = await ScreenshotImporter.importNew(since: since, into: library, route: route)
                #else
                for (url, takenAt) in self.screenshotWatcher?.screenshots(since: since) ?? [] {
                    // Spotlight lists it before the file is complete now and then: wait for the bytes.
                    guard let original = try? Data(contentsOf: url), !original.isEmpty else { continue }
                    let name = url.deletingPathExtension().lastPathComponent + ".jpg"
                    let stored = await Task.detached(priority: .utility) { ScreenshotWatcher.jpeg(original) }.value
                    if route.notes {
                        _ = try? await library.addScreenshot(stored ?? original, original: original, takenAt: takenAt,
                                                             name: stored == nil ? url.lastPathComponent : name,
                                                             mime: stored == nil ? "image/png" : "image/jpeg")
                    }
                    if route.clipboard {
                        _ = try? await library.addScreenshotClip(stored ?? original, mime: stored == nil ? "image/png" : "image/jpeg", device: DeviceInfo.name)
                    }
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
