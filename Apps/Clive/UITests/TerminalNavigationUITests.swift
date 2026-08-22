import XCTest

final class TerminalNavigationUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
    }

    func testFixtureStartsWithExistingTerminalsAndCreatesOneSelectedTerminal() {
        XCTAssertTrue(app.buttons["Terminals"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.buttons["Terminals"].value as? String, "2 open")
        app.buttons["Terminals"].tap()
        app.buttons["New terminal"].tap()
        XCTAssertEqual(app.buttons["Terminals"].value as? String, "3 open")
    }

    func testDrawerOpensWithoutChangingPagesAndRowSelectionWorks() {
        app.buttons["Terminals"].tap()
        XCTAssertTrue(app.staticTexts["Active Terminals"].waitForExistence(timeout: 4))
        app.staticTexts["Shell 2"].tap()
        XCTAssertFalse(app.staticTexts["Active Terminals"].exists)
    }

    func testConnectionDetailsContainSafeTrustAndReplayMessaging() {
        app.buttons["connection-details-button"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'TLS 1.3'")).firstMatch.waitForExistence(timeout: 2))
        XCTAssertGreaterThan(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Mutual authentication'")).count, 0)
        XCTAssertTrue(app.staticTexts["Some output produced while disconnected was discarded."].exists)
        XCTAssertGreaterThan(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'private key'")).count, 0)
    }

    func testDrawerExposesEllipsisEditAndDeleteActions() {
        app.buttons["Terminals"].tap()
        app.buttons["Actions for Shell 1"].tap()
        app.buttons["Edit"].tap()
        app.buttons["Cancel"].tap()
        app.buttons["Actions for Shell 1"].tap()
        XCTAssertTrue(app.buttons["Delete"].exists)
    }

}
