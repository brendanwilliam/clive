import UIKit
import XCTest
@testable import Clive

@MainActor
final class TerminalKeyboardAccessoryTests: XCTestCase {
    func testAdditionalKeysButtonTogglesInlinePanel() throws {
        let accessory = TerminalKeyboardAccessory(
            shortcuts: [],
            send: { _ in },
            command: { _ in }
        )

        let additionalKeysButton = try XCTUnwrap(accessory.descendant(withIdentifier: "keyboard") as? UIButton)
        additionalKeysButton.sendActions(for: .touchUpInside)

        XCTAssertNotNil(accessory.descendant(withIdentifier: "additionalKeysPalette"))

        let updatedAdditionalKeysButton = try XCTUnwrap(accessory.descendant(withIdentifier: "keyboard") as? UIButton)
        updatedAdditionalKeysButton.sendActions(for: .touchUpInside)

        XCTAssertNil(accessory.descendant(withIdentifier: "additionalKeysPalette"))
    }

    func testShortcutButtonTogglesInlinePanelAndReplacesAdditionalKeys() throws {
        let accessory = TerminalKeyboardAccessory(
            shortcuts: [],
            send: { _ in },
            command: { _ in }
        )
        let additionalKeysButton = try XCTUnwrap(accessory.descendant(withIdentifier: "keyboard") as? UIButton)
        additionalKeysButton.sendActions(for: .touchUpInside)

        let shortcutButton = try XCTUnwrap(accessory.descendant(withIdentifier: "shortcuts") as? UIButton)
        shortcutButton.sendActions(for: .touchUpInside)

        XCTAssertNil(accessory.descendant(withIdentifier: "additionalKeysPalette"))
        XCTAssertNotNil(accessory.descendant(withIdentifier: "shortcutsPanel"))

        let updatedShortcutButton = try XCTUnwrap(accessory.descendant(withIdentifier: "shortcuts") as? UIButton)
        updatedShortcutButton.sendActions(for: .touchUpInside)
        XCTAssertNil(accessory.descendant(withIdentifier: "shortcutsPanel"))
    }

    func testSaveLastCommandEnablesAfterCommandIsTrackedAndSavesIt() throws {
        var savedName: String?
        var savedCommand: String?
        var saveCount = 0
        let accessory = TerminalKeyboardAccessory(
            shortcuts: [],
            saveLastCommand: { name, command in
                savedName = name
                savedCommand = command
                saveCount += 1
                return true
            },
            send: { _ in },
            command: { _ in }
        )
        let shortcutButton = try XCTUnwrap(accessory.descendant(withIdentifier: "shortcuts") as? UIButton)
        shortcutButton.sendActions(for: .touchUpInside)
        XCTAssertFalse(try XCTUnwrap(accessory.descendant(withIdentifier: "saveLastCommand") as? UIButton).isEnabled)

        accessory.updateLastCommand("git status")

        let saveButton = try XCTUnwrap(accessory.descendant(withIdentifier: "saveLastCommand") as? UIButton)
        XCTAssertTrue(saveButton.isEnabled)
        accessory.confirmLastCommandShortcut(name: "Repository status")

        XCTAssertEqual(savedName, "Repository status")
        XCTAssertEqual(savedCommand, "git status")
        XCTAssertEqual(saveCount, 1)
        XCTAssertFalse(try XCTUnwrap(accessory.descendant(withIdentifier: "saveLastCommand") as? UIButton).isEnabled)
    }

    func testExistingShortcutCommandCannotBeSavedAgain() throws {
        let accessory = TerminalKeyboardAccessory(
            shortcuts: [CLIShortcut(name: "Status", command: "git status")],
            lastCommand: " git status ",
            saveLastCommand: { _, _ in XCTFail("Duplicate should not save"); return true },
            send: { _ in },
            command: { _ in }
        )

        let shortcutButton = try XCTUnwrap(accessory.descendant(withIdentifier: "shortcuts") as? UIButton)
        shortcutButton.sendActions(for: .touchUpInside)

        XCTAssertFalse(try XCTUnwrap(accessory.descendant(withIdentifier: "saveLastCommand") as? UIButton).isEnabled)
        XCTAssertNil(accessory.descendant(withIdentifier: "closePanel"))
    }

    func testTerminalKeyShowsVisualPressedFeedback() throws {
        let accessory = TerminalKeyboardAccessory(
            shortcuts: [],
            send: { _ in },
            command: { _ in }
        )
        let tabButton = try XCTUnwrap(accessory.descendant(withIdentifier: "tab") as? UIButton)
        let restingColor = tabButton.backgroundColor

        tabButton.isHighlighted = true

        XCTAssertNotEqual(tabButton.backgroundColor, restingColor)
        XCTAssertLessThan(tabButton.transform.a, 1)
    }

    func testAccessoryDoesNotInsertSpacerBelowKeyRow() {
        let accessory = TerminalKeyboardAccessory(
            shortcuts: [],
            send: { _ in },
            command: { _ in }
        )

        XCTAssertNil(accessory.descendant(withIdentifier: "keyboardBridge"))
    }
}

private extension UIView {
    func descendant(withIdentifier identifier: String) -> UIView? {
        if accessibilityIdentifier == identifier { return self }
        for subview in subviews {
            if let match = subview.descendant(withIdentifier: identifier) { return match }
        }
        return nil
    }
}
