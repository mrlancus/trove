import Foundation

/// Which of your own papers belong to a goal: the ones you picked, plus uploads whose name matches it
/// ("CCEA GCSE Physics Unit 1, June 2023" for a CCEA GCSE Physics goal), minus matches you turned off.
/// Names come from `PaperTitle`, so a match reads the same board, level and subject a person would.
public enum GoalUploads {
    /// What a goal is about: from each of its courses, or from its name when it has none (a CCEA or BPhO goal).
    public struct Target: Sendable, Equatable {
        public var board: String?
        public var subject: String?
        public var level: String?
        public init(board: String?, subject: String?, level: String?) { self.board = board; self.subject = subject; self.level = level }
    }

    /// "International GCSE" → "igcse", "GCSE" → "gcse", "AS"/"A-level"/"International AS & A Level" → "alevel".
    public static func level(_ qualification: String?) -> String? {
        guard let q = qualification?.lowercased(), !q.isEmpty else { return nil }
        if q.contains("igcse") || q.contains("international gcse") { return "igcse" }
        if q.contains("gcse") { return "gcse" }
        return "alevel"
    }

    /// Targets for a goal: one per course (board name, subject, qualification), else read from its name and notes.
    public static func targets(courses: [(board: String, subject: String, qualification: String)], goalText: String,
                               subjects: [String] = PaperTitle.commonSubjects) -> [Target] {
        if !courses.isEmpty { return courses.map { Target(board: $0.board, subject: $0.subject, level: level($0.qualification)) } }
        let g = PaperTitle.guess(text: goalText, subjects: subjects)
        guard g.board != nil || g.subject != nil else { return [] }  // "my mocks": nothing to match on
        // "BPhO round 1" names the organiser, not one paper: match all of its papers.
        let event = g.event?.hasPrefix("Round") == true ? nil : g.event
        return [Target(board: g.board, subject: event ?? g.subject, level: level(g.qualification))]
    }

    /// An upload's name fits a target: nothing it says contradicts it (board, level, subject) and it shares
    /// at least the subject or, for a competition, the board.
    public static func matches(_ title: String, _ t: Target, subjects: [String] = PaperTitle.commonSubjects) -> Bool {
        let g = PaperTitle.guess(text: title, subjects: subjects + [t.subject].compactMap { $0 })
        if let a = g.board, let b = t.board, !sameBoard(a, b) { return false }
        if let a = level(g.qualification), let b = t.level, a != b { return false }
        let subject = g.event ?? g.subject
        if let a = subject?.lowercased(), let b = t.subject?.lowercased() {
            return a == b || a.contains(b) || b.contains(a)
        }
        // No subject on one side: a competition's papers match on its organiser (BPhO, UKMT).
        if t.subject == nil, let a = g.board, let b = t.board { return sameBoard(a, b) }
        return false
    }

    /// "Cambridge" (as a paper prints it) is the catalogue's "Cambridge International".
    static func sameBoard(_ a: String, _ b: String) -> Bool {
        let x = a.lowercased(), y = b.lowercased()
        return x == y || x.hasPrefix(y) || y.hasPrefix(x)
    }

    /// The uploads a goal practises from: picked ∪ (matching − turned off), among uploads that exist.
    public static func effective(picked: [String], excluded: [String], uploads: [(id: String, title: String)], targets: [Target],
                                 subjects: [String] = PaperTitle.commonSubjects) -> [String] {
        let off = Set(excluded), mine = Set(picked)
        return uploads.filter { u in
            mine.contains(u.id) || !off.contains(u.id) && targets.contains { matches(u.title, $0, subjects: subjects) }
        }.map(\.id)
    }

    /// The ones that matched by name (not picked), to show as "Matches this goal".
    public static func automatic(uploads: [(id: String, title: String)], targets: [Target], subjects: [String] = PaperTitle.commonSubjects) -> Set<String> {
        Set(uploads.filter { u in targets.contains { matches(u.title, $0, subjects: subjects) } }.map(\.id))
    }
}
