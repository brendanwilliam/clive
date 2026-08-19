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
        var savedCommand: String?
        let accessory = TerminalKeyboardAccessory(
            shortcuts: [],
            saveLastCommand: { savedCommand = $0 },
            send: { _ in },
            command: { _ in }
        )
        let shortcutButton = try XCTUnwrap(accessory.descendant(withIdentifier: "shortcuts") as? UIButton)
        shortcutButton.sendActions(for: .touchUpInside)
        XCTAssertFalse(try XCTUnwrap(accessory.descendant(withIdentifier: "saveLastCommand") as? UIButton).isEnabled)

        accessory.updateLastCommand("git status")

        let saveButton = try XCTUnwrap(accessory.descendant(withIdentifier: "saveLastCommand") as? UIButton)
        XCTAssertTrue(saveButton.isEnabled)
        saveButton.sendActions(for: .touchUpInside)
        XCTAssertEqual(savedCommand, "git status")
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
