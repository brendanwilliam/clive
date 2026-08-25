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
        showFirstTerminalDetail()
    }

    override func tearDownWithError() throws {
        app.terminate()
        app = nil
    }

    func testTerminalTitleRemainsRenameOnlyAfterHorizontalDrag() {
        let first = terminalSurface(firstID)
        XCTAssertTrue(first.waitForExistence(timeout: 3))
        XCTAssertEqual(first.value as? String, "Selected")

        let title = app.buttons["terminal-title-button"]
        XCTAssertTrue(title.waitForExistence(timeout: 3))
        title.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)).press(
            forDuration: 0.05,
            thenDragTo: title.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5))
        )
        XCTAssertTrue(waitForSelection(of: first))
        title.tap()
        XCTAssertTrue(app.staticTexts["Rename terminal"].waitForExistence(timeout: 2))
    }

    func testTerminalSidebarShowsTheSelectedTerminal() {
        openTerminalDrawer()
        XCTAssertTrue(app.staticTexts["Terminals"].waitForExistence(timeout: 4))
        XCTAssertEqual(drawerRow(firstID).value as? String, "Selected")
    }

    func testBottomBarStartsCompactAndTogglesKeyboard() {
        let first = terminalSurface(firstID)
        XCTAssertTrue(first.waitForExistence(timeout: 3))
        let keyboard = app.buttons["terminal-keyboard-button"]
        XCTAssertFalse(keyboard.exists)
        XCTAssertTrue(app.buttons["down"].exists)
        XCTAssertTrue(app.buttons["up"].exists)
        XCTAssertTrue(app.buttons["enter"].exists)
        first.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        XCTAssertTrue(keyboard.waitForExistence(timeout: 2))
        XCTAssertEqual(keyboard.label, "Hide keyboard")
        keyboard.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
    }

    func testTappingTerminalShowsKeyboard() {
        terminalSurface(firstID).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        XCTAssertEqual(app.buttons["terminal-keyboard-button"].label, "Hide keyboard")
    }

    func testKeyboardShowsFixedDownUpEnterToolbar() {
        terminalSurface(firstID).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        let down = app.buttons["down"]
        let up = app.buttons["up"]
        let enter = app.buttons["enter"]
        XCTAssertTrue(down.exists)
        XCTAssertTrue(up.exists)
        XCTAssertTrue(enter.exists)
        XCTAssertLessThan(down.frame.minX, up.frame.minX)
        XCTAssertLessThan(up.frame.minX, enter.frame.minX)
        XCTAssertTrue(app.buttons["escape"].exists)
        XCTAssertTrue(app.buttons["shift"].exists)
    }

    func testHeaderExposesOnlyNewTerminalAction() {
        XCTAssertTrue(app.buttons["new-terminal-button"].exists)
        XCTAssertFalse(app.buttons["shortcuts-button"].exists)
    }

    func testTerminalStartsBelowCompactNavigationBar() {
        let terminal = terminalSurface(firstID)
        XCTAssertTrue(terminal.waitForExistence(timeout: 3))

        let title = app.buttons["terminal-title-button"]
        XCTAssertLessThanOrEqual(title.frame.height, 44)
        XCTAssertGreaterThanOrEqual(terminal.frame.minY, title.frame.maxY)
    }

    func testTerminalTitleOpensRenameInsteadOfSettings() {
        app.buttons["terminal-title-button"].tap()
        XCTAssertTrue(app.staticTexts["Rename terminal"].waitForExistence(timeout: 2))
        app.buttons["Cancel"].tap()
        XCTAssertFalse(app.navigationBars["Settings"].exists)
    }

    func testKeyboardDismissalThenPagingRemainAvailable() {
        let first = terminalSurface(firstID)
        first.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        let keyboard = app.buttons["terminal-keyboard-button"]
        XCTAssertTrue(keyboard.waitForExistence(timeout: 2))
        keyboard.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        openTerminalDrawer()
        drawerRow(secondID).coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)).tap()
        XCTAssertTrue(waitForSelection(of: terminalSurface(secondID)))
    }

    func testDrawerRowSelectionOutsideMenu() {
        openTerminalDrawer()
        drawerRow(secondID).coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)).tap()
        XCTAssertEqual(terminalSurface(secondID).value as? String, "Selected")
    }

    func testConnectionDetailsContainSafeTrustAndReplayMessaging() {
        openTerminalDrawer()
        app.buttons["drawer-settings-button"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 2))
        XCTAssertTrue(text(containing: "Open Terminals").exists)
        XCTAssertTrue(text(containing: "Active Terminals").exists)
        let connection = app.buttons.matching(
            NSPredicate(
                format: "label CONTAINS %@ AND identifier != %@",
                "Test Mac",
                "drawer-settings-button"
            )
        ).firstMatch
        XCTAssertTrue(connection.waitForExistence(timeout: 3))
        connection.tap()
        let details = app.descendants(matching: .any)["connection-details-list"]
        XCTAssertTrue(details.waitForExistence(timeout: 3))
        XCTAssertTrue(revealText("Local network", in: details))
        XCTAssertTrue(revealText("Some output produced while disconnected was discarded.", in: details))
        XCTAssertTrue(revealText("Verified", in: details))
        XCTAssertTrue(revealElement("connection-transport-value", in: details))
        XCTAssertTrue(revealElement("connection-authentication-value", in: details))
    }

    func testDrawerUsesNativeRenameDisconnectAndDeleteSwipeActions() {
        openTerminalDrawer()
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
        openTerminalDrawer()
        XCTAssertTrue(app.images["terminal-status-\(firstID)"].exists)
        XCTAssertTrue(app.images["catalog-terminal-status-00000000-0000-0000-0000-000000000003"].exists)
        XCTAssertTrue(app.staticTexts["Detached shell"].exists)
        XCTAssertFalse(app.staticTexts["Available on this Mac"].exists)
    }

    func testDeleteAllPermanentlyEndsLocalCliveTerminals() {
        openTerminalDrawer()
        app.buttons["Terminal actions"].tap()
        app.buttons["Delete All"].tap()
        XCTAssertTrue(app.staticTexts["Delete all terminals?"].waitForExistence(timeout: 2))
        XCTAssertTrue(text(containing: "permanently ends every Clive terminal").exists)
        app.buttons["Cancel"].tap()
    }

    func testShortcutsOpenFromBottomControlRunAndRestoreKeyboardState() {
        terminalSurface(firstID).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        app.buttons["terminal-shortcuts-button"].tap()
        let shortcut = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Status")).firstMatch
        XCTAssertTrue(shortcut.waitForExistence(timeout: 2))
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        shortcut.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
    }

    func testShortcutPanelManageOpensSettingsAfterKeyboardWasVisible() {
        terminalSurface(firstID).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        app.buttons["terminal-shortcuts-button"].tap()
        XCTAssertTrue(app.buttons["manage-shortcuts-button"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.navigationBars["Shortcuts"].exists)
        XCTAssertFalse(app.buttons["Done"].exists)
        app.buttons["manage-shortcuts-button"].tap()
        XCTAssertTrue(app.navigationBars["Shortcuts"].waitForExistence(timeout: 3))
    }

    func testSetupGuideShowsMacInstallAndPairAction() {
        app.terminate()
        app.launchArguments = ["--ui-testing-setup-guide"]
        app.launch()

        XCTAssertTrue(app.staticTexts["Connect Clive to your Mac"].waitForExistence(timeout: 3))
        XCTAssertTrue(text(containing: "brew install --cask brendanwilliam/tap/clive").exists)
        XCTAssertTrue(app.buttons["setup-guide-pair-mac-button"].exists)
    }

    private func terminalSurface(_ id: String) -> XCUIElement {
        app.descendants(matching: .any)["terminal-surface-\(id)"]
    }

    private func drawerRow(_ id: String) -> XCUIElement {
        app.buttons["terminal-row-\(id)"]
    }

    private var terminalDrawerButton: XCUIElement {
        app.buttons["terminal-sidebar-button"]
    }

    private func showFirstTerminalDetail() {
        let first = terminalSurface(firstID)
        if first.waitForExistence(timeout: 2) { return }

        let firstRow = drawerRow(firstID)
        XCTAssertTrue(firstRow.waitForExistence(timeout: 3))
        firstRow.tap()
        XCTAssertTrue(first.waitForExistence(timeout: 3))
    }

    private func openTerminalDrawer() {
        XCTAssertTrue(terminalDrawerButton.waitForExistence(timeout: 3))
        terminalDrawerButton.tap()
        XCTAssertTrue(app.staticTexts["Terminals"].waitForExistence(timeout: 3))
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
            if element.waitForExistence(timeout: 1) { return true }
            scrollView.swipeUp()
        }
        return element.waitForExistence(timeout: 1)
    }

    private func revealElement(_ identifier: String, in scrollView: XCUIElement) -> Bool {
        let element = app.descendants(matching: .any)[identifier]
        for _ in 0..<3 {
            if element.waitForExistence(timeout: 1) { return true }
            scrollView.swipeUp()
        }
        return element.waitForExistence(timeout: 1)
    }
}

private extension XCUIElement {
    func waitForNonExistence(timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "exists == false")
        return XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: self)], timeout: timeout) == .completed
    }
}
