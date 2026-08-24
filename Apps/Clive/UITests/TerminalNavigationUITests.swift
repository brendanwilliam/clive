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

    func testTitleSwipesSelectAdjacentTerminalsWithoutCreatingAtBoundaries() {
        let first = terminalSurface(firstID)
        XCTAssertTrue(first.waitForExistence(timeout: 3))
        XCTAssertEqual(first.value as? String, "Selected")

        terminalTitle.swipeLeft()
        let second = terminalSurface(secondID)
        XCTAssertEqual(second.value as? String, "Selected")
        XCTAssertEqual(terminalTitle.value as? String, "Shell 2")

        terminalTitle.swipeLeft()
        XCTAssertEqual(app.buttons["Terminals"].value as? String, "2 open")
        XCTAssertEqual(second.value as? String, "Selected")

        terminalTitle.swipeRight()
        XCTAssertEqual(first.value as? String, "Selected")
        terminalTitle.swipeRight()
        XCTAssertEqual(app.buttons["Terminals"].value as? String, "2 open")
        XCTAssertEqual(first.value as? String, "Selected")
    }

    func testLeftEdgeSwipeOpensDrawerWithoutChangingSelection() {
        swipeFromLeftEdge()
        XCTAssertTrue(app.staticTexts["Terminals"].waitForExistence(timeout: 4))
        XCTAssertEqual(drawerRow(firstID).value as? String, "Selected")
    }

    func testRightEdgeSwipeOpensShortcutsWithoutChangingSelection() {
        swipeFromRightEdge()
        XCTAssertTrue(app.otherElements["shortcuts-sheet"].waitForExistence(timeout: 4))
        XCTAssertEqual(terminalSurface(firstID).value as? String, "Selected")
    }

    func testContentSwipesDoNotNavigateOrCreateTerminal() {
        let first = terminalSurface(firstID)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 2))
        first.swipeLeft()
        first.swipeRight()
        XCTAssertEqual(first.value as? String, "Selected")
        XCTAssertEqual(app.buttons["Terminals"].value as? String, "2 open")
    }

    func testVerticalContentSwipesPreserveTerminalSelection() {
        let first = terminalSurface(firstID)
        first.swipeUp()
        first.swipeDown()
        XCTAssertEqual(first.value as? String, "Selected")
        XCTAssertTrue(app.keyboards.firstMatch.exists)
    }

    func testTerminalDoubleTapRegionsPreserveTerminalSelection() {
        let first = terminalSurface(firstID)
        first.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)).doubleTap()
        first.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).doubleTap()
        first.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)).doubleTap()
        XCTAssertEqual(first.value as? String, "Selected")
    }

    func testTerminalTitleOpensRenameAndUpdatesAfterSave() {
        terminalTitle.tap()
        XCTAssertTrue(app.staticTexts["Rename terminal"].waitForExistence(timeout: 2))
        let name = app.textFields["Terminal name"]
        name.tap()
        name.typeText(" Renamed")
        app.buttons["Save"].tap()
        XCTAssertEqual(terminalTitle.value as? String, "Shell 1 Renamed")
        XCTAssertFalse(app.navigationBars["Settings"].exists)
    }

    func testTerminalStartsBelowCompactNavigationBar() {
        let terminal = terminalSurface(firstID)
        XCTAssertTrue(terminal.waitForExistence(timeout: 3))

        XCTAssertLessThanOrEqual(terminalTitle.frame.height, 44)
        XCTAssertGreaterThanOrEqual(terminal.frame.minY, terminalTitle.frame.maxY)
    }

    func testDrawerRowSelectionOutsideMenu() {
        app.buttons["Terminals"].tap()
        drawerRow(secondID).coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)).tap()
        XCTAssertFalse(app.staticTexts["Terminals"].exists)
        XCTAssertEqual(terminalSurface(secondID).value as? String, "Selected")
    }

    func testConnectionDetailsContainSafeTrustAndReplayMessaging() {
        app.buttons["Terminals"].tap()
        app.buttons["drawer-settings-button"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 2))
        XCTAssertTrue(text(containing: "Open Terminals").exists)
        XCTAssertTrue(text(containing: "Active Terminals").exists)
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Test Mac")).firstMatch.tap()
        XCTAssertTrue(text(containing: "Local network").waitForExistence(timeout: 2))
        XCTAssertTrue(text(containing: "TLS 1.3").exists)
        XCTAssertTrue(text(containing: "Mutual authentication").exists)
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
        app.buttons["Terminal actions"].tap()
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

    private var terminalTitle: XCUIElement { app.buttons["terminal-title-button"] }

    private func swipeFromLeftEdge() {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    private func swipeFromRightEdge() {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.99, dy: 0.5))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: end)
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
