import Foundation

/// Every constant the mastery model uses, with its reason (docs/DEVELOP_PLAN.md Appendix B). Change
/// one here and every device re-scores the whole history the same way, since mastery is derived.
public struct MasteryConstants: Sendable, Equatable {
    /// First step size: one even-odds success moves ability 0.4 logits (about 10 points of success
    /// chance): enough to notice, too little for one result to be mastery.
    public var k0 = 0.8
    /// A problem more than this many logits below my ability is one I'd get right ~73 %+ of the time;
    /// succeeding at it says little, so it changes neither ability nor retention.
    public var trivialMargin = 1.0
    /// A success at difficulty b is evidence of ability up to about b + this, not beyond.
    public var ceilingMargin = 1.0
    /// Credit kept at each hint level (0 none … 5 full solution): each hint gives away more of the method.
    public var independence: [Double] = [1.0, 0.85, 0.7, 0.5, 0.3, 0.0]
    /// I decide what I got right with the scheme in front of me; AI may misapply the scheme (checked by
    /// the eval set); without a scheme an AI mark is a guess; unmarked is no evidence.
    public var markingWeight: [Marking: Double] = [.selfMarked: 1.0, .aiScheme: 0.9, .aiNoScheme: 0.5, .none: 0]
    /// FSRS grades from the independence-adjusted score: ≥ good → Good, ≥ hard → Hard, else Again.
    public var goodScore = 0.85
    public var hardScore = 0.5
    /// Practice again when the chance of still being able to do it falls to this. Lower than cards'
    /// 0.9 because a practice problem costs minutes, not seconds.
    public var skillRetention = 0.85
    /// Understanding a solution after failing needs a check the next day.
    public var reassessAfterFailureDays = 1.0
    /// "Proficient": mastery at least this, with this many successes over this many different problems
    /// from this many different sources, and the latest attempt not a failure.
    public var proficientMastery = 0.7
    public var proficientSuccesses = 3
    public var proficientProblems = 2
    public var proficientSources = 2
    /// An attempt counts as a success at this adjusted score.
    public var successScore = 0.7
    /// Two failures at least this long after the last success suggest looking at the prerequisites.
    public var prerequisiteGapDays = 1.0
    /// Calibration is shown from this many predictions.
    public var calibrationMinimum = 30
    /// Ability of an average candidate on a standard question at the spec's level.
    public var referenceDifficulty = 0.0

    public init() {}
    public static let standard = MasteryConstants()
}

/// What Trove knows about one skill, derived from its attempts.
public struct SkillState: Sendable, Equatable {
    public var skill: String
    /// Ability on the logit scale (0 = an average candidate on a standard question).
    public var ability: Double
    /// Fisher information gathered (1 = one even-odds problem).
    public var information: Double
    /// σ(ability − reference), or nil until a non-trivial attempt ("not assessed").
    public var mastery: Double?
    public var memory: FSRS.State?
    public var attempts: Int
    public var trivial: Int
    public var successes: Int
    public var distinctProblems: Int
    public var distinctSources: Int
    public var lastWasFailure: Bool
    public var proficient: Bool
    /// When to practise again (Unix ms), or nil if never attempted.
    public var due: Double?
    public var needsPrerequisites: Bool
    /// (predicted chance of success, succeeded) for every non-trivial attempt, oldest first.
    public var predictions: [(Double, Bool)]
    public var why: String

    public static func == (a: SkillState, b: SkillState) -> Bool {
        a.skill == b.skill && a.ability == b.ability && a.information == b.information && a.mastery == b.mastery && a.memory == b.memory
            && a.attempts == b.attempts && a.trivial == b.trivial && a.successes == b.successes && a.proficient == b.proficient
            && a.due == b.due && a.needsPrerequisites == b.needsPrerequisites && a.why == b.why
            && a.predictions.map(\.0) == b.predictions.map(\.0) && a.predictions.map(\.1) == b.predictions.map(\.1)
    }

    /// The chance I can still do it at `now` (Unix ms).
    public func retention(at now: Double) -> Double? {
        guard let m = memory else { return nil }
        return FSRS.retrievability(days: (now - m.last) / Mastery.day, stability: m.stability)
    }

    /// The chance I can apply the skill `days` after the last attempt: ability times memory.
    public func pApply(daysAfterLast days: Double, constants c: MasteryConstants = .standard) -> Double? {
        guard let m = memory else { return nil }
        return Mastery.sigmoid(ability - c.referenceDifficulty) * FSRS.retrievability(days: days, stability: m.stability)
    }

    /// Brier score of the predictions, once there are enough (lower is better; 0.25 is guessing 50/50).
    public func brier(constants c: MasteryConstants = .standard) -> Double? {
        guard predictions.count >= c.calibrationMinimum else { return nil }
        return predictions.map { p, ok in (p - (ok ? 1 : 0)) * (p - (ok ? 1 : 0)) }.reduce(0, +) / Double(predictions.count)
    }
}

/// The mastery engine (docs/DEVELOP_PLAN.md §B3 point 3, §C7): a pure function of the attempts.
/// Ability is a one-parameter IRT estimate with an information-weighted step; retention is FSRS on a
/// per-skill memory; two rules make farming easy problems worthless.
public enum Mastery {
    static let day = 86_400_000.0

    public static func sigmoid(_ x: Double) -> Double { 1 / (1 + exp(-x)) }

    /// Every skill's state from these attempts (any order; they're sorted by time, then id).
    public static func evaluate(_ attempts: [Attempt], constants c: MasteryConstants = .standard) -> [String: SkillState] {
        var bySkill: [String: [Attempt]] = [:]
        for a in attempts { for s in Set(a.skills) { bySkill[s, default: []].append(a) } }
        var out: [String: SkillState] = [:]
        for (skill, list) in bySkill { out[skill] = evaluate(skill: skill, list, constants: c) }
        return out
    }

    public static func evaluate(skill: String, _ attempts: [Attempt], constants c: MasteryConstants = .standard) -> SkillState {
        let sorted = attempts.sorted { $0.at != $1.at ? $0.at < $1.at : $0.id < $1.id }
        var theta = 0.0, n = 0.0
        var memory: FSRS.State?
        var counted = 0, trivial = 0
        var successes: [(problem: String, source: String)] = []
        var lastWasFailure = false
        var lastSuccessAt: Double?
        var failuresAfterGap = 0
        var reassessAt: Double?
        var predictions: [(Double, Bool)] = []
        for a in sorted {
            let w = c.markingWeight[a.marking] ?? 0
            guard w > 0, !a.uncertain, let score = a.score else { continue }
            if a.b < theta - c.trivialMargin { trivial += 1; continue }
            let hint = min(max(a.hint, 0), c.independence.count - 1)
            let s = min(max(score, 0), 1) * c.independence[hint]
            let p = sigmoid(theta - a.b)
            let k = c.k0 / (1 + n).squareRoot()
            var next = theta + k * w * (s - p)
            if s > p { next = min(next, max(theta, a.b + c.ceilingMargin)) }
            theta = next
            n += w * 4 * p * (1 - p)
            let grade: FSRS.Grade = s >= c.goodScore ? .good : (s >= c.hardScore ? .hard : .again)
            memory = FSRS.review(memory, grade, now: a.at)
            counted += 1
            let ok = s >= c.successScore
            predictions.append((p, ok))
            if ok {
                successes.append((a.problem, a.sourceKey))
                lastSuccessAt = a.at
                failuresAfterGap = 0
                reassessAt = nil
            } else {
                if let last = lastSuccessAt, a.at - last >= c.prerequisiteGapDays * day { failuresAfterGap += 1 }
                if hint == c.independence.count - 1 { reassessAt = a.at + c.reassessAfterFailureDays * day }
            }
            lastWasFailure = !ok
        }
        let mastery = counted > 0 ? sigmoid(theta - c.referenceDifficulty) : nil
        let problems = Set(successes.map(\.problem)).count, sources = Set(successes.map(\.source)).count
        let proficient = (mastery ?? 0) >= c.proficientMastery && successes.count >= c.proficientSuccesses
            && problems >= c.proficientProblems && sources >= c.proficientSources && !lastWasFailure
        var due: Double?
        if let m = memory {
            due = m.last + max(1, FSRS.interval(stability: m.stability, retention: c.skillRetention).rounded()) * day
            if let r = reassessAt { due = min(due!, r) }
        }
        let why: String
        if counted == 0 {
            why = trivial > 0 ? "Not assessed: \(trivial) attempt\(trivial == 1 ? "" : "s") too easy to count." : "Not assessed yet."
        } else if proficient {
            why = "Proficient: \(successes.count) independent solves across \(problems) problems from \(sources) sources."
        } else {
            let need = max(0, c.proficientSuccesses - successes.count)
            why = "\(successes.count) success\(successes.count == 1 ? "" : "es") in \(counted) counted attempt\(counted == 1 ? "" : "s")"
                + (need > 0 ? "; \(need) more in a different context to show it." : (lastWasFailure ? "; the latest was a miss." : "."))
        }
        return SkillState(skill: skill, ability: theta, information: n, mastery: mastery, memory: memory, attempts: counted, trivial: trivial,
                          successes: successes.count, distinctProblems: problems, distinctSources: sources, lastWasFailure: lastWasFailure,
                          proficient: proficient, due: due, needsPrerequisites: failuresAfterGap >= 2, predictions: predictions, why: why)
    }
}

/// Problem difficulty and the AI routing rule (docs/DEVELOP_PLAN.md Appendix C).
public enum Difficulty {
    /// Prior difficulty by level when nothing better is known.
    public static let levelBase: [ProblemLevel: Double] = [.gcse: -1, .alevel: 0, .competition: 1.5, .university: 1.5, .other: 0]
    /// An A-level question whose national average is below this is hard (most candidates lost most marks).
    public static let hardNationalAverage = 0.35
    /// Trove's own estimate counts from this many attempts.
    public static let ownEstimateMinimum = 5
    public static let hardOwnDifficulty = 1.0

    /// b on the logit scale: from the national average fraction of marks when known, else the level's base.
    public static func b(_ problem: Problem) -> Double {
        if let avg = problem.nationalAverage, avg > 0, avg < 1 {
            let clamped = min(max(avg, 0.02), 0.98)
            return -log(clamped / (1 - clamped))
        }
        return levelBase[problem.level] ?? 0
    }

    /// Hard means hard to solve: never GCSE; competition and university by default; A-level only on
    /// evidence. Marks, length, parts and handwriting don't count.
    public static func isHard(_ problem: Problem, ownEstimate: Double? = nil, attempts: Int = 0) -> Bool {
        switch problem.level {
        case .gcse: return false
        case .competition, .university: return true
        case .alevel, .other:
            if let avg = problem.nationalAverage, avg < hardNationalAverage { return true }
            if let own = ownEstimate, attempts >= ownEstimateMinimum, own >= hardOwnDifficulty { return true }
            return false
        }
    }
}

/// Which model and effort a Develop AI task uses. One table, here. The user's own tier choice or key
/// overrides it in the app; nothing here ever picks a dearer model.
public enum DevelopAI {
    public enum Task: String, Sendable { case mark, hint, tagConcepts, splitHelp, explain, plan }
    public struct Route: Sendable, Equatable {
        public var model: String
        public var effort: String
        public var maxTokens: Int
    }

    public static let model = "claude-haiku-5-5"

    public static func route(_ task: Task, hard: Bool, retryOfUncertain: Bool = false) -> Route {
        let effort = hard || retryOfUncertain ? "medium" : "low"
        let maxTokens: Int = switch task {
        case .mark: effort == "medium" ? 2_500 : 1_200
        case .hint: 600
        case .tagConcepts: 500
        case .splitHelp: 800
        case .explain: 1_500
        case .plan: 3_000
        }
        return Route(model: model, effort: effort, maxTokens: maxTokens)
    }
}
