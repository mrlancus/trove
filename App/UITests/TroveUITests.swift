import UIKit
import XCTest

/// UI tests on iPhone and iPad simulators with a generated vault (`-TroveTestVault small`, debug builds
/// only; never your vault): launch, scroll, open a notebook, search, rotate; screenshots of each screen
/// for docs/UI_AUDIT.md (kept in the result bundle; scripts/ci-app-tests.sh exports them).
/// Simulator frame times say little about a device, so these check that things work and keep the
/// screenshots; frame budgets are judged on your devices (Settings → Battery → Lag and frames).
@MainActor
final class TroveUITests: XCTestCase {
    func prepare() {
        continueAfterFailure = true
        addUIInterruptionMonitor(withDescription: "System alerts") { alert in
            for label in ["Don’t Allow", "Don't Allow", "Not Now", "OK", "Allow"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }
    }

    func launch() -> XCUIApplication {
        prepare()
        let app = XCUIApplication()
        app.launchArguments += ["-TroveTestVault", "small"]
        app.launch()
        return app
    }

    func shot(_ app: XCUIApplication, _ name: String) {
        let orientation = XCUIDevice.shared.orientation.isLandscape ? "landscape" : "portrait"
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "\(UIDeviceName.current)-\(orientation)-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// The generated notebook's title shows once the vault has loaded (the first launch writes it).
    func waitForLibrary(_ app: XCUIApplication) -> Bool {
        app.staticTexts["Generated notebook"].firstMatch.waitForExistence(timeout: 180)
            || app.buttons["Generated notebook"].firstMatch.waitForExistence(timeout: 5)
    }

    func testLibraryScrollsAndShows() {
        let app = launch()
        XCTAssertTrue(waitForLibrary(app), "the generated vault never showed")
        shot(app, "library")
        let window = app.windows.firstMatch
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        measure(metrics: [XCTOSSignpostMetric.scrollDecelerationMetric], options: options) {
            window.swipeUp(velocity: .fast)
            window.swipeDown(velocity: .fast)
        }
        shot(app, "library-scrolled")
    }

    func testOpenTheNotebook() {
        let app = launch()
        XCTAssertTrue(waitForLibrary(app))
        let notebook = app.staticTexts["Generated notebook"].firstMatch
        if notebook.exists { notebook.tap() } else { app.buttons["Generated notebook"].firstMatch.tap() }
        sleep(3)
        shot(app, "notebook-item")
        let window = app.windows.firstMatch
        window.swipeUp()
        shot(app, "notebook-item-scrolled")
    }

    func testSearch() {
        let app = launch()
        XCTAssertTrue(waitForLibrary(app))
        let field = app.searchFields.firstMatch
        if !field.waitForExistence(timeout: 5) {
            // iPhone: Search is its own tab.
            app.tabBars.buttons.element(boundBy: app.tabBars.buttons.count - 1).tap()
        }
        if field.waitForExistence(timeout: 10) {
            field.tap()
            field.typeText("momentum")
            sleep(1)
        }
        shot(app, "search")
    }

    func testRotateAndShow() {
        let app = launch()
        XCTAssertTrue(waitForLibrary(app))
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(2)
        shot(app, "library")
        XCUIDevice.shared.orientation = .portrait
        sleep(1)
    }

    func testLaunchTime() {
        // A first launch writes the vault; later launches are what's measured.
        _ = launch()
        measure(metrics: [XCTApplicationLaunchMetric(waitUntilResponsive: true)]) {
            let app = XCUIApplication()
            app.launchArguments += ["-TroveTestVault", "small"]
            app.launch()
        }
    }
}

enum UIDeviceName {
    static var current: String {
        (ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] ?? "device").replacingOccurrences(of: " ", with: "_")
    }
}
