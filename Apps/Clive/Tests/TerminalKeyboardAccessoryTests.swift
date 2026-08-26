import UIKit
import XCTest
@testable import Clive

@MainActor
final class TerminalKeyboardAccessoryTests: XCTestCase {
    func testKeyboardVisibilityTransitionsBetweenCompactAndExpandedControls() {
        var policy = TerminalInputControlPolicy()
        XCTAssertEqual(policy.state, .compact)

        policy.keyboardChanged(visible: true)
        XCTAssertEqual(policy.state, .keyboard)
        policy.keyboardChanged(visible: false)
        XCTAssertEqual(policy.state, .compact)
    }

    func testToolbarStartsWithVerticallyStackedDownUpAndSeparateEnter() throws {
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

    func testBottomControlsDoNotOverlapAtCompactIPhoneOrRegularIPadWidths() {
        for width: CGFloat in [320, 834] {
            let controls = TerminalBottomControls()
            controls.installKeyRow(TerminalKeyboardAccessory(send: { _ in }))
            controls.frame = CGRect(x: 0, y: 0, width: width, height: 48)
            controls.layoutIfNeeded()

            XCTAssertFalse(controls.keyRowControlFrame.intersects(controls.shortcutsControlFrame))
            XCTAssertFalse(controls.isKeyboardControlVisible)
            XCTAssertTrue(controls.isKeyRowControlVisible)
            XCTAssertTrue(controls.isShortcutsControlVisible)
            XCTAssertGreaterThan(controls.keyRowControlFrame.width, 0)
            XCTAssertLessThan(controls.shortcutsControlFrame.maxX, controls.keyRowControlFrame.minX)
            XCTAssertEqual(controls.keyRowControlFrame.maxX, controls.frame.width - 8, accuracy: 0.5)
            XCTAssertEqual((accessoryButton(in: controls, identifier: "enter") as? TerminalKeyButton)?.backgroundColor, .white)

            controls.setKeyboardVisible(true)
            controls.layoutIfNeeded()
            XCTAssertEqual(controls.shortcutsControlFrame.minX, 8, accuracy: 0.5, "shortcuts=\(controls.shortcutsControlFrame), keys=\(controls.keyRowControlFrame), keyboard=\(controls.keyboardControlFrame)")
            XCTAssertFalse(controls.keyboardControlFrame.intersects(controls.keyRowControlFrame))
            XCTAssertFalse(controls.keyRowControlFrame.intersects(controls.shortcutsControlFrame))
            XCTAssertTrue(controls.isKeyboardControlVisible)
            XCTAssertGreaterThan(controls.keyRowControlFrame.width, 0)
            XCTAssertLessThan(controls.shortcutsControlFrame.maxX, controls.keyRowControlFrame.minX)
            XCTAssertLessThan(controls.keyRowControlFrame.maxX, controls.keyboardControlFrame.minX)
        }
    }

    private func accessoryButton(in controls: TerminalBottomControls, identifier: String) -> UIView? {
        func find(_ view: UIView) -> UIView? {
            if view.accessibilityIdentifier == identifier { return view }
            for child in view.subviews {
                if let match = find(child) { return match }
            }
            return nil
        }
        return find(controls)
    }

    func testBottomControlsUseAShortcutMenuWithSettingsLast() {
        let controls = TerminalBottomControls()
        let shortcut = CLIShortcut(name: "Status", command: "git status --short")
        controls.configureShortcutMenu(shortcuts: [shortcut], run: { _ in true }, manage: {})

        XCTAssertTrue(controls.shortcutButton.showsMenuAsPrimaryAction)
        let actions = try! XCTUnwrap(controls.shortcutButton.menu?.children as? [UIAction])
        XCTAssertEqual(actions.map(\.title), ["Status", "Settings"])
        XCTAssertNotNil(actions.first?.image)
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
