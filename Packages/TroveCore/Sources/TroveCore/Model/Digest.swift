import Foundation

/// Looking back (ROADMAP §4 A3, PROTOCOL.md §11): the weekly digest note, "on this day" and possible
/// duplicates. All local, no AI. A port of web/public/core/digest.js; both run `digest-cases.json`.
public enum Digest {
    public struct Week: Hashable, Sendable {
        public var year: Int
        public var week: Int
        public init(year: Int, week: Int) { self.year = year; self.week = week }
    }

    public struct Note: Equatable, Sendable {
        public var id: String
        public var title: String
        public var body: String
        public var week: Week
        public var saved: Int
        public var written: Int
        public var unopened: Int
        public var yearsAgo: Int
    }

    public struct DuplicateGroup: Equatable, Sendable {
        /// "same link", "same title" or "similar title".
        public var reason: String
        /// Oldest first.
        public var ids: [String]
    }

    static let day = 86_400_000.0
    static let months = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October",
                         "November", "December"]
    static let sectionMax = 25

    static var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0)!
        return c
    }

    static func ms(_ date: Date) -> Double { (date.timeIntervalSince1970 * 1000).rounded() }

    /// The ISO 8601 week (UTC) a moment falls in.
    public static func isoWeek(_ date: Date) -> Week {
        var c = Calendar(identifier: .iso8601)
        c.timeZone = utc.timeZone
        let parts = c.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return Week(year: parts.yearForWeekOfYear ?? 1970, week: parts.weekOfYear ?? 1)
    }

    /// Monday 00:00 UTC of an ISO week.
    public static func weekStart(_ week: Week) -> Date {
        let jan4 = utc.date(from: DateComponents(year: week.year, month: 1, day: 4)) ?? Date(timeIntervalSince1970: 0)
        let weekday = (utc.component(.weekday, from: jan4) + 5) % 7 // Monday 0
        let monday1 = ms(jan4) - Double(weekday) * day
        return Date(timeIntervalSince1970: (monday1 + Double(week.week - 1) * 7 * day) / 1000)
    }

    /// The digest's item id, the same on every device.
    public static func id(for week: Week) -> String {
        "digest-\(week.year)-w" + (week.week < 10 ? "0\(week.week)" : "\(week.week)")
    }

    /// The week before the one `date` is in.
    public static func previousWeek(_ date: Date) -> Week {
        isoWeek(weekStart(isoWeek(date)).addingTimeInterval(-86_400))
    }

    static func dayLabel(_ date: Date) -> String {
        let p = utc.dateComponents([.day, .month], from: date)
        return "\(p.day ?? 1) \(months[(p.month ?? 1) - 1])"
    }

    static func year(_ date: Date) -> Int { utc.component(.year, from: date) }

    static func linkTitle(_ title: String) -> String {
        var s = ""
        for ch in title { s.append("[]|#\n".contains(ch) ? " " : ch) }
        return s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    static func host(_ item: Item) -> String {
        guard let h = item.url?.host else { return "" }
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }

    public static func isDigest(_ item: Item) -> Bool { item.record["digest"] != nil || item.id.hasPrefix("digest-") }

    static func isWritten(_ item: Item) -> Bool { item.kind == .note || item.kind == .sketch }

    static func oldestFirst(_ a: Item, _ b: Item) -> Bool {
        let ta = ms(a.createdAt), tb = ms(b.createdAt)
        if ta != tb { return ta < tb }
        return a.id < b.id
    }

    static func list(_ items: [Item], _ describe: (Item) -> String) -> [String] {
        var lines: [String] = []
        for item in items.prefix(sectionMax) {
            let note = describe(item)
            lines.append("- [[\(linkTitle(item.displayTitle))]]" + (note.isEmpty ? "" : " (\(note))"))
        }
        if items.count > sectionMax { lines.append("- and \(items.count - sectionMax) more") }
        return lines
    }

    /// The digest note for a week. `summary` (an AI paragraph) and `model` are optional; without them
    /// the text is the same on every device.
    public static func weekly(_ items: [Item], week: Week, summary: String = "", model: String = "") -> Note {
        let start = ms(weekStart(week)), end = start + 7 * day
        let pool = items.filter { !isDigest($0) }
        let inWeek = pool.filter { ms($0.createdAt) >= start && ms($0.createdAt) < end }.sorted(by: oldestFirst)
        let saved = inWeek.filter { !isWritten($0) }
        let wrote = inWeek.filter(isWritten)
        let unopened = Array(pool.filter { item in
            let t = ms(item.createdAt)
            return item.kind == .link && item.readAt == nil && t >= start - 28 * day && t < start
        }.sorted(by: oldestFirst).prefix(10))
        let yearsAgo = Array(pool.filter { item in
            let t = ms(item.createdAt)
            guard t < start, t > 0 else { return false }
            let w = isoWeek(item.createdAt)
            return w.week == week.week && w.year < week.year
        }.sorted { oldestFirst($1, $0) }.prefix(10))

        let startDate = Date(timeIntervalSince1970: start / 1000)
        let title = "Week of \(dayLabel(startDate)) \(year(startDate))"
        func things(_ n: Int, _ one: String, _ many: String) -> String { "\(n) " + (n == 1 ? one : many) }
        var lines: [String] = []
        if saved.isEmpty && wrote.isEmpty {
            lines.append("A quiet week: nothing new saved or written.")
        } else {
            lines.append("You saved \(things(saved.count, "thing", "things")) and wrote \(things(wrote.count, "note", "notes")) this week.")
        }
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            lines += ["", "## In short", trimmed, "", "_Processed in the cloud" + (model.isEmpty ? "" : " (\(model))") + "._"]
        }
        if !saved.isEmpty {
            lines += ["", "## Saved"] + list(saved) { item in
                let h = host(item)
                return h.isEmpty ? item.kind.rawValue : item.kind.rawValue + ", " + h
            }
        }
        if !wrote.isEmpty { lines += ["", "## Written"] + list(wrote) { $0.kind == .sketch ? "sketch" : "" } }
        if !unopened.isEmpty { lines += ["", "## Not opened yet"] + list(unopened) { "saved " + dayLabel($0.createdAt) } }
        if !yearsAgo.isEmpty { lines += ["", "## This week in other years"] + list(yearsAgo) { String(year($0.createdAt)) } }
        return Note(id: id(for: week), title: title, body: lines.joined(separator: "\n"), week: week,
                    saved: saved.count, written: wrote.count, unopened: unopened.count, yearsAgo: yearsAgo.count)
    }

    /// Items saved on today's date (UTC) in earlier years, newest first.
    public static func onThisDay(_ items: [Item], now: Date = Date()) -> [Item] {
        let today = utc.dateComponents([.year, .month, .day], from: now)
        return items.filter { item in
            guard !isDigest(item), ms(item.createdAt) != 0 else { return false }
            let c = utc.dateComponents([.year, .month, .day], from: item.createdAt)
            return c.month == today.month && c.day == today.day && (c.year ?? 0) < (today.year ?? 0)
        }.sorted { oldestFirst($1, $0) }
    }

    // MARK: Possible duplicates

    static let stopwords: Set<String> = ["a", "an", "and", "the", "of", "to", "in", "on", "for", "with", "is", "at", "by", "from", "how", "what", "why"]

    /// Title words for comparing: folded, lowercased, no stopwords or one-letter words.
    public static func titleWords(_ title: String) -> [String] {
        let folded = title.decomposedStringWithCompatibilityMapping.unicodeScalars
            .filter { !CharacterSet.nonBaseCharacters.contains($0) }
        var words: [String] = [], current = ""
        for scalar in folded {
            if CharacterSet.letters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar) {
                current += String(scalar).lowercased()
            } else if !current.isEmpty {
                words.append(current); current = ""
            }
        }
        if !current.isEmpty { words.append(current) }
        return words.filter { $0.count > 1 && !stopwords.contains($0) }
    }

    static func jaccard(_ a: [String], _ b: [String]) -> Double {
        let sa = Set(a), sb = Set(b)
        let both = sa.intersection(sb).count
        return Double(both) / Double(sa.count + sb.count - both)
    }

    static let reasonRank = ["same link": 0, "same title": 1, "similar title": 2]

    /// Items that look like the same thing saved twice, newest group first (PROTOCOL.md §11).
    public static func possibleDuplicates(_ items: [Item]) -> [DuplicateGroup] {
        let pool = items.filter { !isDigest($0) && $0.kind != .note && $0.kind != .sketch }
        var parent: [String: String] = [:]
        for item in pool { parent[item.id] = item.id }
        var reason: [String: String] = [:]
        func find(_ start: String) -> String {
            var id = start
            while let p = parent[id], p != id {
                let grand = parent[p] ?? p
                parent[id] = grand
                id = grand
            }
            return id
        }
        func notDuplicates(_ item: Item) -> [String] { item.record["notDuplicates"]?.stringArray ?? [] }
        func join(_ a: Item, _ b: Item, _ why: String) {
            if notDuplicates(a).contains(b.id) || notDuplicates(b).contains(a.id) { return }
            let ra = find(a.id), rb = find(b.id)
            let candidates = [why, reason[ra], reason[rb]].compactMap { $0 }
            let best = candidates.min { (reasonRank[$0] ?? 9) < (reasonRank[$1] ?? 9) } ?? why
            if ra != rb { parent[rb] = ra }
            reason[ra] = best
        }
        var key: [String: String] = [:]
        for item in pool { if let url = item.url { key[item.id] = URLCleaner.dedupeKey(url) } }
        func groups(_ keyOf: (Item) -> String) -> [[Item]] {
            var order: [String] = [], map: [String: [Item]] = [:]
            for item in pool {
                let k = keyOf(item)
                guard !k.isEmpty else { continue }
                if map[k] == nil { order.append(k); map[k] = [] }
                map[k]?.append(item)
            }
            return order.compactMap { map[$0] }.filter { $0.count > 1 }
        }
        for g in groups({ key[$0.id] ?? "" }) { for o in g.dropFirst() { join(g[0], o, "same link") } }
        var words: [String: [String]] = [:]
        for item in pool { words[item.id] = titleWords(item.title) }
        for g in groups({ (words[$0.id] ?? []).count >= 4 ? (words[$0.id] ?? []).joined(separator: " ") : "" }) {
            for o in g.dropFirst() { join(g[0], o, "same title") }
        }
        for g in groups({ host($0) }) {
            for x in 0..<g.count {
                for y in (x + 1)..<max(x + 1, g.count) {
                    let a = g[x], b = g[y]
                    let wa = words[a.id] ?? [], wb = words[b.id] ?? []
                    if wa.count < 3 || wb.count < 3 || key[a.id] == key[b.id] { continue }
                    if jaccard(wa, wb) >= 0.8 { join(a, b, "similar title") }
                }
            }
        }
        var order: [String] = [], members: [String: [Item]] = [:]
        for item in pool {
            let r = find(item.id)
            if members[r] == nil { order.append(r); members[r] = [] }
            members[r]?.append(item)
        }
        let found: [(group: DuplicateGroup, newest: Double)] = order.compactMap { r in
            guard let g = members[r], g.count > 1 else { return nil }
            let sorted = g.sorted(by: oldestFirst)
            return (DuplicateGroup(reason: reason[r] ?? "same link", ids: sorted.map(\.id)), ms(sorted[sorted.count - 1].createdAt))
        }
        return found.sorted { a, b in
            if a.newest != b.newest { return a.newest > b.newest }
            return (a.group.ids.first ?? "") < (b.group.ids.first ?? "")
        }.map(\.group)
    }
}
