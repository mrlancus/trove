import Foundation

/// Study mode (docs/MASTER_PLAN.md G8): spaced repetition over flashcards with FSRS (the open
/// "Free Spaced Repetition Scheduler", version 5 default weights). Cards come from notes with a
/// `flashcards` field (made by Ask AI → Make flashcards, or the notebook chat); each card's review
/// state is a `card` record (PROTOCOL.md §12 "Study"), synced like everything else.
public enum FSRS {
    /// FSRS-5 default parameters.
    public static let w: [Double] = [0.4072, 1.1829, 3.1262, 15.4722, 7.2102, 0.5316, 1.0651, 0.0234, 1.616, 0.1544,
                                     1.0824, 1.9813, 0.0953, 0.2975, 2.2042, 0.2407, 2.9466, 0.5034, 0.6567]
    static let decay = -0.5
    static let factor = 19.0 / 81.0
    /// The chance of remembering a card when it comes up again.
    public static let retention = 0.9

    public enum Grade: Int, CaseIterable, Sendable {
        case again = 1, hard, good, easy
        public var label: String {
            switch self {
            case .again: "Again"
            case .hard: "Hard"
            case .good: "Good"
            case .easy: "Easy"
            }
        }
    }

    public struct State: Equatable, Sendable {
        /// Days until the chance of remembering falls to 90 %.
        public var stability: Double
        /// 1 (easy) … 10 (hard).
        public var difficulty: Double
        public var reps: Int
        public var lapses: Int
        /// When it was last reviewed and when it's due (Unix ms).
        public var last: Double
        public var due: Double

        public init(stability: Double, difficulty: Double, reps: Int, lapses: Int, last: Double, due: Double) {
            self.stability = stability; self.difficulty = difficulty; self.reps = reps; self.lapses = lapses; self.last = last; self.due = due
        }
    }

    static func clampD(_ d: Double) -> Double { min(10, max(1, d)) }
    static func initialDifficulty(_ g: Grade) -> Double { clampD(w[4] - exp(w[5] * Double(g.rawValue - 1)) + 1) }

    /// The chance of remembering after `days` with stability `s`.
    public static func retrievability(days: Double, stability s: Double) -> Double {
        pow(1 + factor * max(0, days) / max(0.01, s), decay)
    }

    /// Days until retention falls to `retention` (= the stability at 90 %).
    public static func interval(stability s: Double, retention r: Double = retention) -> Double {
        s / factor * (pow(r, 1 / decay) - 1)
    }

    static let day = 86_400_000.0
    /// A card you got wrong (or a new one marked Again) comes back this soon.
    static let relearn = 10 * 60_000.0

    /// The state after a review at `now` (Unix ms). nil `state` is a new card.
    public static func review(_ state: State?, _ g: Grade, now: Double) -> State {
        guard let s0 = state else {
            let s = w[g.rawValue - 1]
            let d = initialDifficulty(g)
            let due = g == .again ? now + relearn : now + max(1, interval(stability: s).rounded()) * day
            return State(stability: s, difficulty: d, reps: 1, lapses: g == .again ? 1 : 0, last: now, due: due)
        }
        let elapsed = max(0, (now - s0.last) / day)
        let r = retrievability(days: elapsed, stability: s0.stability)
        // Difficulty: moves with the grade, damped near 10, pulled back towards the default.
        let delta = -w[6] * Double(g.rawValue - 3)
        let damped = s0.difficulty + delta * (10 - s0.difficulty) / 9
        let d = clampD(w[7] * initialDifficulty(.easy) + (1 - w[7]) * damped)
        var s: Double
        if g == .again {
            s = w[11] * pow(d, -w[12]) * (pow(s0.stability + 1, w[13]) - 1) * exp(w[14] * (1 - r))
            s = min(s, s0.stability)
        } else {
            let hard = g == .hard ? w[15] : 1
            let easy = g == .easy ? w[16] : 1
            s = s0.stability * (1 + exp(w[8]) * (11 - d) * pow(s0.stability, -w[9]) * (exp(w[10] * (1 - r)) - 1) * hard * easy)
        }
        s = max(0.01, s)
        let due = g == .again ? now + relearn : now + max(1, interval(stability: s).rounded()) * day
        return State(stability: s, difficulty: d, reps: s0.reps + 1, lapses: s0.lapses + (g == .again ? 1 : 0), last: now, due: due)
    }

    /// "10 min", "3 d", "2 mo": what each grade would give, shown on its button.
    public static func preview(_ state: State?, now: Double) -> [Grade: String] {
        var out: [Grade: String] = [:]
        for g in Grade.allCases {
            let next = review(state, g, now: now)
            let ms = next.due - now
            out[g] = ms < day ? "\(Int((ms / 60_000).rounded())) min" : ms < 30 * day ? "\(Int((ms / day).rounded())) d"
                : ms < 365 * day ? "\(Int((ms / (30 * day)).rounded())) mo" : String(format: "%.1f y", ms / (365 * day))
        }
        return out
    }
}

/// One flashcard and where it lives.
public struct StudyCard: Identifiable, Equatable, Sendable {
    /// `card.<note id>.<first 12 hex of sha256(front)>`: stable while the question stays the same.
    public var id: String
    public var noteId: String
    public var noteTitle: String
    public var front: String
    public var back: String
    public var state: FSRS.State?

    public var isNew: Bool { state == nil }
}

extension Library {
    public static let cardKind = "card"
    /// New cards introduced per day (the rest wait for the next day).
    public static let newCardsPerDay = 20

    /// Every flashcard in the library with its review state.
    public func studyCards() async -> [StudyCard] {
        var states: [String: FSRS.State] = [:]
        for r in await engine.records(kind: Self.cardKind) {
            let f = r.fields
            guard let s = f["stability"]?.number, let d = f["difficulty"]?.number, let due = f["due"]?.number else { continue }
            states[r.id] = FSRS.State(stability: s, difficulty: d, reps: Int(f["reps"]?.number ?? 0), lapses: Int(f["lapses"]?.number ?? 0),
                                      last: f["last"]?.number ?? 0, due: due)
        }
        var out: [StudyCard] = []
        for item in await items() {
            guard let cards = item.record["flashcards"]?.array else { continue }
            for c in cards {
                guard let o = c.object, let front = o["front"]?.string, let back = o["back"]?.string, !front.isEmpty else { continue }
                let id = "card.\(item.id).\(String(front.sha256Hex.prefix(12)))"
                out.append(StudyCard(id: id, noteId: item.id, noteTitle: item.displayTitle, front: front, back: back, state: states[id]))
            }
        }
        return out
    }

    /// What to review now: due cards (most overdue first), then up to the day's new cards.
    public func studyQueue(now: Date = Date(), from noteId: String? = nil) async -> [StudyCard] {
        let ms = now.timeIntervalSince1970 * 1000
        let all = await studyCards().filter { noteId == nil || $0.noteId == noteId }
        let due = all.filter { ($0.state?.due ?? .infinity) <= ms }.sorted { ($0.state?.due ?? 0) < ($1.state?.due ?? 0) }
        let startOfDay = Calendar.current.startOfDay(for: now).timeIntervalSince1970 * 1000
        // Seen once, today: new cards already started today.
        let introducedToday = all.filter { $0.state?.reps == 1 && ($0.state?.last ?? 0) >= startOfDay }.count
        let newOnes = all.filter(\.isNew).prefix(max(0, Self.newCardsPerDay - introducedToday))
        return due + newOnes
    }

    /// Records a review.
    @discardableResult
    public func review(_ card: StudyCard, _ grade: FSRS.Grade, now: Date = Date()) async -> FSRS.State {
        let next = FSRS.review(card.state, grade, now: now.timeIntervalSince1970 * 1000)
        await engine.set([
            "note": .string(card.noteId), "stability": .number(next.stability), "difficulty": .number(next.difficulty),
            "reps": .number(Double(next.reps)), "lapses": .number(Double(next.lapses)), "last": .number(next.last), "due": .number(next.due),
        ], record: card.id, kind: Self.cardKind)
        return next
    }
}
