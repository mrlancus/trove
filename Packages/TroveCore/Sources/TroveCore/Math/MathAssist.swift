import Foundation

/// Math Assist (docs/MASTER_PLAN.md G7): solving one handwritten line after the user writes `=`,
/// built to cost almost nothing and to cope with messy handwriting.
///
/// - Nothing runs while writing. `EqualsDetector` spots an `=` from two strokes' shapes alone
///   (microseconds, no model); only then is the one line to its left gathered (`MathLine`) and
///   read by the platform's recogniser.
/// - The recogniser's many guesses are expanded with maths look-alikes and the one that is valid
///   maths and fits the page wins (`MathCandidates`).
/// - Results are cached by the line's strokes, so an untouched line is never read twice.
public enum MathAssist {

    // MARK: What a line says

    public enum Outcome: Equatable, Sendable {
        /// `12*4 =` → 48.
        case value(Double)
        /// `a = 5` (or `a = 2*3`) defines a for the lines below.
        case assignment(String, Double)
        /// `2+2 = 5`: both sides are numbers; `correct` says whether they agree.
        case check(correct: Bool, left: Double, right: Double)
        /// `2x + 3 = 7` → x = 2.
        case solved(String, Double)
        /// Couldn't be worked out (shown as a grey "?", never a guess).
        case unsure
    }

    public struct Line: Equatable, Sendable {
        public var text: String
        public var outcome: Outcome
        public init(text: String, outcome: Outcome) { self.text = text; self.outcome = outcome }
    }

    /// Works out one line. `env` holds variables defined on earlier lines.
    public static func solve(_ text: String, env: [String: Double] = [:]) -> Outcome {
        let normal = MathExpression.normalise(text)
        let parts = normal.split(separator: "=", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 else {
            // No "=": a plain expression (maths in notes evaluates on demand).
            if parts.count == 1, let e = try? MathExpression.parse(normal), let v = try? e.evaluate(env) { return .value(v) }
            return .unsure
        }
        let lhs = parts[0], rhs = parts[1]
        guard !lhs.isEmpty, let left = try? MathExpression.parse(lhs) else { return .unsure }
        // "expr =": the answer.
        if rhs.isEmpty {
            guard let v = try? left.evaluate(env) else { return .unsure }
            return .value(v)
        }
        guard let right = try? MathExpression.parse(rhs) else { return .unsure }
        // "a = expr": a definition, when a is a single new letter.
        if case .variable(let name) = left, env[name] == nil, right.variables.subtracting(env.keys).isEmpty,
           let v = try? right.evaluate(env) {
            return .assignment(name, v)
        }
        let unknowns = left.variables.union(right.variables).subtracting(env.keys)
        if unknowns.isEmpty {
            guard let a = try? left.evaluate(env), let b = try? right.evaluate(env) else { return .unsure }
            return .check(correct: approximatelyEqual(a, b), left: a, right: b)
        }
        guard unknowns.count == 1, let v = unknowns.first,
              let x = solveLinear(left: left, right: right, variable: v, env: env) else { return .unsure }
        return .solved(v, x)
    }

    /// Solves left = right for one unknown when the equation is linear in it (checked at three points).
    public static func solveLinear(left: MathExpression, right: MathExpression, variable v: String, env: [String: Double]) -> Double? {
        func h(_ x: Double) -> Double? {
            var e = env
            e[v] = x
            guard let a = try? left.evaluate(e), let b = try? right.evaluate(e) else { return nil }
            return a - b
        }
        guard let h0 = h(0), let h1 = h(1), let h2 = h(2) else { return nil }
        let slope = h1 - h0
        guard Swift.abs(slope) > 1e-12, approximatelyEqual(h2 - h1, slope) else { return nil }
        let x = -h0 / slope
        guard let check = h(x), Swift.abs(check) < 1e-6 * max(1, Swift.abs(h0)) else { return nil }
        return Swift.abs(x - x.rounded()) < 1e-9 ? x.rounded() : x
    }

    static func approximatelyEqual(_ a: Double, _ b: Double) -> Bool {
        Swift.abs(a - b) <= 1e-9 * max(1, Swift.abs(a), Swift.abs(b))
    }

    /// Lines written one under another, top to bottom: definitions carry down, and each step of a
    /// worked solution is checked against the one before (`2x+3=7` → `2x=4` ✓ → `x=3` ✗).
    public struct StepCheck: Equatable, Sendable {
        public var outcome: Outcome
        /// For an equation step: false when its solution differs from the previous step's.
        public var followsFromPrevious: Bool?
    }

    public static func check(lines: [String]) -> [StepCheck] {
        var env: [String: Double] = [:]
        var previousSolution: (String, Double)?
        var out: [StepCheck] = []
        for text in lines {
            let outcome = solve(text, env: env)
            var follows: Bool?
            switch outcome {
            case .assignment(let name, let v):
                // "x = 3" right after an equation in x is the last step, not a definition.
                if let (pv, px) = previousSolution, pv == name {
                    follows = approximatelyEqual(px, v)
                    previousSolution = (name, v)
                    out.append(StepCheck(outcome: .solved(name, v), followsFromPrevious: follows))
                    continue
                }
                env[name] = v
            case .solved(let name, let v):
                if let (pv, px) = previousSolution, pv == name { follows = approximatelyEqual(px, v) }
                previousSolution = (name, v)
            default:
                previousSolution = nil
            }
            out.append(StepCheck(outcome: outcome, followsFromPrevious: follows))
        }
        return out
    }

    /// What to draw after the `=` (nil: nothing, or a grey "?" when `unsure`).
    public static func answerText(_ outcome: Outcome) -> String? {
        switch outcome {
        case .value(let v): return MathExpression.format(v)
        case .solved(let name, let v): return "\(name) = \(MathExpression.format(v))"
        case .check(let ok, _, let right): return ok ? "✓" : "✗ \(MathExpression.format(right))"
        case .assignment: return nil
        case .unsure: return "?"
        }
    }

    // MARK: When to run (battery)

    public enum Mode: String, Codable, Sendable, CaseIterable {
        /// Solve as soon as an `=` is written.
        case automatic
        /// Only from lasso → Solve, or tapping a line.
        case onRequest
        case off
    }

    /// The user's setting, held back by the power state: in Low Power Mode or when hot, automatic
    /// becomes on request (the user said GoodNotes' Math Assist drains the battery fast).
    public static func effectiveMode(_ setting: Mode, policy: PowerPolicy) -> Mode {
        guard setting == .automatic else { return setting }
        return policy.saving ? .onRequest : .automatic
    }

    /// How long after the pen lifts before reading the line (a new stroke nearby cancels it).
    public static let settleDelay: Double = 0.4
}

extension MathAssist {
    /// Maths in notes (MASTER_PLAN N10): the answer to write after a line that ends in "=", using
    /// variables defined on earlier lines (`rent = 900`). nil when the line isn't maths.
    public static func noteAnswer(line: String, before: [String]) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasSuffix("="), trimmed.count > 1 else { return nil }
        // Only lines that look like maths: digits or defined letters, operators, brackets.
        var env: [String: Double] = [:]
        for b in before.suffix(200) {
            if case .assignment(let name, let v) = solve(b, env: env) { env[name] = v }
        }
        guard case .value(let v) = solve(trimmed, env: env) else { return nil }
        return format(v)
    }

    static func format(_ v: Double) -> String { MathExpression.format(MathExpression.tidy(v)) }
}
