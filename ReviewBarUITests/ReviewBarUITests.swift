import XCTest

final class ReviewBarUITests: XCTestCase {
    @MainActor
    func testDemoDashboardNavigation() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing-demo"]
        app.launch()
        defer {
            XCUIDevice.shared.orientation = .portrait
            app.terminate()
        }

        XCTAssertTrue(app.navigationBars["Apps"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Glassdays"].waitForExistence(timeout: 3))
        app.staticTexts["Glassdays"].tap()
        XCTAssertTrue(app.tabBars.buttons["Overview"].isSelected)
        XCTAssertTrue(app.staticTexts["Version 1.4"].waitForExistence(timeout: 3))

        app.tabBars.buttons["Reviews"].tap()
        XCTAssertTrue(app.navigationBars["Reviews"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Exactly what I wanted"].exists)

        app.tabBars.buttons["Builds"].tap()
        XCTAssertTrue(app.navigationBars["Builds"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["1.4 (48)"].exists)

        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.tabBars.buttons["Builds"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["1.4 (48)"].waitForExistence(timeout: 3))
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    func testSignedOutOnboarding() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing-signed-out"]
        app.launch()
        defer { app.terminate() }

        XCTAssertTrue(app.buttons["Connect to App Store Connect"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Explore with Local Sample Data"].exists)
    }

    @MainActor
    func testEmptyAccountState() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing-empty"]
        app.launch()
        defer { app.terminate() }

        XCTAssertTrue(app.staticTexts["No Apps"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Refresh"].exists)
    }

    @MainActor
    func testDarkModeAtAccessibilityTextSize() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ui-testing-demo",
            "-ui-testing-dark",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"
        ]
        app.launch()
        defer { app.terminate() }

        XCTAssertTrue(app.staticTexts["Glassdays"].waitForExistence(timeout: 5))
        app.staticTexts["Glassdays"].tap()
        XCTAssertTrue(app.staticTexts["Version 1.4"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["In Review"].waitForExistence(timeout: 3))
    }

    @MainActor
    func testSpecificAppleUnavailableStatePersistsAfterAlert() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing-error"]
        app.launch()
        defer { app.terminate() }

        XCTAssertTrue(app.alerts["Apple Unavailable"].waitForExistence(timeout: 5))
        app.alerts["Apple Unavailable"].buttons["OK"].tap()
        XCTAssertTrue(app.staticTexts["Apple Unavailable"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Try Again"].exists)
    }
}
