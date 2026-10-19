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
