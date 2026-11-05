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

    func launch(_ extra: [String] = []) -> XCUIApplication {
        prepare()
        let app = XCUIApplication()
        app.launchArguments += ["-TroveTestVault", "small"] + extra
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

    /// The library has loaded once its collections show counts (the first launch writes the vault).
    /// The app opens on Home; the iPhone's library is its Library tab, opening on Recent with its
    /// collections one tap back.
    func waitForLibrary(_ app: XCUIApplication) -> Bool {
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            if app.staticTexts["Sketches"].firstMatch.exists { return true }
            let library = app.tabBars.buttons["Library"]
            if library.exists, !library.isSelected { library.tap() }
            let back = app.navigationBars.buttons.firstMatch
            if app.navigationBars["Recent"].exists, back.exists { back.tap() }
            sleep(1)
        }
        return false
    }

    /// Opens a collection in the sidebar (iPad, Mac) or the Library tab's list (iPhone).
    func open(_ app: XCUIApplication, _ name: String) {
        let row = app.staticTexts[name].firstMatch
        if row.waitForExistence(timeout: 10) { row.tap() }
    }

    func testLibraryScrollsAndShows() {
        let app = launch()
        // Where the app opens (docs/prompts/practice-space-home.md).
        // Home leads with learning (learn-pivot plan §4 B2): Up next first; New sketch is a small button below.
        XCTAssertTrue(app.staticTexts["Up next"].firstMatch.waitForExistence(timeout: 60), "the app didn't open on Home")
        XCTAssertTrue(app.buttons["New sketch"].firstMatch.exists || app.staticTexts["New sketch"].firstMatch.exists, "no New sketch on Home")
        shot(app, "home")
        XCTAssertTrue(waitForLibrary(app), "the generated vault never showed")
        shot(app, "sidebar")
        open(app, "Notes")
        sleep(2)
        shot(app, "notes")
        let window = app.windows.firstMatch
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        measure(metrics: [XCTOSSignpostMetric.scrollDecelerationMetric], options: options) {
            // Each fling is left to come to rest inside its iteration: a swipe that caught the list still
            // moving left iterations 1 and 2 with no deceleration to measure (iPhone 16 Pro Max, 5068d91).
            window.swipeUp(velocity: .fast)
            sleep(2)
            window.swipeDown(velocity: .fast)
            sleep(2)
        }
        shot(app, "notes-scrolled")
    }

    func testOpenTheNotebook() {
        let app = launch()
        XCTAssertTrue(waitForLibrary(app))
        open(app, "Sketches")
        let notebook = app.staticTexts["Generated notebook"].firstMatch
        XCTAssertTrue(notebook.waitForExistence(timeout: 30), "the generated notebook isn't in Sketches")
        notebook.tap()
        sleep(3)
        shot(app, "notebook-item")
        app.windows.firstMatch.swipeUp()
        shot(app, "notebook-item-scrolled")
    }

    func testSearch() {
        let app = launch()
        XCTAssertTrue(waitForLibrary(app))
        let field = app.searchFields.firstMatch
        if !field.waitForExistence(timeout: 5) {
            // A narrow iPad (mini) folds the toolbar's search field into a Search button; tap it as a person would.
            let button = app.navigationBars.buttons["Search"].firstMatch
            if button.exists { button.tap() } else {
                // iPhone: Search is its own tab (the last one).
                let tabs = app.tabBars.buttons
                if tabs.count > 0 { tabs.element(boundBy: tabs.count - 1).tap() }
            }
        }
        XCTAssertTrue(field.waitForExistence(timeout: 10), "no search field")
        field.tap()
        sleep(1)
        // On iPad the field sits in the toolbar and the keyboard goes to the app, not the element.
        if (field.value(forKey: "hasKeyboardFocus") as? Bool) == true { field.typeText("momentum") } else { app.typeText("momentum") }
        sleep(1)
        shot(app, "search")
    }

    func testDevelop() {
        let app = launch()
        XCTAssertTrue(waitForLibrary(app))
        let tab = app.tabBars.buttons["Learn"]
        if tab.exists { tab.tap() } else { open(app, "Learn") }
        XCTAssertTrue(app.staticTexts["Your courses"].firstMatch.waitForExistence(timeout: 20), "Learn didn't open")
        shot(app, "develop")
        // Add a course from the catalogue (every board's specs, bundled), then open it.
        app.buttons["Add a course"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Add a course"].waitForExistence(timeout: 10), "the course picker didn't open")
        shot(app, "develop-courses")
        let search = app.searchFields.firstMatch
        if search.waitForExistence(timeout: 5) { search.tap(); search.typeText("physics") }
        sleep(1)
        shot(app, "develop-courses-physics")
        let first = app.buttons.matching(NSPredicate(format: "label CONTAINS 'AQA A-level' OR label CONTAINS 'OCR A-level'")).firstMatch
        if first.waitForExistence(timeout: 5) {
            first.tap()
            XCTAssertTrue(app.staticTexts["A-level Physics"].firstMatch.waitForExistence(timeout: 10), "the course wasn't added")
            app.staticTexts["A-level Physics"].firstMatch.tap()
            sleep(2)
            shot(app, "develop-course")
        }
    }

    /// Learn comes second (learn-pivot plan §4 B1): the iPhone's tabs are Home · Learn · Library · Clipboard ·
    /// Search; the iPad's sidebar has Learn right under Home.
    func testLearnComesSecond() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["Up next"].firstMatch.waitForExistence(timeout: 60))
        let tabs = app.tabBars.buttons
        if tabs.count >= 5 {
            XCTAssertEqual((0..<4).map { tabs.element(boundBy: $0).label }, ["Home", "Learn", "Library", "Clipboard"])
            tabs.element(boundBy: 1).tap()
        } else {
            let learn = app.staticTexts["Learn"].firstMatch
            XCTAssertTrue(learn.waitForExistence(timeout: 10), "no Learn in the sidebar")
            let home = app.staticTexts["Home"].firstMatch
            if home.exists { XCTAssertLessThan(home.frame.minY, learn.frame.minY) }
            XCTAssertLessThan(learn.frame.minY, app.staticTexts["Sketches"].firstMatch.frame.minY, "Learn isn't above Notes & Sketches")
            learn.tap()
        }
        XCTAssertTrue(app.staticTexts["Your courses"].firstMatch.waitForExistence(timeout: 20), "Learn didn't open")
        shot(app, "learn")
    }

    /// Hidden features (learn-pivot plan §3): no Connections in the sidebar or the iPhone's list.
    func testConnectionsIsHidden() {
        let app = launch()
        XCTAssertTrue(waitForLibrary(app))
        XCTAssertTrue(app.staticTexts["Import"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Connections"].firstMatch.exists, "Connections shows with Features.graph off")
        shot(app, "sidebar-no-connections")
    }

    /// The hidden graph still works: `-TroveFeatures all` brings Connections back (review R4).
    func testConnectionsWithFeaturesOn() {
        let app = launch(["-TroveFeatures", "all"])
        XCTAssertTrue(waitForLibrary(app))
        let row = app.staticTexts["Connections"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "-TroveFeatures all didn't bring Connections back")
        row.tap()
        XCTAssertTrue(app.staticTexts["Notes"].firstMatch.waitForExistence(timeout: 20) || app.buttons["Notes"].firstMatch.waitForExistence(timeout: 5), "the graph didn't open")
        shot(app, "connections")
    }

    func testRotateAndShow() {
        let app = launch()
        XCTAssertTrue(waitForLibrary(app))
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(2)
        shot(app, "sidebar")
        XCUIDevice.shared.orientation = .portrait
        sleep(1)
    }

    func testLaunchTime() {
        // A first launch writes the vault; later launches are what's measured.
        _ = launch()
        let app = XCUIApplication()
        app.launchArguments += ["-TroveTestVault", "small"]
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        measure(metrics: [XCTApplicationLaunchMetric(waitUntilResponsive: true)], options: options) {
            app.terminate()
            app.launch()
        }
    }
}

enum UIDeviceName {
    static var current: String {
        (ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] ?? "device").replacingOccurrences(of: " ", with: "_")
    }
}
