import Foundation
import UserNotifications
import TroveCore

/// Local notifications for price drops. These are local, not push (a free Apple ID has no push),
/// so they appear when this device syncs: in the app, on a live relay ping, or in a background refresh.
enum PriceAlerts {
    static func requestPermission() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    static func price(_ amount: Double, _ currency: String?) -> String {
        amount.formatted(.currency(code: currency ?? "GBP"))
    }

    static func message(_ drop: PriceDrop) -> String {
        "\(drop.title) is now \(price(drop.price, drop.currency)) (was \(price(drop.previous, drop.currency)))"
    }

    static func notify(_ drop: PriceDrop) async {
        let content = UNMutableNotificationContent()
        content.title = "Price drop"
        content.body = message(drop)
        content.sound = .default
        content.userInfo = ["itemId": drop.itemId]
        let request = UNNotificationRequest(identifier: "price-\(drop.itemId)-\(drop.price)", content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }
}
