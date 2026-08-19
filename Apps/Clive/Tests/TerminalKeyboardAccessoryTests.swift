import UIKit
import XCTest
@testable import Clive

@MainActor
final class TerminalKeyboardAccessoryTests: XCTestCase {
    func testAdditionalKeysPaletteHasCloseButtonThatDismissesIt() throws {
        let accessory = TerminalKeyboardAccessory(
            shortcuts: [],
            send: { _ in },
            command: { _ in }
        )

        let additionalKeysButton = try XCTUnwrap(accessory.descendant(withIdentifier: "keyboard") as? UIButton)
        additionalKeysButton.sendActions(for: .touchUpInside)

        XCTAssertNotNil(accessory.descendant(withIdentifier: "additionalKeysPalette"))
        let closeButton = try XCTUnwrap(accessory.descendant(withIdentifier: "closeAdditionalKeys") as? UIButton)
        XCTAssertEqual(closeButton.accessibilityLabel, "Close additional keys")

        closeButton.sendActions(for: .touchUpInside)

        XCTAssertNil(accessory.descendant(withIdentifier: "additionalKeysPalette"))
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

    func testAccessoryIncludesKeyboardBridgeBelowKeyRow() {
        let accessory = TerminalKeyboardAccessory(
            shortcuts: [],
            send: { _ in },
            command: { _ in }
        )

        XCTAssertNotNil(accessory.descendant(withIdentifier: "keyboardBridge"))
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
