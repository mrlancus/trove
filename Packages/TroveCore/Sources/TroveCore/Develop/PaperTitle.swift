import Foundation

/// A name for a paper you upload, read from the paper itself: its first page, the PDF's own title and the
/// file name, plus where it came from (a board's website in the in-app browser). "CCEA GCSE Physics Unit 1
/// Foundation, June 2023" rather than "GPH11_QP_S23.pdf". Board names are always spelled the board's own
/// way ("Pearson Edexcel", "CCEA", "OCR"), and the on-device model, when it tidies a suggestion, can't
/// change them (`keepsBoard`). Catalogue papers never come here: their names are the board's listing.
public enum PaperTitle {
    public struct Guess: Sendable, Equatable {
        public var board: String?
        public var qualification: String?
        public var subject: String?
        public var paper: String?
        public var tier: String?
        public var series: String?
        public var year: Int?
        /// "Mark scheme", "Examiner report", "Insert"; nil for a question paper.
        public var kind: String?
        /// A competition's own name ("Senior Mathematical Challenge").
        public var event: String?

        /// Enough to name the paper by what it is, not by its file name.
        public var isConfident: Bool {
            event != nil || board != nil && (subject != nil || paper != nil) || subject != nil && qualification != nil && year != nil
        }

        public var title: String {
            var head: [String] = []
            if let board { head.append(board) }
            if let event { head.append(event) } else {
                if let qualification { head.append(qualification) }
                if let subject { head.append(subject) }
                if let paper { head.append(paper) }
                if let tier { head.append(tier) }
            }
            var s = head.joined(separator: " ")
            let when = [series, year.map(String.init)].compactMap { $0 }.joined(separator: " ")
            if !when.isEmpty { s += s.isEmpty ? when : ", " + when }
            if let kind { s += s.isEmpty ? kind : " (\(kind.lowercased()))" }
            return s
        }
    }

    /// Boards and competitions by how they print their name, most specific first, with the name Trove uses.
    static let boards: [(pattern: String, name: String)] = [
        (#"Pearson\s+Edexcel|\bEdexcel\b"#, "Pearson Edexcel"),
        (#"\bWJEC\s+Eduqas\b|\bEduqas\b"#, "Eduqas"),
        (#"\bWJEC\b|\bCBAC\b"#, "WJEC"),
        (#"\bCCEA\b|Council for the Curriculum,? Examinations"#, "CCEA"),
        (#"\bAQA\b"#, "AQA"),
        (#"\bOCR\b|Oxford Cambridge and RSA"#, "OCR"),
        (#"Cambridge\s+(?:Assessment\s+)?International|\bCAIE\b|\bCIE\b|Cambridge\s+IGCSE"#, "Cambridge"),
        (#"\bUKMT\b|United Kingdom Mathematics Trust"#, "UKMT"),
        (#"\bBPhO\b|British Physics Olympiad"#, "BPhO"),
    ]
    /// The board a website belongs to, for papers saved from the in-app browser.
    static let hosts: [(suffix: String, name: String)] = [
        ("ccea.org.uk", "CCEA"), ("pearson.com", "Pearson Edexcel"), ("aqa.org.uk", "AQA"), ("ocr.org.uk", "OCR"),
        ("eduqas.co.uk", "Eduqas"), ("wjec.co.uk", "WJEC"), ("cambridgeinternational.org", "Cambridge"),
        ("ukmt.org.uk", "UKMT"), ("bpho.org.uk", "BPhO"),
    ]
    static let events = #"(?:Junior|Intermediate|Senior) Mathematical (?:Challenge|Olympiad)|(?:Junior|Intermediate|Senior) Kangaroo|"#
        + #"British Mathematical Olympiad,? Round \d|Mathematical Olympiad for Girls|Physics Olympiad,? Round \d|"#
        + #"(?:Junior|Intermediate|Senior) Physics Challenge|A-?Level Physics Challenge|GCSE Physics Challenge|Round \d"#
    /// Subjects to look for when the catalogue's own list isn't to hand.
    public static let commonSubjects = ["Physics", "Chemistry", "Biology", "Combined Science", "Science", "Mathematics", "Further Mathematics",
                                        "Statistics", "Computer Science", "English Language", "English Literature", "History", "Geography",
                                        "Economics", "Business", "Psychology", "Sociology", "Religious Studies", "French", "German", "Spanish",
                                        "Music", "Art and Design", "Design and Technology", "Physical Education", "Politics", "Accounting"]

    /// Reads what it can. `text` is the first page or two; `subjects` the catalogue's subject names.
    public static func guess(text: String, pdfTitle: String? = nil, fileName: String = "", source: URL? = nil,
                             subjects: [String] = commonSubjects) -> Guess {
        let hay = [pdfTitle ?? "", String(text.prefix(4_000))].joined(separator: "\n")
        let all = hay + "\n" + spaced(fileName)
        var g = Guess()
        if let host = source?.host?.lowercased(), let b = hosts.first(where: { host == $0.suffix || host.hasSuffix("." + $0.suffix) }) {
            g.board = b.name
        }
        if g.board == nil { g.board = first(boards.map { ($0.pattern, $0.name) }, in: all) }
        g.event = match(events, in: hay).map { titleCase($0) }
        if g.event == "Round 1" || g.event?.hasPrefix("Round") == true {  // a bare "Round 2" names an event only for BPhO/UKMT
            g.event = g.board == "BPhO" || g.board == "UKMT" ? g.event : nil
        }
        g.qualification = qualification(in: all)
        g.subject = subject(in: hay, subjects: subjects) ?? subject(in: spaced(fileName), subjects: subjects)
        if let p = match(#"\b(?:Paper|Unit|Component|Module)\s+(?:(?:AS|A2)\s*)?\d{1,2}[A-Z]{0,2}\b"#, in: hay) {
            let words = p.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).split(separator: " ")
            g.paper = ([titleCase(String(words[0]))] + words.dropFirst().map { $0.uppercased() }).joined(separator: " ")  // "PAPER 1H" → "Paper 1H"
        }
        if let t = match(#"\b(Foundation|Higher)\s+Tier\b"#, in: all) { g.tier = titleCase(t.components(separatedBy: " ")[0]) }
        if let (series, year) = when(in: hay) ?? when(in: spaced(fileName)) { g.series = series; g.year = year }
        if g.year == nil, let y = match(#"\b20[0-3]\d\b"#, in: g.event != nil ? hay : ""), let n = Int(y) { g.year = n }
        g.kind = kind(in: hay + "\n" + spaced(fileName), fileName: fileName)
        return g
    }

    /// The name to offer: a confident guess, else the PDF's own title if it's a real one, else a tidied file name.
    public static func suggest(text: String, pdfTitle: String? = nil, fileName: String, source: URL? = nil,
                               subjects: [String] = commonSubjects) -> String {
        let g = guess(text: text, pdfTitle: pdfTitle, fileName: fileName, source: source, subjects: subjects)
        if g.isConfident { return g.title }
        if let t = pdfTitle?.trimmingCharacters(in: .whitespacesAndNewlines), isRealTitle(t) { return t }
        return tidy(fileName)
    }

    /// The model's tidier version is used only if it kept the board exactly as Trove spells it, and is a
    /// sensible length; otherwise the suggestion stands.
    public static func keepsBoard(_ refined: String, of guess: Guess) -> Bool {
        let r = refined.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (4...120).contains(r.count), !r.contains("\n") else { return false }
        guard let board = guess.board else { return true }
        let others = boards.map(\.name).filter { $0 != board && !board.contains($0) }
        return r.contains(board) && !others.contains { r.range(of: #"\b"# + NSRegularExpression.escapedPattern(for: $0) + #"\b"#, options: .regularExpression) != nil }
    }

    /// "GPH11_QP-S23.pdf" → "GPH11 QP S23"; "physics paper 1.pdf" → "Physics paper 1".
    public static func tidy(_ fileName: String) -> String {
        var s = (fileName as NSString).deletingPathExtension
        s = s.replacingOccurrences(of: #"[_]+|(?<=\S)-(?=\S)|\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        guard let f = s.first else { return "Paper" }
        return f.uppercased() + s.dropFirst()
    }

    static func isRealTitle(_ t: String) -> Bool {
        guard t.count >= 6, t.count <= 120 else { return false }
        let junk = #"^(Microsoft (Word|PowerPoint)|untitled|document\d*|Slide \d|Print|Scan|PDF|Adobe|\d+$)|\.(docx?|pptx?|indd|pdf|tex|qxd)$|^[A-Z0-9_\-]+$"#
        return t.range(of: junk, options: [.regularExpression, .caseInsensitive]) == nil
    }

    // MARK: Pieces

    static func spaced(_ fileName: String) -> String {
        (fileName as NSString).deletingPathExtension.replacingOccurrences(of: #"[_\-.]+"#, with: " ", options: .regularExpression)
    }

    static func match(_ pattern: String, in text: String, caseInsensitive: Bool = true) -> String? {
        guard let r = text.range(of: pattern, options: caseInsensitive ? [.regularExpression, .caseInsensitive] : [.regularExpression]) else { return nil }
        return String(text[r])
    }

    /// The pattern that appears earliest wins (the board printed in the header, not one named in a question).
    static func first(_ options: [(String, String)], in text: String, caseInsensitive: Bool = true) -> String? {
        var best: (String.Index, String)?
        for (pattern, name) in options {
            if let r = text.range(of: pattern, options: caseInsensitive ? [.regularExpression, .caseInsensitive] : [.regularExpression]),
               best == nil || r.lowerBound < best!.0 {
                best = (r.lowerBound, name)
            }
        }
        return best?.1
    }

    static func qualification(in text: String) -> String? {
        let ordered: [(String, String)] = [
            (#"International\s+GCSE"#, "International GCSE"), (#"\bIGCSE\b"#, "IGCSE"),
            (#"International\s+Advanced\s+(?:Subsidiary|Level)|International\s+A[\s-]?Level|\bIAL\b"#, "International A Level"),
            (#"Cambridge\s+International\s+AS\s*(?:&|and)\s*A\s*Level"#, "International AS & A Level"),
            (#"(?i:Advanced\s+Subsidiary)|\bAS\s+(?i:Level)\b|\bGCE\s+AS\b|\bAS\s+\d\b|\(AS\)"#, "AS"),
            (#"\b(?i:A[\s-]?Level)\b|(?i:Advanced\s+Level)|\bGCE\b|\bA2\b"#, "A-level"),
            (#"\bGCSE\b"#, "GCSE"),
        ]
        return first(ordered, in: text, caseInsensitive: false)
    }

    static func subject(in text: String, subjects: [String]) -> String? {
        var best: (String.Index, Int, String)?
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        for s in Set(subjects) where s.count >= 3 {
            // A plain search first (cheap); the word-boundary check only for subjects actually there.
            let first = s.split(separator: " ").first.map(String.init) ?? s
            guard folded.range(of: first, options: [.caseInsensitive, .diacriticInsensitive]) != nil else { continue }
            let pattern = #"\b"# + NSRegularExpression.escapedPattern(for: s).replacingOccurrences(of: " ", with: #"\s+"#) + #"\b"#
            guard let r = text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else { continue }
            // Earliest wins; at the same place the longer name ("Further Mathematics" over "Mathematics").
            if best == nil || r.lowerBound < best!.0 || r.lowerBound == best!.0 && s.count > best!.1 { best = (r.lowerBound, s.count, s) }
        }
        return best?.2
    }

    static let months = ["january": "January", "february": "February", "march": "March", "april": "April", "may": "May", "june": "June",
                         "july": "July", "october": "October", "november": "November", "summer": "Summer", "autumn": "Autumn",
                         "winter": "Winter", "spring": "Spring"]

    /// "June 2023", "Summer Series 2023", "May/June 2022", or a file's "S23"/"jun23".
    static func when(in text: String) -> (String, Int)? {
        let long = #"\b(January|February|March|April|May|June|July|October|November|Summer|Autumn|Winter|Spring)(?:\s*/\s*\w+)?\s+(?:Series\s+|Examination\s+|Exam\s+)?(20\d\d)\b"#
        if let r = try? NSRegularExpression(pattern: long, options: [.caseInsensitive]),
           let m = r.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let a = Range(m.range(at: 1), in: text), let b = Range(m.range(at: 2), in: text), let y = Int(text[b]) {
            return (months[text[a].lowercased()] ?? String(text[a]), y)
        }
        let short = #"\b(?:(jan|jun|nov|oct|may)|([swm]))[\s]?(\d\d)\b"#
        if let r = try? NSRegularExpression(pattern: short, options: [.caseInsensitive]),
           let m = r.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let yr = Range(m.range(at: 3), in: text), let y = Int(text[yr]), y >= 8, y <= 39 {
            let word = Range(m.range(at: 1), in: text).map { text[$0].lowercased() } ?? Range(m.range(at: 2), in: text).map { text[$0].lowercased() } ?? ""
            let name = ["jan": "January", "jun": "June", "nov": "November", "oct": "October", "may": "May", "s": "Summer", "w": "Winter", "m": "March"][word]
            if let name { return (name, 2000 + y) }
        }
        return nil
    }

    static func kind(in text: String, fileName: String) -> String? {
        // A file's "_ms_" or "-MS" means mark scheme; in text "ms" is milliseconds.
        if spaced(fileName).range(of: #"(?:^|\s)(?:ms|MS|rms|msc)(?:\s|$)"#, options: .regularExpression) != nil { return "Mark scheme" }
        if spaced(fileName).range(of: #"(?:^|\s)(?:er|ER|pef)(?:\s|$)"#, options: .regularExpression) != nil { return "Examiner report" }
        return first([(#"\bMark\s+Scheme\b|\bMarking\s+Scheme\b|\bmark[\s_-]?scheme\b"#, "Mark scheme"),
               (#"(?:Principal|Chief)\s+Examiner|Examiners?['’]?\s+Report|Report\s+on\s+the\s+Examination"#, "Examiner report"),
               (#"\bInsert\b|\bSource\s+Booklet\b|\bResource\s+Booklet\b|\bData\s+Sheet\b"#, "Insert")], in: text)
    }

    static func titleCase(_ s: String) -> String {
        s.split(separator: " ").map { w in
            let lower = w.lowercased()
            if ["for", "of", "and"].contains(lower) { return lower }
            return lower.prefix(1).uppercased() + lower.dropFirst()
        }.joined(separator: " ").replacingOccurrences(of: "A-level", with: "A-Level")
    }
}
