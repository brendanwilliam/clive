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
        XCTAssertTrue(app.staticTexts["Terminals"].waitForExistence(timeout: 4))
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

    func testKeyboardDismissalThenPagingRemainAvailable() {
        let first = terminalSurface(firstID)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 2))
        first.swipeDown(velocity: .slow)
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        first.swipeLeft()
        XCTAssertTrue(waitForSelection(of: terminalSurface(secondID)))
    }

    func testTerminalStartsBelowCompactNavigationBar() {
        let terminal = terminalSurface(firstID)
        XCTAssertTrue(terminal.waitForExistence(timeout: 3))

        let connection = app.buttons["connection-details-button"]
        XCTAssertLessThanOrEqual(connection.frame.height, 44)
        XCTAssertGreaterThanOrEqual(terminal.frame.minY, connection.frame.maxY)
    }

    func testDrawerRowSelectionOutsideMenu() {
        app.buttons["Terminals"].tap()
        drawerRow(secondID).coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)).tap()
        XCTAssertFalse(app.staticTexts["Terminals"].exists)
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

    func testDrawerUsesNativeRenameDisconnectAndDeleteSwipeActions() {
        app.buttons["Terminals"].tap()
        drawerRow(firstID).swipeLeft()
        XCTAssertTrue(app.buttons["Rename"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["Disconnect"].exists)
        XCTAssertTrue(app.buttons["Delete"].exists)

        app.buttons["Rename"].tap()
        XCTAssertTrue(app.staticTexts["Rename terminal"].waitForExistence(timeout: 2))
        app.buttons["Cancel"].tap()

        drawerRow(firstID).swipeLeft()
        app.buttons["Disconnect"].tap()
        drawerRow(firstID).swipeLeft()
        XCTAssertTrue(app.buttons["Reconnect"].waitForExistence(timeout: 2))
    }

    func testDrawerShowsConnectedAndDisconnectedTerminalsTogether() {
        app.buttons["Terminals"].tap()
        XCTAssertTrue(app.images["terminal-status-\(firstID)"].exists)
        XCTAssertTrue(app.images["catalog-terminal-status-00000000-0000-0000-0000-000000000003"].exists)
        XCTAssertTrue(app.staticTexts["Detached shell"].exists)
        XCTAssertFalse(app.staticTexts["Available on this Mac"].exists)
    }

    func testDeleteAllPermanentlyEndsLocalCliveTerminals() {
        app.buttons["Terminals"].tap()
        app.buttons["Delete All"].tap()
        XCTAssertTrue(app.staticTexts["Delete all terminals?"].waitForExistence(timeout: 2))
        XCTAssertTrue(text(containing: "permanently ends every Clive terminal").exists)
        app.buttons["Cancel"].tap()
    }

    func testShortcutsUseNativeEditDeleteAndReorderActions() {
        app.buttons["shortcuts-button"].tap()
        let shortcut = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Status")).firstMatch
        XCTAssertTrue(shortcut.waitForExistence(timeout: 2))

        shortcut.swipeLeft()
        XCTAssertTrue(app.buttons["Edit"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["Delete"].exists)
        app.buttons["Edit"].tap()
        XCTAssertTrue(app.staticTexts["Edit shortcut"].waitForExistence(timeout: 2))
        app.alerts["Edit shortcut"].buttons["Cancel"].tap()

        app.buttons["shortcut-options"].tap()
        XCTAssertTrue(app.buttons["Reorder Shortcuts"].waitForExistence(timeout: 2))
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
