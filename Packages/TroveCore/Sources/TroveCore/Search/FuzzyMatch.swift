import Foundation

/// The quick switcher's matching (docs/MASTER_PLAN.md O1): the query's letters in order inside a
/// title, scored so whole-word starts, consecutive letters and short titles win ("phsyn" finds
/// "Photosynthesis"; "wk3" finds "Week 3 notes"). Case- and accent-insensitive.
public enum FuzzyMatch {
    /// nil when the letters aren't all there in order.
    public static func score(_ query: String, _ candidate: String) -> Double? {
        let q = Array(fold(query).filter { !$0.isWhitespace })
        guard !q.isEmpty else { return 0 }
        let c = Array(fold(candidate))
        var score = 0.0, qi = 0, previous = -2
        for (i, ch) in c.enumerated() where qi < q.count && ch == q[qi] {
            var s = 1.0
            if i == previous + 1 { s += 1.5 }                                   // consecutive
            if i == 0 || !(c[i - 1].isLetter || c[i - 1].isNumber) { s += 2 }    // start of a word
            score += s
            previous = i
            qi += 1
        }
        guard qi == q.count else { return nil }
        // Shorter titles and matches that start early rank higher.
        return score - Double(c.count) * 0.02
    }

    /// The best matches, highest first.
    public static func rank<T>(_ query: String, _ items: [T], limit: Int = 20, title: (T) -> String) -> [T] {
        if query.trimmingCharacters(in: .whitespaces).isEmpty { return Array(items.prefix(limit)) }
        return items.compactMap { item in score(query, title(item)).map { (item, $0) } }
            .sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }

    static func fold(_ s: String) -> String { s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
}
