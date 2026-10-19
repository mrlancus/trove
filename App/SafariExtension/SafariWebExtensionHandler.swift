import Foundation
import SafariServices

/// The Safari extension is the same web extension as Chrome (extensions/browser, bundled as
/// resources). It talks to the relay directly, so this native handler only answers pings.
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        let response = NSExtensionItem()
        response.userInfo = [SFExtensionMessageKey: ["ok": true]]
        context.completeRequest(returningItems: [response], completionHandler: nil)
    }
}
