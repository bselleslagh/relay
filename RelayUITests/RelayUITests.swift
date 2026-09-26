import XCTest

final class RelayUITests: XCTestCase {
    private func capture(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways
        add(attachment)
    }
    func testTabsAndCoverageNavigation() throws {
        let app = XCUIApplication(); app.launchArguments = ["--demo"]; app.launch()
        XCTAssertTrue(app.staticTexts["In sync."].waitForExistence(timeout: 5))
        capture("Relay-Sync", app: app)
        app.tabBars.buttons["Data"].tap()
        XCTAssertTrue(app.staticTexts["Health data"].waitForExistence(timeout: 3))
        capture("Relay-Data", app: app)
        app.buttons["All data types"].tap()
        XCTAssertTrue(app.navigationBars["Data coverage"].waitForExistence(timeout: 3))
        app.buttons["Done"].tap()
        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.switches["automatic-toggle"].waitForExistence(timeout: 3))
        capture("Relay-Settings", app: app)
        app.switches["wifi-toggle"].tap()
        XCTAssertEqual(app.switches["wifi-toggle"].value as? String, "1")
    }
    func testFreshInstallHasNoFabricatedSyncedData() throws {
        let app = XCUIApplication(); app.launch()
        XCTAssertTrue(app.buttons["primary-sync-action"].waitForExistence(timeout: 5))
        capture("Relay-First-Launch", app: app)
        XCTAssertFalse(app.staticTexts["In sync."].exists)
        app.buttons["primary-sync-action"].tap()
        XCTAssertTrue(app.textFields["server-address"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.secureTextFields["invitation-code"].exists)
        XCTAssertFalse(app.buttons["pair-button"].isEnabled)
        capture("Relay-Connect", app: app)
    }
    func testLargeTextKeepsNavigationAndActionsAccessible() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.switches["automatic-toggle"].waitForExistence(timeout: 3))
        capture("Relay-Large-Text", app: app)
        for _ in 0..<8 {
            if app.buttons["Data coverage"].isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(app.buttons["Data coverage"].isHittable)
    }
}
