import UIKit
import XCTest
@testable import Clive

@MainActor
final class TerminalKeyboardAccessoryTests: XCTestCase {
    func testKeyboardAndShortcutVisibilityTransitionsRestoreOnlyPriorKeyboardState() {
        var policy = TerminalInputControlPolicy()
        XCTAssertEqual(policy.state, .compact)

        policy.keyboardChanged(visible: true)
        XCTAssertEqual(policy.state, .keyboard)
        policy.keyboardChanged(visible: false)
        XCTAssertEqual(policy.state, .compact)

        policy.keyboardChanged(visible: true)
        policy.openShortcuts()
        XCTAssertEqual(policy.state, .shortcuts)
        policy.dismissShortcuts()
        XCTAssertEqual(policy.state, .keyboard)

        policy.keyboardChanged(visible: false)
        policy.openShortcuts()
        policy.dismissShortcuts()
        XCTAssertEqual(policy.state, .compact)
    }

    func testToolbarStartsWithOnlyDownUpAndEnter() throws {
        let accessory = TerminalKeyboardAccessory(send: { _ in })
        for identifier in ["down", "up", "enter"] {
            XCTAssertNotNil(accessory.descendant(withIdentifier: identifier))
        }
        for removed in ["escape", "tab", "shift", "control", "option", "command", "left", "right"] {
            XCTAssertNil(accessory.descendant(withIdentifier: removed))
        }
    }

    func testToolbarExpandsToTheFullSymbolKeyRow() throws {
        let accessory = TerminalKeyboardAccessory(send: { _ in })
        accessory.setKeyboardVisible(true)
        for identifier in ["escape", "tab", "shift", "control", "option", "command", "left", "down", "up", "right"] {
            XCTAssertNotNil(accessory.descendant(withIdentifier: identifier))
        }
    }

    func testToolbarSendsDownUpAndEnterWithoutModifierState() throws {
        var sent: [Data] = []
        let accessory = TerminalKeyboardAccessory(send: { sent.append($0) })
        for identifier in ["down", "up", "enter"] {
            let button = try XCTUnwrap(accessory.descendant(withIdentifier: identifier) as? UIButton)
            button.sendActions(for: .touchUpInside)
        }
        XCTAssertEqual(sent, [Data("\u{1b}[B".utf8), Data("\u{1b}[A".utf8), Data("\r".utf8)])
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
