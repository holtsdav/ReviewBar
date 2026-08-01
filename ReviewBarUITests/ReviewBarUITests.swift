import XCTest

final class ReviewBarUITests: XCTestCase {
    @MainActor
    func testDemoDashboardNavigation() throws {
        let app = launch(["-ui-testing-demo"])
        defer {
            XCUIDevice.shared.orientation = .portrait
            app.terminate()
        }

        XCTAssertTrue(app.navigationBars["Apps"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Glassdays"].waitForExistence(timeout: 3))
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Glassdays")).firstMatch.tap()
        XCTAssertTrue(app.tabBars.buttons["Overview"].isSelected)
        XCTAssertTrue(app.staticTexts["Version 1.4"].waitForExistence(timeout: 3))

        app.tabBars.buttons["Reviews"].tap()
        XCTAssertTrue(app.navigationBars["Reviews"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Exactly what I wanted"].exists)

        app.tabBars.buttons["Overview"].tap()
        let builds = app.buttons["overview-builds"]
        if !builds.isHittable { app.swipeUp() }
        XCTAssertTrue(builds.waitForExistence(timeout: 3))
        builds.tap()
        XCTAssertTrue(app.navigationBars["Builds"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["1.4 (48)"].exists)

        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertFalse(app.tabBars.buttons["Builds"].exists)
        XCTAssertTrue(app.staticTexts["1.4 (48)"].waitForExistence(timeout: 3))
        XCUIDevice.shared.orientation = .portrait

        app.navigationBars["Builds"].buttons["Overview"].tap()
        XCTAssertTrue(app.navigationBars["Overview"].waitForExistence(timeout: 3))
        app.buttons["overview-release-history"].tap()
        XCTAssertTrue(app.navigationBars["Releases"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Current Release"].exists)

        app.navigationBars["Releases"].buttons["Overview"].tap()
        app.staticTexts["Analytics Snapshot · All Platforms"].swipeUp()
        app.buttons["View Analytics"].tap()
        XCTAssertTrue(app.navigationBars["Analytics"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Downloads Trend"].waitForExistence(timeout: 3))
    }

    @MainActor
    func testSignedOutOnboarding() throws {
        let app = launch(["-ui-testing-signed-out"])
        defer { app.terminate() }

        XCTAssertTrue(app.buttons["Connect to App Store Connect"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Explore with Local Sample Data"].exists)
    }

    @MainActor
    func testEmptyAccountState() throws {
        let app = launch(["-ui-testing-empty"])
        defer { app.terminate() }

        XCTAssertTrue(app.staticTexts["No Apps"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Refresh"].exists)
    }

    @MainActor
    func testDarkModeAtAccessibilityTextSize() throws {
        let app = launch([
            "-ui-testing-demo",
            "-ui-testing-dark",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"
        ])
        defer { app.terminate() }

        XCTAssertTrue(app.staticTexts["Glassdays"].waitForExistence(timeout: 5))
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Glassdays")).firstMatch.tap()
        let release = app.buttons["overview-release-history"]
        XCTAssertTrue(release.waitForExistence(timeout: 5))
        XCTAssertTrue(release.label.contains("In Review"))
    }

    @MainActor
    func testSpecificAppleUnavailableStatePersistsAfterAlert() throws {
        let app = launch(["-ui-testing-error"])
        defer { app.terminate() }

        XCTAssertTrue(app.alerts["Apple Unavailable"].waitForExistence(timeout: 5))
        app.alerts["Apple Unavailable"].buttons["OK"].tap()
        XCTAssertTrue(app.staticTexts["Apple Unavailable"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Try Again"].exists)
    }

    @MainActor
    func testAnalyticsPermissionAndEmptyStates() throws {
        let permissionApp = launch(["-ui-testing-demo", "-ui-testing-analytics-permission"])
        XCTAssertTrue(permissionApp.staticTexts["Glassdays"].waitForExistence(timeout: 5))
        permissionApp.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Glassdays")).firstMatch.tap()
        XCTAssertTrue(permissionApp.navigationBars["Overview"].waitForExistence(timeout: 5))
        permissionApp.tabBars.buttons["Analytics"].tap()
        XCTAssertTrue(permissionApp.staticTexts["Analytics Permission Required"].waitForExistence(timeout: 5))
        permissionApp.terminate()

        let emptyApp = launch(["-ui-testing-demo", "-ui-testing-analytics-empty"])
        XCTAssertTrue(emptyApp.staticTexts["Glassdays"].waitForExistence(timeout: 5))
        emptyApp.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Glassdays")).firstMatch.tap()
        XCTAssertTrue(emptyApp.navigationBars["Overview"].waitForExistence(timeout: 5))
        emptyApp.tabBars.buttons["Analytics"].tap()
        XCTAssertTrue(emptyApp.staticTexts["No Analytics Data"].waitForExistence(timeout: 5))
        emptyApp.terminate()
    }

    @MainActor
    func testRealTimeSettingsExplainsUnavailableDemoMode() throws {
        let app = launch(["-ui-testing-demo"])
        defer { app.terminate() }

        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 5))
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 3))
        let realtime = app.buttons["settings-realtime-updates"]
        if !realtime.isHittable { app.swipeUp() }
        XCTAssertTrue(realtime.waitForExistence(timeout: 3))
        realtime.tap()
        XCTAssertTrue(app.navigationBars["Real-Time Updates"].waitForExistence(timeout: 3))
        let status = app.descendants(matching: .any).matching(identifier: "realtime-status").firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 3))
        XCTAssertTrue(status.label.contains("Real-Time Updates") || status.value as? String == "Unavailable")
        XCTAssertTrue(app.staticTexts["Apple Role Required"].exists)
    }

    @MainActor
    private func launch(_ arguments: [String]) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = arguments + ["-ui-testing-reset"]
        app.launch()
        return app
    }
}
