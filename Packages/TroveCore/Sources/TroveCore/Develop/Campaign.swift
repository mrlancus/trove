import Foundation

/// Preparation campaigns (docs/DEVELOP_PLAN.md §C10): a goal and a deadline → a diagnostic for what
/// hasn't been assessed → a day-by-day plan of the skills most likely to slip by then, within the time
/// you have → re-planned from the evidence whenever you open it. Deterministic, no AI.
public enum CampaignPlanner {
    public static let kind = "campaign"

    public struct Goal: Sendable, Equatable, Identifiable {
        public var id: String
        public var name: String
        /// Unix ms.
        public var deadline: Double
        /// The skills it needs (empty: every skill).
        public var skills: [String]
        /// Your usual time a day; today's can differ (`todayMinutes`).
        public var minutesPerDay: Int
        /// Catalogue spec ids it covers (practice comes from their papers).
        public var courses: [String]
        /// Which papers or components ("Paper 1", "Component 2"), when only some.
        public var papers: [String]
        /// Your own papers (upload item ids) you picked for it.
        public var uploads: [String]
        /// Uploads that matched it automatically and you turned off.
        public var excludedUploads: [String]
        /// "A*", "grade 7", "a gold certificate".
        public var target: String?
        /// What the goal is, in a sentence (written when your AI clarified it, or by you).
        public var summary: String?
        /// The time you have today, if you said: start of that day (Unix ms) and minutes.
        public var todayDate: Double?
        public var todayMinutes: Int?
        /// Removing a goal keeps its record (inactive), so the removal syncs.
        public var active: Bool

        public init(id: String, name: String, deadline: Double, skills: [String] = [], minutesPerDay: Int = 30, courses: [String] = [],
                    papers: [String] = [], uploads: [String] = [], excludedUploads: [String] = [], target: String? = nil, summary: String? = nil,
                    todayDate: Double? = nil, todayMinutes: Int? = nil, active: Bool = true) {
            self.id = id; self.name = name; self.deadline = deadline; self.skills = skills; self.minutesPerDay = minutesPerDay
            self.courses = courses; self.papers = papers; self.uploads = uploads; self.excludedUploads = excludedUploads
            self.target = target; self.summary = summary
            self.todayDate = todayDate; self.todayMinutes = todayMinutes; self.active = active
        }
        public init?(_ r: Record) {
            guard let deadline = r.fields["deadline"]?.number else { return nil }
            self.init(id: r.id, name: r.fields["name"]?.string ?? "", deadline: deadline, skills: r.fields["skills"]?.stringArray ?? [],
                      minutesPerDay: Int(r.fields["minutesPerDay"]?.number ?? 30), courses: r.fields["courses"]?.stringArray ?? [],
                      papers: r.fields["papers"]?.stringArray ?? [], uploads: r.fields["uploads"]?.stringArray ?? [],
                      excludedUploads: r.fields["excludedUploads"]?.stringArray ?? [], target: r.fields["target"]?.string, summary: r.fields["summary"]?.string,
                      todayDate: r.fields["todayDate"]?.number, todayMinutes: r.fields["todayMinutes"]?.number.map { Int($0) },
                      active: r.fields["active"]?.bool ?? true)
        }
        public var fields: [String: JSONValue] {
            var f: [String: JSONValue] = ["name": .string(name), "deadline": .number(deadline), "skills": JSONValue(skills),
                                          "minutesPerDay": .number(Double(minutesPerDay)), "courses": JSONValue(courses),
                                          "papers": JSONValue(papers), "uploads": JSONValue(uploads),
                                          "excludedUploads": JSONValue(excludedUploads), "active": .bool(active)]
            f["target"] = target.map { .string($0) } ?? .null
            f["summary"] = summary.map { .string($0) } ?? .null
            f["todayDate"] = todayDate.map { .number($0) } ?? .null
            f["todayMinutes"] = todayMinutes.map { .number(Double($0)) } ?? .null
            return f
        }

        /// The minutes for the day starting at `dayStart`: today's if you said, else your usual.
        public func minutes(on dayStart: Double) -> Int {
            if let d = todayDate, let m = todayMinutes, abs(d - dayStart) < 1 { return m }
            return minutesPerDay
        }

        /// Sets today's time; it becomes your usual too, since time changes and the latest is the best guess.
        public mutating func setToday(_ minutes: Int, now: Double) {
            todayDate = (now / CampaignPlanner.day).rounded(.down) * CampaignPlanner.day
            todayMinutes = minutes
            minutesPerDay = minutes
        }

        /// Problems from the goal's courses: their catalogue papers' source keys start with these.
        public var sourcePrefixes: Set<String> { Set(courses.map { "cat:\($0)-" }) }

        /// Its courses' papers and its uploads (`GoalUploads.effective`). Empty: anything you have.
        public func sourcePrefixes(uploads: [String]) -> Set<String> { sourcePrefixes.union(uploads.map { "item:\($0)" }) }

        /// Days left, counting today.
        public func daysLeft(now: Double) -> Int {
            let today = (now / CampaignPlanner.day).rounded(.down) * CampaignPlanner.day
            return max(0, Int(((deadline / CampaignPlanner.day).rounded(.down) * CampaignPlanner.day - today) / CampaignPlanner.day) + 1)
        }
    }

    /// One problem takes about this long, with marking (A-level structured questions).
    public static let minutesPerProblem = 8
    /// A skill whose chance of being applied on the deadline is at least this is left alone.
    public static let safeChance = 0.8

    public struct Day: Sendable, Equatable {
        /// Start of the day, Unix ms.
        public var date: Double
        public var skills: [String]
        public var diagnostic: Bool
        /// How many questions fit that day's time.
        public var questions: Int = 0
    }

    public struct Plan: Sendable, Equatable {
        public var days: [Day]
        /// Proficient skills of the goal, and all of them.
        public var proficient: [String]
        public var total: Int
        public var readiness: Double { total == 0 ? 0 : Double(proficient.count) / Double(total) }
        /// "Ready: 3 of 6 skills shown, …": never a bare number.
        public var why: String
    }

    public static let day = 86_400_000.0

    public static func plan(_ goal: Goal, skills allSkills: [String], states: [String: SkillState], now: Double) -> Plan {
        let wanted = (goal.skills.isEmpty ? allSkills : goal.skills).sorted()
        let today = (now / day).rounded(.down) * day
        let lastDay = max(today, (goal.deadline / day).rounded(.down) * day)
        func perDay(_ date: Double) -> Int { max(1, goal.minutes(on: date) / minutesPerProblem) }
        // When each skill was last practised in the plan (starts from the evidence).
        var last: [String: Double] = [:]
        var stability: [String: Double] = [:]
        var ability: [String: Double] = [:]
        var unassessed: [String] = []
        for s in wanted {
            if let st = states[s], st.mastery != nil, let m = st.memory {
                last[s] = m.last; stability[s] = m.stability; ability[s] = st.ability
            } else {
                unassessed.append(s)
            }
        }
        /// The chance of applying a skill on the deadline if last practised at `at`.
        func chance(_ s: String) -> Double {
            guard let l = last[s], let st = stability[s], let a = ability[s] else { return 0 }
            return Mastery.sigmoid(a) * FSRS.retrievability(days: (goal.deadline - l) / day, stability: st)
        }
        var days: [Day] = []
        var date = today
        var queue = unassessed
        while date <= lastDay {
            var picks: [String] = []
            var diagnostic = false
            // A diagnostic first: one problem for every skill with no evidence.
            let perDay = perDay(date)
            while picks.count < perDay, !queue.isEmpty { picks.append(queue.removeFirst()); diagnostic = true }
            if picks.count < perDay {
                let need = wanted.filter { !picks.contains($0) && last[$0] != nil && chance($0) < safeChance }
                    .sorted { chance($0) != chance($1) ? chance($0) < chance($1) : $0 < $1 }
                for s in need.prefix(perDay - picks.count) { picks.append(s) }
            }
            // Planned practice counts as practice on that day for the days after (a modest step).
            for s in picks {
                last[s] = date
                stability[s] = max(stability[s] ?? 1, (stability[s] ?? 1) * 1.5)
                ability[s] = (ability[s] ?? 0) + 0.1
            }
            days.append(Day(date: date, skills: picks, diagnostic: diagnostic, questions: perDay))
            date += day
        }
        let proficient = wanted.filter { states[$0]?.proficient == true }
        let shown = proficient.count, total = wanted.count
        let left = Int(((lastDay - today) / day).rounded()) + 1
        let why = "\(shown) of \(total) skills shown with several independent solves; \(unassessed.count) not assessed yet; \(left) day\(left == 1 ? "" : "s") left."
        return Plan(days: days, proficient: proficient, total: total, why: why)
    }
}

extension Library {
    @discardableResult
    public func saveCampaign(_ goal: CampaignPlanner.Goal) async -> String {
        await engine.set(goal.fields, record: goal.id, kind: CampaignPlanner.kind)
        return goal.id
    }

    public func campaigns() async -> [CampaignPlanner.Goal] {
        await engine.records(kind: CampaignPlanner.kind).compactMap(CampaignPlanner.Goal.init).filter(\.active).sorted { $0.deadline < $1.deadline }
    }

    public func removeCampaign(_ goal: CampaignPlanner.Goal) async {
        var off = goal
        off.active = false
        await saveCampaign(off)
    }
}
