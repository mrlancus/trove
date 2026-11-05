import Foundation

/// How candidates did on each question, as an examiner report says it (study-with-friends prompt §1, the national
/// cohort): after marking, Learn shows the report's own sentence next to your score. Only what the report prints:
/// "Just over 60% of the students scored 3 marks", "More than half of students obtained both marks", "The mean
/// mark was 2.8". Nothing is averaged, estimated or invented, and a question the report gives no figure for gets
/// none. Read on the device from the downloaded report; nothing is shared and no AI is used.
///
/// What the boards print (checked on real 2024–25 reports): AQA gives per-question percentages in almost every
/// part ("01.4 … fewer than 10 % of the students scoring 2 marks"); OCR, Pearson and Cambridge mostly write
/// prose with no figures, so their questions usually say "no figure".
public enum ExaminerReport {
    /// Question key ("1.2", "3.1.2" for 3(a)(ii), as `PaperSplitter` keys questions) → the report's sentences
    /// with a figure for it, in the order printed.
    public static func figures(_ lines: [String]) -> [String: [String]] {
        var out: [String: [String]] = [:]
        var current: String? // the question whose section we're in
        var paragraph: [String] = []
        var paragraphKey: String?

        func flush() {
            defer { paragraph = []; paragraphKey = nil }
            guard !paragraph.isEmpty else { return }
            var lastRef: String?
            for sentence in sentences(paragraph.joined(separator: " ")) {
                let refs = references(sentence)
                if refs.count == 1 { lastRef = refs[0] }
                guard hasFigure(sentence) else { continue }
                let quote = tidy(sentence)
                var keys: [String]
                if refs.count > 1 {
                    // "Question 09.2 had …, while question 10.1 had almost 60 % …": each question named gets the
                    // sentence only if its own part of it carries a figure.
                    keys = parts(sentence).filter { hasFigure($0.text) }.map(\.key)
                } else if let only = refs.first {
                    keys = [only]
                } else if let key = (sentence.range(of: "this question", options: .caseInsensitive) != nil ? lastRef : nil) ?? paragraphKey {
                    keys = [key]
                } else {
                    keys = []
                }
                for k in keys where !(out[k]?.contains(quote) ?? false) { out[k, default: []].append(quote) }
            }
        }

        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || isFurniture(line) { flush(); continue }
            if let h = heading(line) {
                flush()
                current = h.key
                paragraphKey = h.key
                // "Question 5.1 was answered correctly by …" is a heading and the start of its sentence.
                if !h.rest.isEmpty { paragraph.append(line) }
                continue
            }
            if isNewSection(line) {
                // "Section B" (multiple choice, named "B14" and the like): no longer the last question's.
                flush()
                current = nil
                continue
            }
            if paragraph.isEmpty { paragraphKey = current }
            paragraph.append(line)
        }
        flush()
        return out
    }

    // MARK: Figures

    /// A sentence states how candidates did: a percentage or fraction of the candidates, or a mean mark.
    static func hasFigure(_ s: String) -> Bool {
        let ns = s as NSString
        let all = NSRange(location: 0, length: ns.length)
        return [percent, percentDid, fraction, mean].contains { $0.firstMatch(in: s, range: all) != nil }
    }

    private static let who = #"(?:the\s+)?(?:students|candidates|entrants|responses|scripts)"#
    /// "60 % of the students", "nearly 70% of candidates".
    static let percent = try! NSRegularExpression(pattern: #"\b\d{1,3}(?:\.\d+)?\s?(?:%|per\s?cent)\s+of\s+"# + who, options: .caseInsensitive)
    /// "Over 20% gained all five marks", "57% of …", but not "rounded to 5% scored no marks".
    static let percentDid = try! NSRegularExpression(pattern: #"(?:^|\b(?:over|about|nearly|almost|around|approximately|only|under|than|further|and|while)\s+)\d{1,3}(?:\.\d+)?\s?%\s+(?:scored|gained|obtained|got|achieved|earned|received|answered)\b"#, options: .caseInsensitive)
    /// "More than half of students", "nearly three quarters of the students", "one in five candidates".
    static let fraction = try! NSRegularExpression(pattern: #"\b(?:half|a\s+third|two[\s-]thirds|a\s+quarter|three[\s-]quarters|one\s+in\s+(?:\d+|two|three|four|five|six|seven|eight|nine|ten))\s+(?:of\s+)?"# + who, options: .caseInsensitive)
    /// "The mean mark for this question was 2.8", "an average mark of 3.1 out of 6".
    static let mean = try! NSRegularExpression(pattern: #"\b(?:mean|average)\s+mark\b[^.%]{0,60}?\d+(?:\.\d+)?"#, options: .caseInsensitive)

    // MARK: Questions

    private static let romans = ["i": 1, "ii": 2, "iii": 3, "iv": 4, "v": 5, "vi": 6, "vii": 7, "viii": 8, "ix": 9, "x": 10]
    /// "01.1", "9.2", "1.3.2"; "3(a)(ii)", "3 (a)", "3a".
    private static let keyPattern = #"(\d{1,2})(?:\.(\d{1,2})(?:\.(\d{1,2}))?|\s?\(?([a-h])\)?(?:\s?\(([ivx]{1,4})\))?)?"#
    /// A line that is a question's heading: "01.1", "Question 2", "Question 1(b)(i)", "Q3 (a) Most candidates…".
    static let headingLine = try! NSRegularExpression(pattern: #"^(?:(?:Question|Q)\.?\s?"# + keyPattern + #"(?=\s|$|:)|"# + #"(\d{1,2})\.(\d{1,2})(?:\.(\d{1,2}))?$)"#)
    /// A question named in a sentence: "Question 1.1", "question 09.2", "Q4(b)", "in 1.3", "for 2.4".
    static let reference = try! NSRegularExpression(pattern: #"(?:\b[Qq]uestions?\s+|\bQ|\b(?:in|for|on)\s+(?=\d{1,2}\.\d))"# + keyPattern + #"(?![\d%])"#)

    static func key(_ n: String, _ dot: [String], letter: String, roman: String) -> String? {
        guard let q = Int(n), q > 0 else { return nil }
        var parts = [String(q)]
        let dots = dot.filter { !$0.isEmpty }.compactMap(Int.init)
        if !dots.isEmpty { parts += dots.map(String.init) }
        else if let l = letter.first?.asciiValue, letter.count == 1 {
            parts.append(String(Int(l) - 96))
            if let r = romans[roman] { parts.append(String(r)) }
        }
        return parts.joined(separator: ".")
    }

    private static func groups(_ m: NSTextCheckingResult, in ns: NSString) -> [String] {
        (0..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? "" : ns.substring(with: m.range(at: $0)) }
    }

    static func heading(_ line: String) -> (key: String, rest: String)? {
        let ns = line as NSString
        guard let m = headingLine.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let g = groups(m, in: ns)
        let k = g[1].isEmpty ? key(g[6], [g[7], g[8]], letter: "", roman: "") : key(g[1], [g[2], g[3]], letter: g[4], roman: g[5])
        guard let k else { return nil }
        let rest = ns.substring(from: m.range.location + m.range.length).trimmingCharacters(in: CharacterSet(charactersIn: " :–-"))
        return (k, rest)
    }

    /// The questions a sentence names, in order, each once.
    static func references(_ s: String) -> [String] {
        var seen: [String] = []
        for p in parts(s) where !seen.contains(p.key) { seen.append(p.key) }
        return seen
    }

    /// The sentence cut at each question it names: each piece is that question's.
    static func parts(_ s: String) -> [(key: String, text: String)] {
        let ns = s as NSString
        let ms = reference.matches(in: s, range: NSRange(location: 0, length: ns.length))
        var out: [(String, String)] = []
        for (i, m) in ms.enumerated() {
            let g = groups(m, in: ns)
            guard let k = key(g[1], [g[2], g[3]], letter: g[4], roman: g[5]) else { continue }
            let end = i + 1 < ms.count ? ms[i + 1].range.location : ns.length
            out.append((k, ns.substring(with: NSRange(location: m.range.location, length: end - m.range.location))))
        }
        return out
    }

    // MARK: Text

    /// Page furniture: "© 2025 AQA   3 of 11", "Report on the examination – GCSE – Physics – 8463/1H – June 2025".
    static func isFurniture(_ line: String) -> Bool {
        line.contains("©") || line.range(of: #"^\d+\s+of\s+\d+$|^Page\s+\d+|Report on the [Ee]xamination\s+[–-]"#, options: .regularExpression) != nil
    }

    /// "Section B", "Section A: multiple choice", "Multiple choice questions".
    static func isNewSection(_ line: String) -> Bool {
        line.range(of: #"^(?:Section\s+[A-Z1-9]\b|Multiple[\s-]choice(?:\s+questions)?$)"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func sentences(_ text: String) -> [String] {
        let ns = text as NSString
        let cut = try! NSRegularExpression(pattern: #"(?<=[.!?])\s+(?=[A-Z“"‘'(])"#)
        var out: [String] = []
        var start = 0
        for m in cut.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out.append(ns.substring(with: NSRange(location: start, length: m.range.location - start)))
            start = m.range.location + m.range.length
        }
        out.append(ns.substring(from: start))
        return out.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// One line of plain text: spaces collapsed, "60 %" as "60%".
    static func tidy(_ s: String) -> String {
        s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"(\d)\s+%"#, with: "$1%", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }
}
