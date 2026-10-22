import Foundation
import Testing
@testable import TroveCore

/// Screenshots from iCloud Photos seen by two devices are saved once; exact copies are removed.
@Suite struct ScreenshotTests {
    @Test func twoDevicesSaveOneAndExactCopiesGo() async throws {
        let lib = Library(engine: SyncEngine(device: "D", keys: .generate(), transports: []))
        let shot = Data("png bytes".utf8), other = Data("other bytes".utf8)
        let t = Date(timeIntervalSince1970: 1_792_591_502.123)
        let id = try #require(try await lib.addScreenshot(Data("jpeg".utf8), original: shot, takenAt: t))
        #expect(try await lib.addScreenshot(Data("jpeg".utf8), original: shot, takenAt: t) == nil) // the other device
        #expect(id == Library.screenshotId(takenAt: t, original: shot))
        // Same picture at another time, or another picture at the same time: both kept.
        #expect(try await lib.addScreenshot(Data("jpeg".utf8), original: shot, takenAt: t.addingTimeInterval(1)) != nil)
        #expect(try await lib.addScreenshot(Data("jpeg2".utf8), original: other, takenAt: t) != nil)
        // Copies made before ids were shared: same time and same file go; a different file stays.
        let a = try await lib.addFile(Data("old".utf8), name: "Screenshot.jpg", mime: "image/jpeg", kind: .image, source: .screenshot, createdAt: t, id: "b-old")
        _ = try await lib.addFile(Data("old".utf8), name: "Screenshot.jpg", mime: "image/jpeg", kind: .image, source: .screenshot, createdAt: t, id: "a-old")
        _ = try await lib.addFile(Data("older".utf8), name: "Screenshot.jpg", mime: "image/jpeg", kind: .image, source: .screenshot, createdAt: t, id: "c-old")
        _ = try await lib.addFile(Data("old".utf8), name: "Photo.jpg", mime: "image/jpeg", kind: .image, source: .app, createdAt: t, id: "d-photo")
        #expect(await lib.removeDuplicateScreenshots() == 1)
        #expect(await lib.item(a) == nil) // "a-old" is kept on every device
        #expect(await lib.item("a-old") != nil)
        #expect(await lib.item("c-old") != nil)
        #expect(await lib.item("d-photo") != nil)
        #expect(await lib.items().filter { $0.source == .screenshot }.count == 5)
        #expect(await lib.removeDuplicateScreenshots() == 0)
    }
}
