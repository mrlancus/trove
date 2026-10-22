import Foundation

/// What your AI did and what it cost (PROTOCOL.md §8 `aiusage.<device>.<day>`): every request, from
/// Ask or in the background, is logged with its tokens and price, so Settings → AI → Activity can
/// show exactly what ran, and totals for a session, day, week or month. One record per device per
/// day, one field per request (`log.<ms>-<n>`), so each request adds one small op.
public enum AIUsage {
    public enum Purpose: String, Sendable, CaseIterable {
        /// Ask (your questions, and the searches and reads it made for them).
        case ask
        /// Reading handwriting in the background (sketches, GoodNotes, PDFs, photos).
        case handwriting
        /// Note and page actions (rewrite, summarise, explain, flashcards).
        case action
        /// Settings → AI → Test.
        case test

        public var label: String {
            switch self {
            case .ask: "Ask"
            case .handwriting: "Reading handwriting"
            case .action: "Note actions"
            case .test: "Test"
            }
        }

        /// Runs without you asking (counts against the monthly limit for background work).
        public var isBackground: Bool { self == .handwriting }
    }

    /// One request to the provider.
    public struct Call: Sendable, Equatable, Identifiable {
        public var id: String
        public var at: Date
        public var device: String
        public var purpose: Purpose
        /// What it was about: the question, or the item's title.
        public var about: String
        public var model: String
        public var input: Int
        public var output: Int
        public var cacheRead: Int
        public var cacheWrite: Int
        /// US dollars, when the price is known.
        public var cost: Double?

        public init(id: String = "", at: Date = Date(), device: String = "", purpose: Purpose, about: String = "", model: String,
                    input: Int, output: Int, cacheRead: Int = 0, cacheWrite: Int = 0, cost: Double? = nil) {
            self.id = id; self.at = at; self.device = device; self.purpose = purpose; self.about = about; self.model = model
            self.input = input; self.output = output; self.cacheRead = cacheRead; self.cacheWrite = cacheWrite
            self.cost = cost ?? AIPrices.cost(model: model, input: input, output: output, cacheRead: cacheRead, cacheWrite: cacheWrite)
        }

        public var tokens: Int { input + output + cacheRead + cacheWrite }

        var json: JSONValue {
            var o: [String: JSONValue] = [
                "at": JSONValue(at), "purpose": .string(purpose.rawValue), "about": .string(String(about.prefix(160))),
                "model": .string(model), "in": .number(Double(input)), "out": .number(Double(output)),
            ]
            if cacheRead > 0 { o["cacheRead"] = .number(Double(cacheRead)) }
            if cacheWrite > 0 { o["cacheWrite"] = .number(Double(cacheWrite)) }
            if let cost { o["cost"] = .number(cost) }
            return .object(o)
        }

        init?(id: String, device: String, json: JSONValue) {
            guard let o = json.object, let purpose = o["purpose"]?.string.flatMap(Purpose.init(rawValue:)) else { return nil }
            self.id = id
            self.device = device
            self.purpose = purpose
            at = o["at"]?.date ?? Date(timeIntervalSince1970: 0)
            about = o["about"]?.string ?? ""
            model = o["model"]?.string ?? ""
            input = Int(o["in"]?.number ?? 0)
            output = Int(o["out"]?.number ?? 0)
            cacheRead = Int(o["cacheRead"]?.number ?? 0)
            cacheWrite = Int(o["cacheWrite"]?.number ?? 0)
            cost = o["cost"]?.number
        }
    }

    /// Sums of some calls.
    public struct Total: Sendable, Equatable {
        public var calls = 0
        public var input = 0
        public var output = 0
        public var cost = 0.0
        /// Some calls had no known price (counted in tokens only).
        public var unpriced = 0

        public init() {}

        public init<S: Sequence>(_ calls: S) where S.Element == Call {
            for c in calls { add(c) }
        }

        public mutating func add(_ c: Call) {
            calls += 1
            input += c.input + c.cacheRead + c.cacheWrite
            output += c.output
            if let cost = c.cost { self.cost += cost } else { unpriced += 1 }
        }

        public var tokens: Int { input + output }
    }

    /// The periods totals are shown for.
    public enum Period: String, CaseIterable, Sendable {
        case session, day, week, month
        public var label: String {
            switch self {
            case .session: "This session"
            case .day: "Today"
            case .week: "This week"
            case .month: "This month"
            }
        }

        /// When the period began (the session from `sessionStart`).
        public func start(now: Date = Date(), sessionStart: Date, calendar: Calendar = .current) -> Date {
            switch self {
            case .session: return sessionStart
            case .day: return calendar.startOfDay(for: now)
            case .week: return calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? calendar.startOfDay(for: now)
            case .month: return calendar.dateInterval(of: .month, for: now)?.start ?? calendar.startOfDay(for: now)
            }
        }
    }

    static let kind = "aiUsage"

    static func day(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func recordId(device: String, day: String) -> String { "aiusage.\(device).\(day)" }

    /// "$0.0123" or "<$0.0001", "12p"-style is up to the app.
    public static func dollars(_ value: Double) -> String {
        if value == 0 { return "$0.00" }
        if value < 0.0001 { return "<$0.0001" }
        if value < 0.01 { return String(format: "$%.4f", value) }
        if value < 1 { return String(format: "$%.3f", value) }
        return String(format: "$%.2f", value)
    }

    /// "1.2k", "34k", "1.5M".
    public static func tokens(_ n: Int) -> String {
        if n < 1000 { return "\(n)" }
        if n < 10_000 { return String(format: "%.1fk", Double(n) / 1000) }
        if n < 1_000_000 { return "\(n / 1000)k" }
        return String(format: "%.1fM", Double(n) / 1_000_000)
    }
}

/// Prices per million tokens (US dollars), for working out what a request cost. Providers other
/// than Claude are priced only when the API says (OpenRouter's `usage.cost`).
public enum AIPrices {
    public struct Price: Sendable, Equatable {
        public var input: Double
        public var output: Double
    }

    /// Longest prefix first.
    static let table: [(prefix: String, price: Price)] = [
        ("claude-fable-5", Price(input: 10, output: 50)),
        ("claude-mythos-5", Price(input: 10, output: 50)),
        ("claude-opus-5-5", Price(input: 4, output: 20)),
        ("claude-opus-5", Price(input: 5, output: 25)),
        ("claude-opus-4", Price(input: 5, output: 25)),
        ("claude-sonnet-5", Price(input: 2, output: 10)),
        ("claude-sonnet-4", Price(input: 3, output: 15)),
        ("claude-haiku-5-5", Price(input: 0.10, output: 0.50)),
        ("claude-haiku-4", Price(input: 1, output: 5)),
    ]

    public static func price(_ model: String) -> Price? {
        let m = model.lowercased().replacingOccurrences(of: "anthropic/", with: "")
        return table.first { m.hasPrefix($0.prefix) }?.price
    }

    /// Cache reads cost a tenth of input, cache writes a quarter more. Haiku 5.5 prompts over 100K
    /// tokens cost five times as much.
    public static func cost(model: String, input: Int, output: Int, cacheRead: Int = 0, cacheWrite: Int = 0) -> Double? {
        guard var p = price(model) else { return nil }
        if model.lowercased().contains("haiku-5-5"), input + cacheRead + cacheWrite > 100_000 { p = Price(input: 0.5, output: 2.5) }
        let i = Double(input) * p.input + Double(cacheRead) * p.input * 0.1 + Double(cacheWrite) * p.input * 1.25
        return (i + Double(output) * p.output) / 1_000_000
    }
}

extension Library {
    /// Logs one request (on this device's record for today).
    public func recordAIUsage(_ call: AIUsage.Call) async {
        let device = await engine.device
        let day = AIUsage.day(call.at)
        let ms = Int64((call.at.timeIntervalSince1970 * 1000).rounded())
        let key = "log.\(ms)-\(Int.random(in: 1000...9999))"
        await engine.set(["device": .string(device), "day": .string(day), key: call.json],
                         record: AIUsage.recordId(device: device, day: day), kind: AIUsage.kind)
    }

    /// Every request since a moment, from every device, newest first.
    public func aiUsage(since: Date) async -> [AIUsage.Call] {
        let firstDay = AIUsage.day(since.addingTimeInterval(-86_400)) // time zones: a day of slack, filtered below
        var out: [AIUsage.Call] = []
        for r in await engine.records(kind: AIUsage.kind) {
            guard let day = r["day"]?.string, day >= firstDay else { continue }
            let device = r["device"]?.string ?? ""
            for (key, value) in r.fields where key.hasPrefix("log.") {
                if let call = AIUsage.Call(id: r.id + "/" + key, device: device, json: value), call.at >= since { out.append(call) }
            }
        }
        return out.sorted { $0.at > $1.at }
    }

    /// What background work (reading handwriting) has cost this calendar month, on every device.
    public func backgroundAISpend(now: Date = Date(), calendar: Calendar = .current) async -> Double {
        let start = AIUsage.Period.month.start(now: now, sessionStart: now, calendar: calendar)
        return AIUsage.Total(await aiUsage(since: start).filter(\.purpose.isBackground)).cost
    }
}
