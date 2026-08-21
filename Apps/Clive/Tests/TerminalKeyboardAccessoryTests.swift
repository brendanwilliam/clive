import UIKit
import XCTest
@testable import Clive

@MainActor
final class TerminalKeyboardAccessoryTests: XCTestCase {
    func testEscapeAppearsImmediatelyBeforeTabAndSendsEscapeByteOnce() throws {
        var sent: [Data] = []
        let accessory = TerminalKeyboardAccessory(shortcuts: [], send: { sent.append($0) }, command: { _ in })
        let escape = try XCTUnwrap(accessory.descendant(withIdentifier: "escape") as? UIButton)
        let tab = try XCTUnwrap(accessory.descendant(withIdentifier: "tab"))
        let row = try XCTUnwrap(escape.superview as? UIStackView)
        let escapeIndex = try XCTUnwrap(row.arrangedSubviews.firstIndex(of: escape))

        XCTAssertEqual(row.arrangedSubviews[escapeIndex + 1], tab)

        let shift = try XCTUnwrap(accessory.descendant(withIdentifier: "shift") as? UIButton)
        shift.sendActions(for: .touchUpInside)
        escape.sendActions(for: .touchUpInside)

        XCTAssertEqual(sent, [Data([0x1b])])
    }

    func testKeyRowUsesInsetCapsuleWithPlainRestingKeys() throws {
        let accessory = TerminalKeyboardAccessory(shortcuts: [], send: { _ in }, command: { _ in })
        accessory.frame = CGRect(x: 0, y: 0, width: 320, height: 48)
        accessory.layoutIfNeeded()
        let capsule = try XCTUnwrap(accessory.descendant(withIdentifier: "terminalKeyCapsule") as? UIVisualEffectView)
        let escape = try XCTUnwrap(accessory.descendant(withIdentifier: "escape") as? UIButton)

        XCTAssertEqual(capsule.frame.minX, 8, accuracy: 0.5)
        XCTAssertEqual(capsule.frame.maxX, 312, accuracy: 0.5)
        XCTAssertEqual(capsule.layer.cornerRadius, 20)
        XCTAssertEqual(escape.backgroundColor, .clear)

        escape.isHighlighted = true

        XCTAssertNotEqual(escape.backgroundColor, .clear)
    }

    func testNarrowKeyRowKeepsAllKeysReachableByScrolling() throws {
        let accessory = TerminalKeyboardAccessory(shortcuts: [], send: { _ in }, command: { _ in })
        accessory.frame = CGRect(x: 0, y: 0, width: 320, height: 48)
        accessory.layoutIfNeeded()
        let escape = try XCTUnwrap(accessory.descendant(withIdentifier: "escape"))
        let dollar = try XCTUnwrap(accessory.descendant(withIdentifier: "$"))
        let row = try XCTUnwrap(escape.superview as? UIStackView)
        let scroll = try XCTUnwrap(row.superview as? UIScrollView)

        XCTAssertGreaterThan(scroll.contentSize.width, scroll.bounds.width)
        XCTAssertGreaterThanOrEqual(escape.frame.minX, 0)
        XCTAssertLessThanOrEqual(dollar.frame.maxX, scroll.contentSize.width)
    }

    func testAdditionalKeysButtonIsSecondAfterShortcuts() throws {
        let accessory = TerminalKeyboardAccessory(shortcuts: [], send: { _ in }, command: { _ in })
        let shortcuts = try XCTUnwrap(accessory.descendant(withIdentifier: "shortcuts"))
        let additionalKeys = try XCTUnwrap(accessory.descendant(withIdentifier: "keyboard"))
        let row = try XCTUnwrap(shortcuts.superview as? UIStackView)

        XCTAssertEqual(row.arrangedSubviews.first, shortcuts)
        XCTAssertEqual(row.arrangedSubviews.dropFirst().first, additionalKeys)
    }

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
