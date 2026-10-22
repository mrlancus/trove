import Foundation

/// Notes (docs/ROADMAP.md "Notes", PROTOCOL.md §12): placeholders, the daily note, templates and
/// checklists. A port of web/public/core/notes.js; both run `Fixtures/notes-cases.json` (made by
/// web/test/make-notes-fixture.mjs).
public enum Notes {
    /// The parts of a moment on this device's clock. Everything below takes these, so tests don't
    /// depend on the time zone.
    public struct DateParts: Sendable, Equatable {
        public var year, month, day, hour, minute, second: Int
        /// 0 = Sunday.
        public var weekday: Int

        public init(year: Int, month: Int, day: Int, hour: Int = 0, minute: Int = 0, second: Int = 0, weekday: Int) {
            self.year = year
            self.month = month
            self.day = day
            self.hour = hour
            self.minute = minute
            self.second = second
            self.weekday = weekday
        }

        public init(_ date: Date = Date(), calendar: Calendar = .current) {
            let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second, .weekday], from: date)
            self.init(year: c.year ?? 1970, month: c.month ?? 1, day: c.day ?? 1, hour: c.hour ?? 0, minute: c.minute ?? 0,
                      second: c.second ?? 0, weekday: ((c.weekday ?? 1) - 1 + 7) % 7)
        }
    }

    static let weekdays = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
    static let months = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]

    static func pad(_ n: Int, _ width: Int = 2) -> String {
        let s = String(n)
        return s.count >= width ? s : String(repeating: "0", count: width - s.count) + s
    }

    /// 2026-10-21
    public static func isoDate(_ p: DateParts) -> String { "\(pad(p.year, 4))-\(pad(p.month))-\(pad(p.day))" }
    /// Wednesday 21 October 2026
    public static func longDate(_ p: DateParts) -> String { "\(weekdays[p.weekday % 7]) \(p.day) \(months[(p.month - 1) % 12]) \(p.year)" }

    // MARK: Placeholders

    public static let placeholderNames: Set<String> = ["date", "time", "datetime", "longdate", "weekday", "day", "month", "year", "clipboard", "title"]

    /// Fills in `{date}` (2026-10-21), `{time}` (14:05), `{datetime}`, `{longdate}` (Wednesday 21
    /// October 2026), `{weekday}`, `{day}`, `{month}` (October), `{year}`, `{clipboard}` and `{title}`.
    /// Anything else in braces stays as it is.
    public static func expand(_ text: String, _ p: DateParts, clipboard: String = "", title: String = "") -> String {
        let time = "\(pad(p.hour)):\(pad(p.minute))"
        let values: [String: String] = [
            "date": isoDate(p), "time": time, "datetime": "\(isoDate(p)) \(time)", "longdate": longDate(p),
            "weekday": weekdays[p.weekday % 7], "day": String(p.day), "month": months[(p.month - 1) % 12], "year": String(p.year),
            "clipboard": clipboard, "title": title,
        ]
        return replacePlaceholders(text) { values[$0] }
    }

    /// True when text has a placeholder we fill in.
    public static func hasPlaceholders(_ text: String) -> Bool { !placeholders(in: text).isEmpty }

    /// Whether filling in a template needs the clipboard (reading it asks permission on iPhone/iPad).
    public static func usesClipboard(_ template: Template) -> Bool {
        placeholders(in: template.title).contains("clipboard") || placeholders(in: template.body).contains("clipboard")
    }

    static func placeholders(in text: String) -> Set<String> {
        var found: Set<String> = []
        _ = replacePlaceholders(text) { name in
            found.insert(name)
            return nil
        }
        return found
    }

    /// `{name}` with name of lowercase ASCII letters, replaced by `value(name)` when it's one we know.
    private static func replacePlaceholders(_ text: String, _ value: (String) -> String?) -> String {
        guard text.contains("{") else { return text }
        var out = ""
        var rest = text[...]
        while let open = rest.firstIndex(of: "{") {
            out += rest[..<open]
            let after = rest.index(after: open)
            var end = after
            while end < rest.endIndex, let a = rest[end].asciiValue, a >= 97, a <= 122 { end = rest.index(after: end) }
            if end > after, end < rest.endIndex, rest[end] == "}" {
                let name = String(rest[after..<end])
                if placeholderNames.contains(name), let v = value(name) {
                    out += v
                } else {
                    out += rest[open...end]
                }
                rest = rest[rest.index(after: end)...]
            } else {
                out += "{"
                rest = rest[after...]
            }
        }
        out += rest
        return out
    }

    // MARK: Templates and the daily note

    public struct Template: Sendable, Equatable, Identifiable {
        public var id: String
        public var name: String
        public var title: String
        public var body: String
        public var tags: [String]
        public var category: String?
        /// One of your notes tagged `template` (not built in).
        public var user: Bool

        public init(id: String, name: String, title: String, body: String, tags: [String], category: String? = nil, user: Bool = false) {
            self.id = id
            self.name = name
            self.title = title
            self.body = body
            self.tags = tags
            self.category = category
            self.user = user
        }
    }

    public static let templateTag = "template"
    public static let dailyTag = "daily"
    public static let dailyName = "Daily note"

    /// Built-in templates. `title` and `body` take placeholders.
    public static let builtIns: [Template] = [
        Template(id: "daily", name: dailyName, title: "{longdate}", body: "## Tasks\n- [ ] \n\n## Notes\n", tags: ["daily"]),
        Template(id: "meeting", name: "Meeting", title: "Meeting {date}",
                 body: "{longdate}, {time}\n\n## Who\n- \n\n## Agenda\n- \n\n## Notes\n\n\n## Actions\n- [ ] ", tags: ["meeting"]),
        Template(id: "journal", name: "Journal", title: "Journal {date}",
                 body: "## How I feel\n\n\n## What happened\n\n\n## Grateful for\n- \n\n## Tomorrow\n- [ ] ", tags: ["journal"]),
        Template(id: "recipe", name: "Recipe", title: "New recipe",
                 body: "Serves: \nTakes: \n\n## Ingredients\n- \n\n## Method\n1. \n\n## Notes\n", tags: ["recipe"], category: "recipe"),
    ]

    /// The daily note's id: the same on every device for that day, so they all write one note.
    public static func dailyId(_ p: DateParts) -> String { "daily-" + isoDate(p) }

    public static func isDaily(_ item: Item) -> Bool { item.id.hasPrefix("daily-") }

    /// A template's name: its title without placeholders ("Meeting {date}" is "Meeting").
    public static func templateName(_ title: String) -> String {
        let bare = replacePlaceholders(title) { _ in "" }
        let words = bare.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
        return words.isEmpty ? "Template" : words.joined(separator: " ")
    }

    /// Notes tagged `template` are your own templates, named after their title, A to Z.
    public static func userTemplates(_ items: [Item]) -> [Template] {
        items.filter { $0.kind == .note && $0.tags.contains(templateTag) && !isDaily($0) }
            .map { i in
                Template(id: i.id, name: templateName(i.title), title: i.title, body: i.body,
                         tags: i.tags.filter { $0 != templateTag }, category: i.category == .note || i.category == .other ? nil : i.category.rawValue, user: true)
            }
            .sorted { a, b in
                let x = a.name.lowercased(), y = b.name.lowercased()
                return x != y ? x < y : a.id < b.id
            }
    }

    /// Every template, yours first; one of yours named like a built-in one replaces it.
    public static func allTemplates(_ items: [Item]) -> [Template] {
        let mine = userTemplates(items)
        let names = Set(mine.map { $0.name.lowercased() })
        return mine + builtIns.filter { !names.contains($0.name.lowercased()) }
    }

    public struct NewNote: Sendable, Equatable {
        public var title: String
        public var body: String
        public var tags: [String]
        public var category: String?
    }

    /// A new note from a template, with the placeholders filled in (`{title}` in the body is the new title).
    public static func make(from template: Template, _ p: DateParts, clipboard: String = "") -> NewNote {
        let title = expand(template.title, p, clipboard: clipboard)
        let body = expand(template.body, p, clipboard: clipboard, title: title)
        return NewNote(title: title, body: body, tags: Array(Set(template.tags)).sorted(), category: template.category)
    }

    /// The daily note for a day: titled with the long date; the body and tags from your template named
    /// "Daily note" if you made one, else the built-in one. Always tagged `daily`.
    public static func daily(_ items: [Item], _ p: DateParts) -> (id: String, date: String, note: NewNote) {
        let template = allTemplates(items).first { $0.name.lowercased() == dailyName.lowercased() } ?? builtIns[0]
        var note = make(from: Template(id: template.id, name: template.name, title: "{longdate}", body: template.body,
                                       tags: template.tags, category: template.category), p)
        note.tags = Array(Set(note.tags + [dailyTag])).sorted()
        return (dailyId(p), isoDate(p), note)
    }

    // MARK: Checklists

    public struct Checkbox: Sendable, Equatable {
        /// The line in the body, from 0.
        public var line: Int
        public var done: Bool
        public var text: String
    }

    /// A `- [ ]` / `- [x]` line (also `*` or `•`, indented with spaces or tabs): whether it's ticked,
    /// where the mark is and the text after it.
    public static func checkbox(_ line: Substring) -> (done: Bool, mark: String.Index, text: Substring)? {
        func blank(_ c: Character) -> Bool { c == " " || c == "\t" }
        var i = line.startIndex
        while i < line.endIndex, blank(line[i]) { i = line.index(after: i) }
        guard i < line.endIndex, "-*•".contains(line[i]) else { return nil }
        i = line.index(after: i)
        guard i < line.endIndex, blank(line[i]) else { return nil }
        while i < line.endIndex, blank(line[i]) { i = line.index(after: i) }
        guard i < line.endIndex, line[i] == "[" else { return nil }
        let mark = line.index(after: i)
        guard mark < line.endIndex, line[mark] == " " || line[mark] == "x" || line[mark] == "X" else { return nil }
        let close = line.index(after: mark)
        guard close < line.endIndex, line[close] == "]" else { return nil }
        let after = line.index(after: close)
        if after < line.endIndex, !blank(line[after]) { return nil }
        let text = after < line.endIndex ? line[line.index(after: after)...] : line[after...]
        return (line[mark] != " ", mark, text)
    }

    static func isFence(_ line: Substring) -> Bool { line.trimmingCharacters(in: .whitespaces).hasPrefix("```") }

    /// The checklist lines outside code blocks, in order.
    public static func checkboxes(in body: String) -> [Checkbox] {
        var out: [Checkbox] = []
        var fence = false
        for (n, line) in lines(body).enumerated() {
            if isFence(line) { fence.toggle(); continue }
            if !fence, let c = checkbox(line) { out.append(Checkbox(line: n, done: c.done, text: String(c.text))) }
        }
        return out
    }

    /// Ticks or unticks the `index`th checkbox (from 0); the body unchanged if there's no such checkbox.
    public static func toggle(_ body: String, at index: Int) -> String {
        let boxes = checkboxes(in: body)
        guard boxes.indices.contains(index) else { return body }
        var all = lines(body).map(String.init)
        let n = boxes[index].line
        let line = all[n][...]
        guard let c = checkbox(line) else { return body }
        all[n] = String(line[..<c.mark]) + (c.done ? " " : "x") + String(line[line.index(after: c.mark)...])
        return all.joined(separator: "\n")
    }

    /// How many checkboxes are ticked, of how many.
    public static func counts(_ body: String) -> (done: Int, total: Int) {
        let boxes = checkboxes(in: body)
        return (boxes.filter(\.done).count, boxes.count)
    }

    /// Lines split on "\n" only, like JavaScript's `split("\n")` (a "\r\n" keeps its "\r").
    static func lines(_ text: String) -> [Substring] {
        text.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false).map { Substring($0) }
    }
}
