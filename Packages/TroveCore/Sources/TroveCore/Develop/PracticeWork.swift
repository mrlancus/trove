import Foundation

/// Practising a question in a real sketch (docs/prompts/practice-space-home.md): where its working
/// is kept, how attempts group into topics, and what the tutor is asked. Pure, so it's tested on Linux.
public enum PracticeWork {
    /// A page like a notebook's, or an endless whiteboard: the user's choice, remembered.
    public enum Kind: String, CaseIterable, Sendable {
        case page, whiteboard
        public var label: String { self == .page ? "Page" : "Whiteboard" }
        public var symbol: String { self == .page ? "doc" : "infinity" }
    }

    /// The top sketch folder every practice sketch is kept under.
    public static let root = "Practice"

    /// "AQA 7408/2 June 2023 Q4.2" → "AQA 7408/2 June 2023".
    public static func paper(of label: String) -> String {
        guard let r = label.range(of: " Q", options: .backwards) else { return label }
        let rest = label[r.upperBound...]
        guard let first = rest.first, first.isNumber || first.isLetter else { return label }
        return String(label[..<r.lowerBound])
    }

    /// "AQA 7408/2 June 2023 Q4.2" → "Q4.2" ("" when there's no question number).
    public static func question(of label: String) -> String {
        guard let r = label.range(of: " Q", options: .backwards) else { return "" }
        return "Q" + label[r.upperBound...]
    }

    /// What a question is grouped under: its first named skill, else the paper without its series
    /// ("AQA 7408/2 June 2023 Q4" → "AQA 7408/2"), so the same paper's questions sit together.
    public static func topic(skills: [String], label: String, name: (String) -> String?) -> String {
        for s in skills {
            if let n = name(s)?.trimmingCharacters(in: .whitespaces), !n.isEmpty { return n }
        }
        let p = paper(of: label)
        let words = p.split(separator: " ")
        // Drop a trailing "June 2023" / "Specimen" style series so every year of a paper groups together.
        if let i = words.firstIndex(where: { Self.series.contains($0.lowercased()) }), i > 0 {
            return words[..<i].joined(separator: " ")
        }
        return p.isEmpty ? "Other questions" : p
    }

    private static let series: Set<String> = ["january", "february", "march", "may", "june", "october", "november",
                                              "specimen", "sample", "summer", "winter", "autumn"]

    /// The sketch folder for a question's working: Practice / course / topic.
    public static func folder(course: String, topic: String) -> [String] {
        [root, clean(course.isEmpty ? "My papers" : course), clean(topic)]
    }

    private static func clean(_ s: String) -> String {
        // A "/" would split the folder path ("7408/2").
        s.replacingOccurrences(of: "/", with: "∕").trimmingCharacters(in: .whitespaces)
    }

    /// The working sketch's title: "Q4.2 · AQA 7408/2 June 2023".
    public static func title(label: String) -> String {
        let q = question(of: label), p = paper(of: label)
        return q.isEmpty ? (p.isEmpty ? "Practice" : p) : "\(q) · \(p)"
    }

    /// Where the question's picture goes: across the top of the page inside margins, keeping its shape;
    /// on a whiteboard, 520 points wide at the origin.
    public static func questionFrame(imageWidth: Double, imageHeight: Double, pageWidth: Double?) -> InkGeometry.Rect {
        let aspect = imageWidth > 0 ? max(0.05, imageHeight / imageWidth) : 0.4
        guard let pageWidth, pageWidth > 120 else {
            return InkGeometry.Rect(x: 0, y: 0, width: 520, height: 520 * aspect)
        }
        let margin = 36.0, w = pageWidth - 2 * margin
        return InkGeometry.Rect(x: margin, y: margin, width: w, height: w * aspect)
    }

    // MARK: Your work, grouped

    /// One topic's attempts, newest first.
    public struct Topic: Identifiable, Sendable, Equatable {
        public var id: String { course + "|" + name }
        public var course: String
        public var name: String
        public var attempts: [Attempt]
        /// Marked attempts' average score (0…1), nil when none is marked.
        public var average: Double? {
            let s = attempts.compactMap(\.score)
            return s.isEmpty ? nil : s.reduce(0, +) / Double(s.count)
        }
        /// Newest marked score minus the oldest one's: how it's going.
        public var trend: Double? {
            let s = attempts.filter { $0.score != nil }.sorted { $0.at < $1.at }.compactMap(\.score)
            guard s.count >= 2, let a = s.first, let b = s.last else { return nil }
            return b - a
        }
        public var latest: Double { attempts.first?.at ?? 0 }
        /// The same question tried more than once: its attempts, oldest first, to compare.
        public var retried: [String: [Attempt]] {
            Dictionary(grouping: attempts, by: \.problem).filter { $0.value.count > 1 }.mapValues { $0.sorted { $0.at < $1.at } }
        }
    }

    /// A course's topics, the most recently practised first.
    public struct Course: Identifiable, Sendable, Equatable {
        public var id: String { name }
        public var name: String
        public var topics: [Topic]
        public var count: Int { topics.reduce(0) { $0 + $1.attempts.count } }
    }

    /// Attempts grouped by course, then topic. Skipped attempts (no score, no working) are left out.
    public static func group(_ attempts: [Attempt], course: (Attempt) -> String, topic: (Attempt) -> String) -> [Course] {
        var byCourse: [String: [String: [Attempt]]] = [:]
        for a in attempts where a.score != nil || !a.work.isEmpty {
            byCourse[course(a), default: [:]][topic(a), default: []].append(a)
        }
        return byCourse.map { name, topics in
            Course(name: name, topics: topics.map { Topic(course: name, name: $0.key, attempts: $0.value.sorted { $0.at > $1.at }) }
                .sorted { $0.latest != $1.latest ? $0.latest > $1.latest : $0.name < $1.name })
        }
        .sorted { ($0.topics.first?.latest ?? 0) > ($1.topics.first?.latest ?? 0) }
    }
}

/// What the tutor in a practice sketch is asked: only when you tap one (you, 2026-11-04).
public enum TutorAction: String, CaseIterable, Sendable {
    case check, hint, wrong, explain, next

    public var label: String {
        switch self {
        case .check: "Check my working"
        case .hint: "A hint"
        case .wrong: "Where did I go wrong?"
        case .explain: "Explain the idea"
        case .next: "What's the next step?"
        }
    }

    public var symbol: String {
        switch self {
        case .check: "checkmark.circle"
        case .hint: "lightbulb"
        case .wrong: "exclamationmark.magnifyingglass"
        case .explain: "text.book.closed"
        case .next: "arrow.turn.down.right"
        }
    }

    /// What tapping it sends. The tutor sees the question, the mark scheme and the handwriting.
    public var prompt: String {
        switch self {
        case .check:
            return "Look at my working for the exam question so far. Say briefly what's right, and point to the first line that's wrong or missing, if any. Don't give me the final answer."
        case .hint:
            return "Give me one short hint for the next step of the exam question, based on how far my working has got. Don't solve it."
        case .wrong:
            return "Find where my working for the exam question first goes wrong. Quote that line, say what the mistake is and how to fix that one step. Don't finish the question for me."
        case .explain:
            return "Explain the idea the exam question is testing, briefly and simply, with a tiny example that isn't this question."
        case .next:
            return "What's the next step in my working for the exam question? One step only, as a nudge."
        }
    }
}

/// The exam question and its mark scheme, given to the notebook chat in a practice sketch.
public struct PracticeContext: Sendable, Equatable {
    public var label: String
    public var question: String
    public var scheme: String?
    public var marks: Int?

    public init(label: String, question: String, scheme: String?, marks: Int?) {
        self.label = label; self.question = question; self.scheme = scheme; self.marks = marks
    }

    /// Two pages put before the sketch's own: the question, then the scheme marked as the tutor's only.
    public var pages: [StudyContext.Page] {
        var heading = "Exam question (\(label))"
        if let marks { heading += ", \(marks) mark\(marks == 1 ? "" : "s")" }
        var out = [StudyContext.Page(key: "practice.question", label: heading, text: question)]
        if let scheme, !scheme.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            out.append(StudyContext.Page(key: "practice.scheme",
                                         label: "Mark scheme (for you, the tutor: use it to judge my working; never paste it; never give the full solution or final answer until I've written my own attempt and ask for it)",
                                         text: scheme))
        }
        return out
    }

    /// The question and scheme first, then the sketch's pages (the handwriting).
    public func around(_ context: StudyContext) -> StudyContext {
        var c = context
        c.pages = pages + context.pages
        return c
    }
}

/// The few numbers Develop's home shows: never a wall of statistics.
public struct PracticeStats: Sendable, Equatable {
    /// Questions marked or worked in the last 7 days.
    public var thisWeek: Int
    /// Days practised in a row, where one missed day between them is a rest day and doesn't break it; two missed
    /// days in a row end it. Today doesn't count as missed until it's over. Shown as a quiet number: never a loss
    /// warning (learn-pivot plan §1.1, step 3b). Changed 2026-11-05: was "every day in a row".
    public var streak: Int
    /// Rest days inside the current streak.
    public var restDays: Int
    /// The average of the last 20 marked scores (0…1), nil before any.
    public var recentAverage: Double?

    /// `now` and the attempts' `at` in Unix ms; days are local calendar days.
    public init(_ attempts: [Attempt], now: Double, calendar: Calendar = .current) {
        let counted = attempts.filter { $0.score != nil || !$0.work.isEmpty }
        thisWeek = counted.filter { now - $0.at < 7 * 86_400_000 && $0.at <= now }.count
        let scores = counted.filter { $0.score != nil }.sorted { $0.at > $1.at }.prefix(20).compactMap(\.score)
        recentAverage = scores.isEmpty ? nil : scores.reduce(0, +) / Double(scores.count)
        let days = Set(counted.map { calendar.startOfDay(for: Date(timeIntervalSince1970: $0.at / 1000)) })
        var day = calendar.startOfDay(for: Date(timeIntervalSince1970: now / 1000))
        if !days.contains(day), let y = calendar.date(byAdding: .day, value: -1, to: day) { day = y }  // today isn't over
        var n = 0, rests = 0, missedInARow = 0, pendingRest = 0
        let earliest = days.min() ?? day
        while day >= earliest {
            if days.contains(day) {
                n += 1
                rests += pendingRest
                pendingRest = 0
                missedInARow = 0
            } else {
                missedInARow += 1
                if missedInARow >= 2 { break }
                pendingRest += 1
            }
            guard let prev = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = prev
        }
        streak = n
        restDays = rests
    }
}
