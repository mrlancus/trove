import AppIntents
import Foundation
import TroveCore

/// Shortcuts / Siri / Spotlight / Action Button actions. They run without opening the app where
/// possible by dropping a sealed envelope into the inbox (CaptureDrop).

struct SaveTextIntent: AppIntent {
    static let title: LocalizedStringResource = "Save to Trove"
    static let description = IntentDescription("Saves text or a link to Trove.")
    @Parameter(title: "Text or link") var text: String

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), url.scheme?.hasPrefix("http") == true, !trimmed.contains(" ") {
            try await CaptureDrop.send(CaptureDrop.link(url, source: "ios"))
        } else {
            try await CaptureDrop.send(CaptureDrop.text(trimmed, source: "ios"))
        }
        return .result(dialog: "Saved to Trove")
    }
}

struct SaveClipboardIntent: AppIntent {
    static let title: LocalizedStringResource = "Save Clipboard to Trove"
    static let description = IntentDescription("Saves whatever you last copied. Great on Back Tap or the Action Button.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        if let url = Pasteboard.url {
            try await CaptureDrop.send(CaptureDrop.link(url))
            return .result(dialog: "Saved the link")
        }
        guard let text = Pasteboard.string, !text.isEmpty else { return .result(dialog: "Your clipboard is empty") }
        try await CaptureDrop.send(CaptureDrop.text(text))
        return .result(dialog: "Saved to Trove")
    }
}

struct SearchTroveIntent: AppIntent {
    static let title: LocalizedStringResource = "Search Trove"
    static let openAppWhenRun = true
    @Parameter(title: "Search for") var query: String

    @MainActor
    func perform() async throws -> some IntentResult & OpensIntent {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        return .result(opensIntent: OpenURLIntent(URL(string: "trove://search?q=\(encoded)")!))
    }
}

struct TroveShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: SaveClipboardIntent(), phrases: ["Save clipboard to \(.applicationName)", "Save this to \(.applicationName)"],
                    shortTitle: "Save Clipboard", systemImageName: "doc.on.clipboard")
        AppShortcut(intent: OpenCaptureIntent(), phrases: ["Capture in \(.applicationName)", "New \(.applicationName) note"],
                    shortTitle: "Capture", systemImageName: "plus.circle")
        AppShortcut(intent: SearchTroveIntent(), phrases: ["Search \(.applicationName)"],
                    shortTitle: "Search", systemImageName: "magnifyingglass")
    }
}
