import XCTest

final class TerminalNavigationUITests: XCTestCase {
    private let firstID = "00000000-0000-0000-0000-000000000001"
    private let secondID = "00000000-0000-0000-0000-000000000002"
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
    }

    func testPagesFirstToSecondToFirstWithNativeSwipes() {
        let first = terminalSurface(firstID)
        XCTAssertTrue(first.waitForExistence(timeout: 3))
        XCTAssertEqual(first.value as? String, "Selected")

        first.swipeLeft()
        let second = terminalSurface(secondID)
        XCTAssertEqual(second.value as? String, "Selected")

        second.swipeRight()
        XCTAssertEqual(first.value as? String, "Selected")
    }

    func testSwipeRightFromFirstOpensDrawerWithoutChangingSelection() {
        terminalSurface(firstID).swipeRight()
        XCTAssertTrue(app.staticTexts["Active Terminals"].waitForExistence(timeout: 4))
        XCTAssertEqual(drawerRow(firstID).value as? String, "Selected")
    }

    func testSwipeLeftFromLastCreatesExactlyOneSelectedTerminal() {
        terminalSurface(firstID).swipeLeft()
        terminalSurface(secondID).swipeLeft()
        XCTAssertEqual(app.buttons["Terminals"].value as? String, "3 open")
        let selected = app.textViews.matching(
            NSPredicate(format: "identifier BEGINSWITH 'terminal-page-' AND value == 'Selected'")
        )
        XCTAssertEqual(selected.count, 1)
    }

    func testKeyboardDismissalThenVerticalScrollAndPagingRemainAvailable() {
        let first = terminalSurface(firstID)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 2))
        first.swipeDown(velocity: .slow)
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        first.swipeUp()
        first.swipeLeft()
        XCTAssertTrue(waitForSelection(of: terminalSurface(secondID)))
    }

    func testDrawerRowSelectionOutsideMenu() {
        app.buttons["Terminals"].tap()
        drawerRow(secondID).coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)).tap()
        XCTAssertFalse(app.staticTexts["Active Terminals"].exists)
        XCTAssertEqual(terminalSurface(secondID).value as? String, "Selected")
    }

    func testConnectionDetailsContainSafeTrustAndReplayMessaging() {
        app.buttons["connection-details-button"].tap()
        XCTAssertTrue(text(containing: "Connected").waitForExistence(timeout: 2))
        XCTAssertTrue(text(containing: "Local network").exists)
        XCTAssertTrue(text(containing: "Existing session resumed").exists)
        XCTAssertTrue(text(containing: "Some output produced while disconnected was discarded.").exists)
        let details = app.collectionViews["connection-details-sheet"]
        XCTAssertTrue(revealText("TLS 1.3", in: details))
        XCTAssertTrue(revealText("Mutual authentication", in: details))
        XCTAssertTrue(revealText("Certificate pin", in: details))
        XCTAssertTrue(revealText("private key", in: details, caseInsensitive: true))
        XCTAssertTrue(revealText("SHA-256 fingerprint", in: details))
    }

    func testDrawerExposesNativeSwipeEditAndDeleteActions() {
        app.buttons["Terminals"].tap()
        drawerRow(firstID).swipeLeft()
        XCTAssertTrue(app.buttons["Edit"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["Delete"].exists)
    }

    func testDrawerExposesVerticalEllipsisEditAndDeleteActionsAndHitTargets() {
        app.buttons["Terminals"].tap()
        let menu = app.buttons["terminal-actions-\(firstID)"]
        menu.tap()
        app.buttons["Edit"].tap()
        app.buttons["Cancel"].tap()
        menu.tap()
        XCTAssertTrue(app.buttons["Delete"].exists)
        app.buttons["Delete"].tap()
        app.buttons["Cancel"].tap()

        XCTAssertGreaterThanOrEqual(menu.frame.width, 44)
        XCTAssertGreaterThanOrEqual(menu.frame.height, 44)
    }

    private func terminalSurface(_ id: String) -> XCUIElement {
        app.textViews["terminal-page-\(id)"]
    }

    private func drawerRow(_ id: String) -> XCUIElement {
        app.buttons["terminal-row-\(id)"]
    }

    private func waitForSelection(of terminal: XCUIElement, timeout: TimeInterval = 4) -> Bool {
        let predicate = NSPredicate(format: "value == %@", "Selected")
        return XCTWaiter.wait(
            for: [XCTNSPredicateExpectation(predicate: predicate, object: terminal)],
            timeout: timeout
        ) == .completed
    }

    private func text(containing value: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", value)).firstMatch
    }

    private func revealText(_ value: String, in scrollView: XCUIElement, caseInsensitive: Bool = false) -> Bool {
        let comparison = caseInsensitive ? "label CONTAINS[c] %@" : "label CONTAINS %@"
        let element = app.staticTexts.matching(NSPredicate(format: comparison, value)).firstMatch
        for _ in 0..<3 {
            if element.exists { return true }
            scrollView.swipeUp()
        }
        return element.exists
    }
}

private extension XCUIElement {
    func waitForNonExistence(timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "exists == false")
        return XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: self)], timeout: timeout) == .completed
    }
}
