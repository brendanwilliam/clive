import UIKit
import XCTest
@testable import Clive

@MainActor
final class TerminalKeyboardAccessoryTests: XCTestCase {
    func testEscapeAppearsImmediatelyBeforeTabAndSendsEscapeByteOnce() throws {
        var sent: [Data] = []
        let accessory = TerminalKeyboardAccessory(send: { sent.append($0) }, command: { _ in })
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
        let accessory = TerminalKeyboardAccessory(send: { _ in }, command: { _ in })
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
        let accessory = TerminalKeyboardAccessory(send: { _ in }, command: { _ in })
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

    func testAdditionalKeysButtonIsFirstAndShortcutButtonIsAbsent() throws {
        let accessory = TerminalKeyboardAccessory(send: { _ in }, command: { _ in })
        let additionalKeys = try XCTUnwrap(accessory.descendant(withIdentifier: "keyboard"))
        let row = try XCTUnwrap(additionalKeys.superview as? UIStackView)

        XCTAssertEqual(row.arrangedSubviews.first, additionalKeys)
        XCTAssertNil(accessory.descendant(withIdentifier: "shortcuts"))
    }

    func testAdditionalKeysButtonTogglesInlinePanel() throws {
        let accessory = TerminalKeyboardAccessory(
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

    func testEveryAdditionalKeySendsItsExpectedInput() throws {
        var sent: [Data] = []
        let accessory = TerminalKeyboardAccessory(send: { sent.append($0) }, command: { _ in })
        let values = ["~", "`", "|", "\\", "{", "}", "[", "]", "(", ")", "<", ">", "=", "*", "#", "^", "_", "-", ";", ":"]

        let additionalKeysButton = try XCTUnwrap(accessory.descendant(withIdentifier: "keyboard") as? UIButton)
        additionalKeysButton.sendActions(for: .touchUpInside)
        for value in values {
            let key = try XCTUnwrap(accessory.descendant(withIdentifier: "special:\(value)") as? UIButton)
            key.sendActions(for: .touchUpInside)
        }

        XCTAssertEqual(sent, values.map { Data($0.utf8) })
    }

    func testTerminalKeyShowsVisualPressedFeedback() throws {
        let accessory = TerminalKeyboardAccessory(
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
