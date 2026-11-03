import AppIntents
import Foundation

/// Opens Trove's capture sheet. Compiled into both the app and the widget extension, because the
/// Control Center / Lock Screen control (TroveWidgets) runs it.
struct OpenCaptureIntent: AppIntent {
    static let title: LocalizedStringResource = "Capture in Trove"
    static let description = IntentDescription("Opens Trove ready to capture.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & OpensIntent {
        .result(opensIntent: OpenURLIntent(URL(string: "trove://capture")!))
    }
}

/// Opens today's note (Control Center, Lock Screen, Action button, Shortcuts).
struct OpenTodayIntent: AppIntent {
    static let title: LocalizedStringResource = "Today's Note in Trove"
    static let description = IntentDescription("Opens (or makes) today's note.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & OpensIntent {
        .result(opensIntent: OpenURLIntent(URL(string: "trove://today")!))
    }
}

/// Opens Study with the flashcards due now.
struct OpenStudyIntent: AppIntent {
    static let title: LocalizedStringResource = "Study Flashcards in Trove"
    static let description = IntentDescription("Reviews the flashcards that are due.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & OpensIntent {
        .result(opensIntent: OpenURLIntent(URL(string: "trove://study")!))
    }
}
