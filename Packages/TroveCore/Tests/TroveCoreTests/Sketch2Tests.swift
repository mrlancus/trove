import Foundation
import Testing
@testable import TroveCore

/// Sketch 2 (docs/plans/sketch-2-plan.md): the stress notebook, handwriting freshness, consent.
struct InkStressTests {
    @Test func sameSeedSameStrokes() {
        let a = InkStress.strokes(page: 3, count: 200)
        let b = InkStress.strokes(page: 3, count: 200)
        #expect(a == b)
        #expect(a.count == 200)
        #expect(InkStress.strokes(page: 4, count: 200) != a)
        for s in a {
            #expect(!s.points.isEmpty)
            #expect(s.points.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.x >= 0 && $0.x <= 612 && $0.y >= 0 && $0.y <= 792 })
        }
    }

    @Test func notebookHasEveryPageAndStroke() async {
        let lib = Library(engine: SyncEngine(device: "D", keys: nil, encrypted: false))
        let id = await lib.addStressNotebook(pages: 3, strokesPerPage: 40)
        let pages = await lib.item(id)!.sketchPageList
        #expect(pages.count == 3)
        for p in pages {
            let n = await lib.strokes(on: id, pageKey: p.id).count
            #expect(n == 40)
        }
    }
}

struct HandwritingFreshnessTests {
    let pages: [(key: String, sig: String)] = [("a", "1"), ("b", "2"), ("c", "3")]

    @Test func clearedCacheReadsEverything() {
        // The synced signature matches, but this device holds nothing: every page is read.
        #expect(HandwritingFreshness.pagesToRead(pages, local: [:]) == ["a", "b", "c"])
        #expect(!HandwritingFreshness.upToDate(pages, local: [:]))
    }

    @Test func onlyChangedPagesAreRead() {
        #expect(HandwritingFreshness.pagesToRead(pages, local: ["a": "1", "b": "old", "c": "3"]) == ["b"])
        #expect(HandwritingFreshness.upToDate(pages, local: ["a": "1", "b": "2", "c": "3"]))
    }
}

struct PictureConsentTests {
    @Test func asksOncePerSessionByDefault() {
        #expect(PictureConsent.decide(.askEachSession, session: nil) == .ask)
        let r = PictureConsent.apply(.allowSession, setting: .askEachSession)
        #expect(r.send && r.session == true && r.setting == .askEachSession)
        #expect(PictureConsent.decide(r.setting, session: r.session) == .send)
    }

    @Test func alwaysAndNever() {
        let r = PictureConsent.apply(.allowAlways, setting: .askEachSession)
        #expect(r.setting == .always)
        #expect(PictureConsent.decide(.always, session: nil) == .send)
        #expect(PictureConsent.decide(.never, session: true) == .skip)
    }

    @Test func onceAndNotNowAskAgain() {
        let once = PictureConsent.apply(.allowOnce, setting: .askEachSession)
        #expect(once.send && once.session == nil)
        let no = PictureConsent.apply(.notNow, setting: .askEachSession)
        #expect(!no.send && PictureConsent.decide(no.setting, session: no.session) == .ask)
    }
}
