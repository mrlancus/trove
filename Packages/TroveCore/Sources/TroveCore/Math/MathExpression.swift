import Foundation

/// A small maths language for Math Assist and maths in notes (docs/MASTER_PLAN.md G7, N10).
/// It parses what handwriting recognition read (`12×4.5`, `2(3+4)²`, `√16 + 3x`, `15% of 80`) into a
/// tree, evaluates it, and solves linear equations in one unknown. No AI, no network: it runs in
/// microseconds, so Math Assist costs nothing beyond reading the one line that was written.
public indirect enum MathExpression: Equatable, Sendable {
    case number(Double)
    case variable(String)
    case unary(Character, MathExpression)          // "-"
    case binary(Character, MathExpression, MathExpression) // + - * / ^
    case function(String, MathExpression)
    case percent(MathExpression)
    case factorial(MathExpression)

    public enum Failure: Error, Equatable {
        case empty, unexpected(String), unbalanced, unknownFunction(String), undefined(String), notANumber
    }

    // MARK: Parsing

    public static let functions: Set<String> = ["sqrt", "sin", "cos", "tan", "asin", "acos", "atan", "log", "ln", "abs", "exp"]
    public static let constants: [String: Double] = ["pi": .pi, "π": .pi, "e": M_E, "τ": 2 * .pi]

    enum Token: Equatable {
        case number(Double), ident(String), op(Character), lparen, rparen
    }

    /// Unifies what recognisers and keyboards write for the same thing.
    public static func normalise(_ text: String) -> String {
        var s = text
        let replacements: [(String, String)] = [
            ("×", "*"), ("·", "*"), ("⋅", "*"), ("∙", "*"), ("÷", "/"), (":", "/"), ("−", "-"), ("–", "-"), ("—", "-"),
            ("**", "^"), ("²", "^2"), ("³", "^3"), ("√", "sqrt"), ("{", "("), ("}", ")"), ("[", "("), ("]", ")"),
        ]
        for (a, b) in replacements { s = s.replacingOccurrences(of: a, with: b) }
        // "15% of 80" → "15%*80"
        s = s.replacingOccurrences(of: "% of", with: "%*").replacingOccurrences(of: "%of", with: "%*")
        return s.filter { !$0.isWhitespace }
    }

    static func tokenize(_ raw: String) throws -> [Token] {
        let chars = Array(normalise(raw))
        var out: [Token] = []
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c.isNumber || (c == "." && i + 1 < chars.count && chars[i + 1].isNumber) {
                var j = i
                var text = ""
                while j < chars.count, chars[j].isNumber || chars[j] == "." || (chars[j] == "," && j + 1 < chars.count && chars[j + 1].isNumber && text.count <= 3) {
                    if chars[j] != "," { text.append(chars[j]) }
                    j += 1
                }
                guard let value = Double(text) else { throw Failure.unexpected(text) }
                out.append(.number(value))
                i = j
            } else if c.isLetter || c == "π" || c == "τ" {
                var j = i
                var text = ""
                while j < chars.count, chars[j].isLetter || chars[j] == "π" || chars[j] == "τ" { text.append(chars[j]); j += 1 }
                out.append(contentsOf: splitIdentifier(text.lowercased()))
                i = j
            } else if "+-*/^%!".contains(c) {
                out.append(.op(c)); i += 1
            } else if c == "(" {
                out.append(.lparen); i += 1
            } else if c == ")" {
                out.append(.rparen); i += 1
            } else {
                throw Failure.unexpected(String(c))
            }
        }
        return out
    }

    /// "sqrt", "pi", "sin" stay whole; anything else splits into single-letter variables, so "2xy"
    /// is 2·x·y (handwritten maths never has multi-letter variable names).
    static func splitIdentifier(_ text: String) -> [Token] {
        let lower = text.lowercased()
        if functions.contains(lower) || constants[lower] != nil { return [.ident(lower)] }
        for f in functions.sorted(by: { $0.count > $1.count }) where lower.hasPrefix(f) && lower.count > f.count {
            return [.ident(f)] + splitIdentifier(String(text.dropFirst(f.count)))
        }
        if lower.hasPrefix("pi"), lower.count > 2 { return [.ident("pi")] + splitIdentifier(String(text.dropFirst(2))) }
        return text.map { .ident(String($0)) }
    }

    public static func parse(_ text: String) throws -> MathExpression {
        var parser = Parser(tokens: try tokenize(text))
        guard !parser.tokens.isEmpty else { throw Failure.empty }
        let expr = try parser.expression()
        guard parser.pos == parser.tokens.count else { throw Failure.unexpected("\(parser.tokens[parser.pos])") }
        return expr
    }

    struct Parser {
        var tokens: [Token]
        var pos = 0

        var peek: Token? { pos < tokens.count ? tokens[pos] : nil }

        mutating func expression() throws -> MathExpression {
            var left = try term()
            while case .op(let c)? = peek, c == "+" || c == "-" {
                pos += 1
                left = .binary(c, left, try term())
            }
            return left
        }

        mutating func term() throws -> MathExpression {
            var left = try unary()
            while true {
                if case .op(let c)? = peek, c == "*" || c == "/" {
                    pos += 1
                    left = .binary(c, left, try unary())
                } else if startsPrimary(peek) {
                    // Implicit multiplication: 2x, 3(4+1), (a)(b), 2√9.
                    left = .binary("*", left, try power())
                } else {
                    return left
                }
            }
        }

        func startsPrimary(_ t: Token?) -> Bool {
            switch t {
            case .number?, .ident?, .lparen?: return true
            default: return false
            }
        }

        mutating func unary() throws -> MathExpression {
            if case .op(let c)? = peek, c == "-" || c == "+" {
                pos += 1
                let inner = try unary()
                return c == "-" ? .unary("-", inner) : inner
            }
            return try power()
        }

        mutating func power() throws -> MathExpression {
            let base = try postfix()
            if case .op("^")? = peek {
                pos += 1
                return .binary("^", base, try unary())
            }
            return base
        }

        mutating func postfix() throws -> MathExpression {
            var e = try primary()
            while case .op(let c)? = peek, c == "%" || c == "!" {
                pos += 1
                e = c == "%" ? .percent(e) : .factorial(e)
            }
            return e
        }

        mutating func primary() throws -> MathExpression {
            guard let t = peek else { throw Failure.empty }
            pos += 1
            switch t {
            case .number(let v):
                return .number(v)
            case .ident(let name):
                if MathExpression.functions.contains(name) {
                    // sqrt9, sqrt(9), sin30
                    if case .lparen? = peek {
                        pos += 1
                        let arg = try expression()
                        guard case .rparen? = peek else { throw Failure.unbalanced }
                        pos += 1
                        return .function(name, arg)
                    }
                    return .function(name, try power())
                }
                return .variable(name)
            case .lparen:
                let inner = try expression()
                guard case .rparen? = peek else { throw Failure.unbalanced }
                pos += 1
                return inner
            case .rparen:
                throw Failure.unbalanced
            case .op(let c):
                throw Failure.unexpected(String(c))
            }
        }
    }

    // MARK: Evaluating

    public func evaluate(_ env: [String: Double] = [:], degrees: Bool = true) throws -> Double {
        let v: Double
        switch self {
        case .number(let n): v = n
        case .variable(let name):
            if let value = env[name] { v = value } else if let c = Self.constants[name] { v = c } else { throw Failure.undefined(name) }
        case .unary(_, let e): v = -(try e.evaluate(env, degrees: degrees))
        case .binary(let op, let a, let b):
            let x = try a.evaluate(env, degrees: degrees), y = try b.evaluate(env, degrees: degrees)
            switch op {
            case "+": v = x + y
            case "-": v = x - y
            case "*": v = x * y
            case "/": v = x / y
            default: v = Foundation.pow(x, y)
            }
        case .function(let name, let e):
            let x = try e.evaluate(env, degrees: degrees)
            let rad = degrees ? x * .pi / 180 : x
            switch name {
            case "sqrt": v = x.squareRoot()
            case "sin": v = Self.clean(Foundation.sin(rad))
            case "cos": v = Self.clean(Foundation.cos(rad))
            case "tan": v = Self.clean(Foundation.tan(rad))
            case "asin": v = Foundation.asin(x) * (degrees ? 180 / .pi : 1)
            case "acos": v = Foundation.acos(x) * (degrees ? 180 / .pi : 1)
            case "atan": v = Foundation.atan(x) * (degrees ? 180 / .pi : 1)
            case "log": v = Foundation.log10(x)
            case "ln": v = Foundation.log(x)
            case "abs": v = Swift.abs(x)
            case "exp": v = Foundation.exp(x)
            default: throw Failure.unknownFunction(name)
            }
        case .percent(let e): v = try e.evaluate(env, degrees: degrees) / 100
        case .factorial(let e):
            let n = try e.evaluate(env, degrees: degrees)
            guard n >= 0, n <= 170, n == n.rounded() else { throw Failure.notANumber }
            v = n == 0 ? 1 : (1...Int(n)).reduce(1.0) { $0 * Double($1) }
        }
        guard v.isFinite else { throw Failure.notANumber }
        return v
    }

    /// sin(180°) is 1.2e-16 and sin(30°) 0.49999999999999994 in floating point: trig results are
    /// rounded to 12 significant digits, which is what someone writing by hand means.
    static func clean(_ x: Double) -> Double { Swift.abs(x) < 1e-12 ? 0 : tidy(x) }

    /// Rounds away floating-point dust (12 significant digits).
    public static func tidy(_ x: Double) -> Double {
        guard x != 0, x.isFinite else { return x }
        let digits = 12 - Int(Foundation.floor(Foundation.log10(Swift.abs(x)))) - 1
        guard digits > 0, digits < 300 else { return x }
        let scale = Foundation.pow(10, Double(digits))
        return (x * scale).rounded() / scale
    }

    /// Variables in the expression that aren't constants.
    public var variables: Set<String> {
        switch self {
        case .number: return []
        case .variable(let n): return Self.constants[n] == nil ? [n] : []
        case .unary(_, let e), .function(_, let e), .percent(let e), .factorial(let e): return e.variables
        case .binary(_, let a, let b): return a.variables.union(b.variables)
        }
    }

    // MARK: Formatting

    /// Up to 10 significant digits, no trailing zeros, thousands unseparated (as written by hand).
    public static func format(_ x: Double) -> String {
        if x == x.rounded(), Swift.abs(x) < 1e15 { return String(Int64(x)) }
        var s = String(format: "%.10g", x)
        if s.contains("e") { return s }
        if s.contains(".") {
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
        }
        return s
    }
}
