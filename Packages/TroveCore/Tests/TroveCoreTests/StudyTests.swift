import Foundation
import Testing
@testable import TroveCore

/// Study mode (MASTER_PLAN G8): FSRS scheduling and the review queue.
struct StudyTests {
    let day = 86_400_000.0

    @Test func newCardsStartWhereFSRSSays() {
        let good = FSRS.review(nil, .good, now: 0)
        #expect(abs(good.stability - FSRS.w[2]) < 1e-9)
        #expect(good.due == 3 * day) // ~3.1 days, rounded
        let again = FSRS.review(nil, .again, now: 0)
        #expect(again.due == 10 * 60_000)
        #expect(again.lapses == 1)
        #expect(FSRS.review(nil, .easy, now: 0).due > good.due)
        #expect(FSRS.review(nil, .easy, now: 0).difficulty < FSRS.review(nil, .hard, now: 0).difficulty)
    }

    @Test func intervalsGrowWhenRememberedAndShrinkWhenForgotten() {
        var s = FSRS.review(nil, .good, now: 0)
        var last = s.due
        for _ in 0..<5 {
            let next = FSRS.review(s, .good, now: s.due)
            #expect(next.due - s.due > last - s.last) // each interval longer than the one before
            last = next.due - s.due + s.due
            s = next
        }
        let forgot = FSRS.review(s, .again, now: s.due)
        #expect(forgot.stability < s.stability)
        #expect(forgot.due - s.due == 10 * 60_000)
        #expect(FSRS.retrievability(days: 0, stability: 5) == 1)
        #expect(abs(FSRS.retrievability(days: 5, stability: 5) - 0.9) < 1e-9)
        #expect(abs(FSRS.interval(stability: 5) - 5) < 1e-9)
    }

    @Test func queueAndReviewsSync() async {
        let lib = Library(engine: SyncEngine(device: "D", keys: nil, encrypted: false))
        let note = await lib.addFlashcards([("What makes ATP?", "Mitochondria"), ("Where is DNA?", "Nucleus")], title: "Cells", from: nil, where: "device", model: "")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var queue = await lib.studyQueue(now: now)
        #expect(queue.count == 2)
        #expect(queue.allSatisfy { $0.isNew })
        await lib.review(queue[0], .good, now: now)
        await lib.review(queue[1], .again, now: now)
        queue = await lib.studyQueue(now: now)
        #expect(queue.isEmpty) // the Again one comes back in 10 minutes
        queue = await lib.studyQueue(now: now.addingTimeInterval(11 * 60))
        #expect(queue.map(\.front) == ["Where is DNA?"])
        queue = await lib.studyQueue(now: now.addingTimeInterval(4 * 86_400), from: note)
        #expect(queue.count == 2)
        // The card id is stable while the question stays the same.
        let ids = await lib.studyCards().map(\.id)
        let prefix = "card.\(note)."
        #expect(ids.allSatisfy { $0.hasPrefix(prefix) })
        #expect(FSRS.preview(nil, now: 0)[.again] == "10 min")
    }
}

/// Learn → Cards (learn-pivot plan §4 B1, step 7): decks with their due and new counts.
@Suite struct DeckTests {
    @Test func decksCountWhatsDueAndNew() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let ms = now.timeIntervalSince1970 * 1000
        func card(_ note: String, _ title: String, due: Double?) -> StudyCard {
            StudyCard(id: UUID().uuidString, noteId: note, noteTitle: title, front: "f", back: "b",
                      state: due.map { FSRS.State(stability: 1, difficulty: 5, reps: 1, lapses: 0, last: ms - 86_400_000, due: $0) })
        }
        let decks = Deck.summaries([card("a", "French verbs", due: ms - 1), card("a", "French verbs", due: ms + 1e9), card("a", "French verbs", due: nil),
                                    card("b", "Biology words", due: nil), card("c", "Atoms", due: ms - 5), card("c", "Atoms", due: ms - 6)], now: now)
        #expect(decks.map(\.title) == ["Atoms", "French verbs", "Biology words"])
        #expect(decks[1].total == 3 && decks[1].due == 1 && decks[1].new == 1)
        #expect(decks[2].due == 0 && decks[2].new == 1)
    }
}
