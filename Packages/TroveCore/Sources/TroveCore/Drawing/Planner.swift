import Foundation

/// Generated planners (docs/MASTER_PLAN.md G3), made in code so there are no template files:
/// a year of monthly, weekly or daily pages, each named in the notebook's outline (so the pages
/// panel is the index), with its heading and day labels as text boxes you can write around.
public enum PlannerKind: String, CaseIterable, Sendable {
    case monthly, weekly, daily
    public var label: String {
        switch self {
        case .monthly: "Monthly (12 pages)"
        case .weekly: "Weekly (a page a week)"
        case .daily: "Daily (a page a day)"
        }
    }
}

public enum Planner {
    public struct Page: Equatable, Sendable {
        public var name: String
        /// Text boxes: heading first, then labels, with their top-left positions.
        public var labels: [(text: String, x: Double, y: Double, size: Double)]
        public static func == (a: Page, b: Page) -> Bool { a.name == b.name && a.labels.map(\.text) == b.labels.map(\.text) }
    }

    /// The pages for a year (page size 768 × 1024, the sketch default).
    public static func pages(_ kind: PlannerKind, year: Int, calendar inCal: Calendar = Calendar(identifier: .gregorian)) -> [Page] {
        var cal = inCal
        cal.firstWeekday = 2 // Monday
        let monthName = DateFormatter()
        monthName.calendar = cal
        monthName.locale = Locale(identifier: "en_GB")
        monthName.dateFormat = "MMMM"
        let dayName = DateFormatter()
        dayName.calendar = cal
        dayName.locale = Locale(identifier: "en_GB")
        dayName.dateFormat = "EEEE d MMMM"
        let short = DateFormatter()
        short.calendar = cal
        short.locale = Locale(identifier: "en_GB")
        short.dateFormat = "EEE d"
        guard let jan1 = cal.date(from: DateComponents(year: year, month: 1, day: 1)),
              let next = cal.date(from: DateComponents(year: year + 1, month: 1, day: 1)) else { return [] }
        switch kind {
        case .monthly:
            return (1...12).compactMap { m in
                guard let first = cal.date(from: DateComponents(year: year, month: m, day: 1)),
                      let days = cal.range(of: .day, in: .month, for: first)?.count else { return nil }
                var labels: [(String, Double, Double, Double)] = [("\(monthName.string(from: first)) \(year)", 48, 40, 30)]
                // A grid of day numbers: 7 columns from Monday.
                let offset = (cal.component(.weekday, from: first) + 5) % 7
                for (i, d) in ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"].enumerated() { labels.append((d, 48 + Double(i) * 96, 100, 13)) }
                for day in 1...days {
                    let cell = offset + day - 1
                    labels.append(("\(day)", 52 + Double(cell % 7) * 96, 130 + Double(cell / 7) * 140, 13))
                }
                return Page(name: monthName.string(from: first), labels: labels)
            }
        case .weekly:
            var out: [Page] = []
            var start = cal.dateInterval(of: .weekOfYear, for: jan1)?.start ?? jan1
            var n = 1
            while start < next {
                var labels: [(String, Double, Double, Double)] = [("Week \(n) · \(short.string(from: start))", 48, 40, 26)]
                for i in 0..<7 {
                    guard let d = cal.date(byAdding: .day, value: i, to: start) else { continue }
                    labels.append((short.string(from: d), 48, 100 + Double(i) * 128, 15))
                }
                out.append(Page(name: "Week \(n)", labels: labels))
                n += 1
                guard let s = cal.date(byAdding: .day, value: 7, to: start) else { break }
                start = s
            }
            return out
        case .daily:
            var out: [Page] = []
            var d = jan1
            while d < next {
                out.append(Page(name: dayName.string(from: d), labels: [(dayName.string(from: d), 48, 40, 26)]))
                guard let n = cal.date(byAdding: .day, value: 1, to: d) else { break }
                d = n
            }
            return out
        }
    }
}

extension Library {
    /// A new planner notebook for `year` (lined paper; pages named for the outline).
    @discardableResult
    public func addPlanner(_ kind: PlannerKind, year: Int, folder: [String] = []) async -> String {
        let pages = Planner.pages(kind, year: year)
        let id = await addSketch(title: "\(year) \(kind.rawValue.capitalized) planner", paper: kind == .monthly ? .blank : .lined, folder: folder)
        let list = pages.map { InkPage(id: String(newId().prefix(8)), name: $0.name) }
        await setPages(id, list)
        for (page, spec) in zip(list, pages) {
            for (i, l) in spec.labels.enumerated() {
                await addElement(on: id, pageKey: page.id, kind: .text, frame: InkGeometry.Rect(x: l.x, y: l.y, width: i == 0 ? 600 : 160, height: l.size * 1.4),
                                 text: l.text, size: l.size, color: i == 0 ? "#1f2937" : "#6b7280")
            }
        }
        return id
    }
}
