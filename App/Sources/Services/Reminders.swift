import Foundation
import TroveCore
import UserNotifications

/// Reminders on items (MASTER_PLAN N8): every device keeps its local notifications in step with
/// the items' `remindAt` after each change (only the differences are added or removed).
@MainActor
enum Reminders {
    static let prefix = "trove.remind."
    private static var scheduled: [String: Date] = [:]

    static func sync(_ items: [Item]) {
        var wanted: [String: (Date, String)] = [:]
        let now = Date()
        for item in items { if let at = item.remindAt, at > now { wanted[item.id] = (at, item.displayTitle) } }
        let center = UNUserNotificationCenter.current()
        let gone = scheduled.keys.filter { wanted[$0] == nil || wanted[$0]?.0 != scheduled[$0] }
        if !gone.isEmpty { center.removePendingNotificationRequests(withIdentifiers: gone.map { prefix + $0 }) }
        for id in gone { scheduled[id] = nil }
        for (id, (at, title)) in wanted where scheduled[id] != at {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = "Reminder from Trove"
            content.sound = .default
            content.userInfo = ["item": id]
            let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: at)
            let request = UNNotificationRequest(identifier: prefix + id, content: content, trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false))
            center.add(request)
            scheduled[id] = at
        }
    }

    static func ask() async { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }
}
