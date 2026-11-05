import Foundation

/// Develop's records (docs/DEVELOP_PLAN.md §C1, PROTOCOL.md §13): concepts and skills, typed edges
/// between any two records, problems and attempts (the evidence), and specifications. Mastery is
/// never stored: `Mastery.evaluate` derives it from attempts on each device.
public enum Develop {
    public static let conceptKind = "concept", edgeKind = "edge", problemKind = "problem", attemptKind = "attempt", specKind = "spec"

    /// NFKD, combining marks dropped, lowercase; every run of characters other than a–z and 0–9
    /// becomes "-", trimmed, at most 64 characters (PROTOCOL.md §13).
    public static func slug(_ name: String) -> String {
        let folded = name.decomposedStringWithCompatibilityMapping.unicodeScalars
            .filter { !$0.properties.isDiacritic && $0.properties.generalCategory != .nonspacingMark }
        var out = ""
        var dash = false
        for s in String(String.UnicodeScalarView(folded)).lowercased().unicodeScalars {
            if ("a"..."z").contains(s) || ("0"..."9").contains(s) {
                if dash, !out.isEmpty { out.append("-") }
                dash = false
                out.unicodeScalars.append(s)
            } else {
                dash = true
            }
        }
        return String(out.prefix(64)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    public static func sha12(_ s: String) -> String { String(s.sha256Hex.prefix(12)) }

    public static func conceptId(_ name: String) -> String { "concept.\(slug(name))" }
    public static func edgeId(from: String, type: EdgeType, to: String) -> String {
        let (a, b) = type.isSymmetric ? (min(from, to), max(from, to)) : (from, to)
        return "edge.\(sha12("\(a)\n\(type.rawValue)\n\(b)"))"
    }
    public static func problemId(sourceKey: String, key: String) -> String { "problem.\(sha12("\(sourceKey)\n\(key)"))" }
    public static func specId(board: String, code: String, version: String) -> String { "spec.\(slug("\(board) \(code) \(version)"))" }
}

public enum ConceptType: String, Sendable, Codable { case concept, skill }
public enum DevelopOrigin: String, Sendable, Codable { case user, ai, rule, spec }

public enum EdgeType: String, Sendable, Codable, CaseIterable {
    case about, tests, requires, partOf, confusedWith, madeFrom, gap, related, inSpec
    public var isSymmetric: Bool { self == .confusedWith || self == .related }
}

public enum EdgeState: String, Sendable, Codable { case suggested, accepted, rejected }

public enum Marking: String, Sendable, Codable, CaseIterable {
    /// Ticked against the mark scheme by me.
    case selfMarked = "self"
    case aiScheme, aiNoScheme
    /// A friend's marks against the mark scheme that I accepted (study groups, PROTOCOL.md §4).
    case peer
    case none
}

public enum ProblemLevel: String, Sendable, Codable { case gcse, igcse, alevel, competition, university, other }

public struct Concept: Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var type: ConceptType
    public var aliases: [String]
    public var mergedInto: String?
    public var origin: DevelopOrigin
    public var summary: String?

    public init(_ r: Record) {
        id = r.id
        name = r.fields["name"]?.string ?? ""
        type = ConceptType(rawValue: r.fields["type"]?.string ?? "") ?? .concept
        aliases = r.fields["aliases"]?.stringArray ?? []
        mergedInto = r.fields["mergedInto"]?.string
        origin = DevelopOrigin(rawValue: r.fields["origin"]?.string ?? "") ?? .user
        summary = r.fields["summary"]?.string
    }
}

public struct Edge: Sendable, Equatable, Identifiable {
    public var id: String
    public var from: String
    public var to: String
    public var type: EdgeType
    public var state: EdgeState
    public var origin: DevelopOrigin
    public var confidence: Double?
    public var why: String?

    public init?(_ r: Record) {
        guard let from = r.fields["from"]?.string, let to = r.fields["to"]?.string,
              let type = EdgeType(rawValue: r.fields["type"]?.string ?? "") else { return nil }
        id = r.id
        self.from = from
        self.to = to
        self.type = type
        state = EdgeState(rawValue: r.fields["state"]?.string ?? "") ?? .suggested
        origin = DevelopOrigin(rawValue: r.fields["origin"]?.string ?? "") ?? .user
        confidence = r.fields["confidence"]?.number
        why = r.fields["why"]?.string
    }
}

/// Where a problem's page region is: page 0-based, rect [x, y, w, h] in PDF points, origin top-left.
public struct PageRegion: Sendable, Equatable, Codable {
    public var page: Int
    public var rect: [Double]
    public init(page: Int, rect: [Double]) { self.page = page; self.rect = rect }
    var json: JSONValue { ["page": .number(Double(page)), "rect": .array(rect.map(JSONValue.number))] }
    init?(json: JSONValue) {
        guard let o = json.object, let p = o["page"]?.number, let r = o["rect"]?.array?.compactMap(\.number), r.count == 4 else { return nil }
        page = Int(p)
        rect = r
    }
}

/// Kinds of practice that aren't exam questions (learn-pivot plan §C3; the field is `format`, not `kind`: review R5).
/// Older builds don't know the field and treat every problem as written.
public enum PracticeFormat: String, Sendable, Codable, CaseIterable {
    /// An exam-style question, written out and marked (the default).
    case written
    /// "Explain X" in your own words, self-marked against key points (or by AI on a tap).
    case recall
    /// Something done away from the app (a scale on the piano, a speaking drill): a timer and a 1–4 rating.
    case rated
    /// Said aloud, written down on the device, checked against the answer.
    case spoken

    public var label: String {
        switch self {
        case .written: "Written question"
        case .recall: "Explain in your own words"
        case .rated: "Do it and rate it"
        case .spoken: "Say it aloud"
        }
    }

    /// A 1–4 rating ("Again", "Hard", "Good", "Easy" in spirit) as a score; rated practice counts as self-marked
    /// evidence, like any self-marked attempt.
    public static func score(rating: Int) -> Double { Double(min(max(rating, 1), 4) - 1) / 3 }
    public static let ratings = ["Couldn't yet", "Shaky", "Mostly", "Nailed it"]
}

public struct Problem: Sendable, Equatable, Identifiable {
    public var id: String
    /// `cat:<doc id>` or `item:<item id>`.
    public var sourceKey: String
    public var key: String
    public var parent: String?
    public var pages: [PageRegion]
    public var marks: Int?
    public var level: ProblemLevel
    public var nationalAverage: Double?
    public var splitBy: String
    public var label: String
    public var skills: [String]
    /// The `PaperSplitter.version` that made its regions (1 before versions were kept).
    public var splitVersion: Int
    /// What kind of practice it is; missing means written.
    public var format: PracticeFormat

    public init(_ r: Record) {
        id = r.id
        let source = r.fields["source"]?.object
        if let doc = source?["catalogue"]?.string { sourceKey = "cat:\(doc)" } else { sourceKey = "item:\(source?["item"]?.string ?? "")" }
        key = r.fields["key"]?.string ?? ""
        parent = r.fields["parent"]?.string
        pages = (r.fields["pages"]?.array ?? []).compactMap(PageRegion.init(json:))
        marks = r.fields["marks"]?.number.map { Int($0) }
        level = ProblemLevel(rawValue: r.fields["level"]?.string ?? "") ?? .other
        nationalAverage = r.fields["nationalAverage"]?.number
        splitBy = r.fields["splitBy"]?.string ?? "auto"
        splitVersion = Int(r.fields["splitV"]?.number ?? 1)
        label = r.fields["label"]?.string ?? ""
        skills = r.fields["skills"]?.stringArray ?? []
        format = PracticeFormat(rawValue: r.fields["format"]?.string ?? "") ?? .written
    }
}

public struct Attempt: Sendable, Equatable, Identifiable {
    public var id: String
    public var problem: String
    public var skills: [String]
    /// Unix ms.
    public var at: Double
    public var hint: Int
    public var marking: Marking
    /// 0…1, nil when not marked.
    public var score: Double?
    public var uncertain: Bool
    /// The difficulty used when it was recorded.
    public var b: Double
    public var sourceKey: String
    public var label: String
    /// The sketch the working was written in (an item id), "" for none (PROTOCOL.md §13).
    public var work: String
    /// When the full solution or mark scheme was shown (Unix ms), nil if it wasn't (learn-pivot plan §1.1: the
    /// tutor holds the answer back until you've tried; a mark made after seeing it is weaker evidence).
    public var solutionShownAt: Double?
    /// Whether the solution was shown before you'd written anything (`shownBeforeTrying`).
    public var shownBeforeTrying: Bool

    public init(id: String, problem: String, skills: [String], at: Double, hint: Int, marking: Marking, score: Double?,
                uncertain: Bool = false, b: Double, sourceKey: String, label: String = "", work: String = "",
                solutionShownAt: Double? = nil, shownBeforeTrying: Bool = false) {
        self.id = id; self.problem = problem; self.skills = skills; self.at = at; self.hint = hint; self.marking = marking
        self.score = score; self.uncertain = uncertain; self.b = b; self.sourceKey = sourceKey; self.label = label; self.work = work
        self.solutionShownAt = solutionShownAt; self.shownBeforeTrying = shownBeforeTrying
    }

    public init(_ r: Record) {
        let f = r.fields
        self.init(id: r.id, problem: f["problem"]?.string ?? "", skills: f["skills"]?.stringArray ?? [], at: f["at"]?.number ?? 0,
                  hint: Int(f["hint"]?.number ?? 0), marking: Marking(rawValue: f["marking"]?.string ?? "") ?? .none,
                  score: f["score"]?.number, uncertain: f["uncertain"]?.bool ?? false, b: f["b"]?.number ?? 0,
                  sourceKey: f["source"]?.string ?? "", label: f["label"]?.string ?? "", work: f["work"]?.string ?? "",
                  solutionShownAt: f["shownAt"]?.number, shownBeforeTrying: f["shownBeforeTrying"]?.bool ?? false)
    }

    var fields: [String: JSONValue] {
        var out: [String: JSONValue] = [
            "problem": .string(problem), "skills": JSONValue(skills), "at": .number(at), "hint": .number(Double(hint)),
            "marking": .string(marking.rawValue), "uncertain": .bool(uncertain), "b": .number(b), "source": .string(sourceKey),
            "label": .string(label),
        ]
        out["score"] = score.map(JSONValue.number) ?? .null
        if !work.isEmpty { out["work"] = .string(work) }
        if let solutionShownAt { out["shownAt"] = .number(solutionShownAt); out["shownBeforeTrying"] = .bool(shownBeforeTrying) }
        return out
    }
}

extension Library {
    // MARK: Concepts

    /// Makes (or finds) the concept with this name. The id comes from the name, so two devices making
    /// "Conservation of momentum" offline make the same record.
    @discardableResult
    public func addConcept(_ name: String, type: ConceptType = .concept, origin: DevelopOrigin = .user) async -> String {
        let id = Develop.conceptId(name)
        if let r = await engine.record(id), !r.isDeleted { return id }
        await engine.set(["name": .string(name.trimmingCharacters(in: .whitespacesAndNewlines)), "type": .string(type.rawValue),
                          "origin": .string(origin.rawValue), "createdAt": .number(now().timeIntervalSince1970 * 1000)],
                         record: id, kind: Develop.conceptKind)
        return id
    }

    public func concepts() async -> [Concept] { await engine.records(kind: Develop.conceptKind).map(Concept.init) }

    /// The loser points at the winner; edges aren't rewritten (`EdgeIndex` follows `mergedInto`).
    public func mergeConcept(_ loser: String, into winner: String) async {
        guard loser != winner else { return }
        await engine.set(["mergedInto": .string(winner)], record: loser, kind: Develop.conceptKind)
    }

    public func unmergeConcept(_ id: String) async {
        await engine.set(["mergedInto": .null], record: id, kind: Develop.conceptKind)
    }

    // MARK: Edges

    /// Adds or updates an edge. A rejected edge is never turned back into a suggestion: only the user
    /// (origin `.user`) can accept it again.
    @discardableResult
    public func setEdge(from: String, to: String, type: EdgeType, state: EdgeState, origin: DevelopOrigin,
                        confidence: Double? = nil, why: String? = nil) async -> String {
        let (a, b) = type.isSymmetric ? (min(from, to), max(from, to)) : (from, to)
        let id = Develop.edgeId(from: a, type: type, to: b)
        if let r = await engine.record(id), let old = Edge(r), old.state == .rejected, origin != .user { return id }
        var fields: [String: JSONValue] = ["from": .string(a), "to": .string(b), "type": .string(type.rawValue), "state": .string(state.rawValue),
                                           "origin": .string(origin.rawValue), "at": .number(now().timeIntervalSince1970 * 1000)]
        if let confidence { fields["confidence"] = .number(confidence) }
        if let why { fields["why"] = .string(why) }
        await engine.set(fields, record: id, kind: Develop.edgeKind)
        return id
    }

    public func edges() async -> [Edge] { await engine.records(kind: Develop.edgeKind).compactMap(Edge.init) }

    // MARK: Problems and attempts

    @discardableResult
    public func addProblem(sourceKey: String, key: String, parent: String? = nil, pages: [PageRegion], marks: Int?, level: ProblemLevel,
                           nationalAverage: Double? = nil, label: String, skills: [String] = [], splitBy: String = "auto",
                           format: PracticeFormat = .written) async -> String {
        let id = Develop.problemId(sourceKey: sourceKey, key: key)
        let source: JSONValue = sourceKey.hasPrefix("cat:") ? ["catalogue": .string(String(sourceKey.dropFirst(4)))]
            : ["item": .string(String(sourceKey.dropFirst(5)))]
        var fields: [String: JSONValue] = ["source": source, "key": .string(key), "pages": .array(pages.map(\.json)), "level": .string(level.rawValue),
                                           "label": .string(label), "skills": JSONValue(skills), "splitBy": .string(splitBy), "origin": .string(sourceKey.hasPrefix("cat:") ? "paper" : "upload")]
        fields["parent"] = parent.map(JSONValue.string) ?? .null
        fields["marks"] = marks.map { .number(Double($0)) } ?? .null
        fields["nationalAverage"] = nationalAverage.map(JSONValue.number) ?? .null
        fields["splitV"] = .number(Double(PaperSplitter.version))
        if format != .written { fields["format"] = .string(format.rawValue) }
        await engine.set(fields, record: id, kind: Develop.problemKind)
        for skill in skills { await setEdge(from: id, to: skill, type: .tests, state: .accepted, origin: .rule) }
        return id
    }

    public func problems() async -> [Problem] { await engine.records(kind: Develop.problemKind).map(Problem.init) }

    /// Adds skills to a problem (a spec statement found later; learn-pivot plan §B4). What it has is kept.
    public func addSkills(_ skills: [String], to problemId: String) async {
        guard let r = await engine.record(problemId), !r.isDeleted else { return }
        let have = r["skills"]?.stringArray ?? []
        let new = skills.filter { !have.contains($0) }
        guard !new.isEmpty else { return }
        await engine.set(["skills": JSONValue(have + new)], record: problemId, kind: Develop.problemKind)
        for skill in new { await setEdge(from: problemId, to: skill, type: .tests, state: .accepted, origin: .spec) }
    }

    /// After splitting a paper again: its questions that the new split no longer has are removed (their
    /// attempts keep their label, so Your work still shows them).
    public func removeProblems(sourceKey: String, keeping keys: Set<String>) async {
        for p in await problems() where p.sourceKey == sourceKey && !keys.contains(p.key) {
            await engine.delete(p.id)
        }
    }

    /// Records an attempt (written once; marking can be confirmed or changed later).
    @discardableResult
    public func recordAttempt(_ attempt: Attempt) async -> String {
        await engine.set(attempt.fields, record: attempt.id, kind: Develop.attemptKind)
        return attempt.id
    }

    public func attempts() async -> [Attempt] { await engine.records(kind: Develop.attemptKind).map(Attempt.init) }
}
