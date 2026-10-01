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

    func testCompactToolbarHasOnlyEnterWithDirectionalCueAndAccessibleActions() throws {
        let accessory = TerminalKeyboardAccessory(send: { _ in })
        let enter = try XCTUnwrap(accessory.descendant(withIdentifier: "enter") as? ActionWheelControl)
        XCTAssertEqual(enter.accessibilityHint, "Tap for Enter. Swipe nearby for arrows, or hold and drag for the wheel.")
        XCTAssertEqual(enter.accessibilityCustomActions?.map(\.name), ["Up", "Down", "Left", "Right"])
        XCTAssertGreaterThanOrEqual(enter.subviews.compactMap { $0 as? UIImageView }.count, 4)
        XCTAssertNil(enter.image(for: .normal))
        let container = TerminalSurfaceContainer(frame: CGRect(x: 0, y: 0, width: 320, height: 640))
        container.installKeyRow(accessory)
        container.layoutIfNeeded()
        let hint = try XCTUnwrap(container.descendant(withIdentifier: "enter-swipe-hint") as? UILabel)
        let controls = try XCTUnwrap(container.subviews.compactMap { $0 as? TerminalBottomControls }.first)
        XCTAssertNil(accessory.descendant(withIdentifier: "enter-swipe-hint"))
        XCTAssertEqual(hint.frame.minY, controls.frame.maxY + 4, accuracy: 0.5)
        XCTAssertFalse(hint.isUserInteractionEnabled)
        XCTAssertTrue(hint.attributedText?.string.contains("Tap for Enter") == true)
        XCTAssertTrue(hint.attributedText?.string.contains("Swipe for arrows") == true)
        let attributedHint = try XCTUnwrap(hint.attributedText)
        var attachmentCount = 0
        attributedHint.enumerateAttribute(.attachment, in: NSRange(location: 0, length: attributedHint.length)) { value, _, _ in
            if value != nil { attachmentCount += 1 }
        }
        XCTAssertEqual(attachmentCount, 2)
        for removed in ["escape", "tab", "shift", "control", "option", "command", "left", "right", "down", "up"] {
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

    func testAccessibleArrowActionsUseExistingSequences() throws {
        var sent: [Data] = []
        let accessory = TerminalKeyboardAccessory(send: { sent.append($0) })
        let enter = try XCTUnwrap(accessory.descendant(withIdentifier: "enter") as? ActionWheelControl)
        for action in try XCTUnwrap(enter.accessibilityCustomActions) {
            XCTAssertTrue(action.actionHandler?(action) == true)
        }
        XCTAssertEqual(sent, [TerminalWheelKey.up, .down, .left, .right].map(\.input))
    }

    func testPrimaryAccessibilityActionSendsEnter() throws {
        var sent: [Data] = []
        let accessory = TerminalKeyboardAccessory(send: { sent.append($0) })
        let enter = try XCTUnwrap(accessory.descendant(withIdentifier: "enter") as? ActionWheelControl)
        XCTAssertTrue(enter.accessibilityActivate())
        XCTAssertEqual(sent, [TerminalWheelKey.enter.input])
    }

    func testNearbySwipesSendOneArrowWithoutOpeningWheel() {
        var sent: [Data] = []
        let container = TerminalSurfaceContainer(frame: CGRect(x: 0, y: 0, width: 320, height: 640))
        let accessory = TerminalKeyboardAccessory(send: { sent.append($0) })
        container.installKeyRow(accessory)
        container.layoutIfNeeded()
        let button = accessory.compactEnterButton.convert(accessory.compactEnterButton.bounds, to: container)
        let starts = [
            CGPoint(x: button.maxX + 10, y: button.midY),
            CGPoint(x: button.midX, y: button.maxY + 10),
            CGPoint(x: button.minX - 10, y: button.midY),
            CGPoint(x: button.midX, y: button.minY - 10),
        ]
        let movements = [CGPoint(x: 40, y: 0), CGPoint(x: 0, y: 40),
                         CGPoint(x: -40, y: 0), CGPoint(x: 0, y: -40)]
        for (start, movement) in zip(starts, movements) {
            container.sendNearbyArrow(from: start, to: CGPoint(x: start.x + movement.x, y: start.y + movement.y))
        }
        container.sendNearbyArrow(from: starts[0], to: CGPoint(x: starts[0].x + 20, y: starts[0].y + 20))
        XCTAssertEqual(sent, [TerminalWheelKey.right, .down, .left, .up].map(\.input))
        XCTAssertNil(container.descendant(withIdentifier: "terminal-action-wheel"))
        let above = CGPoint(x: button.midX, y: button.minY - 90)
        container.sendNearbyArrow(from: above, to: CGPoint(x: button.midX, y: button.maxY + 10))
        XCTAssertEqual(sent.last, TerminalWheelKey.down.input)
        XCTAssertEqual(sent.count, 5)
        accessory.setKeyboardVisible(true)
        container.sendNearbyArrow(from: starts[0], to: CGPoint(x: starts[0].x + 40, y: starts[0].y))
        XCTAssertEqual(sent.count, 5)
    }

    func testNearbySwipeCanStartAboveAndCrossEnterWithoutCapturingAdjacentControls() {
        let button = CGRect(x: 104, y: 500, width: 112, height: 56)
        let bounds = CGRect(x: 0, y: 0, width: 320, height: 640)
        XCTAssertTrue(TerminalNearbyArrowPolicy.accepts(CGPoint(x: 80, y: 528), around: button, within: bounds))
        XCTAssertTrue(TerminalNearbyArrowPolicy.accepts(CGPoint(x: 160, y: 580), around: button, within: bounds))
        XCTAssertTrue(TerminalNearbyArrowPolicy.accepts(CGPoint(x: 160, y: 400), around: button, within: bounds))
        for point in [CGPoint(x: 160, y: 528), CGPoint(x: 40, y: 528), CGPoint(x: 280, y: 528)] {
            XCTAssertFalse(TerminalNearbyArrowPolicy.accepts(point, around: button, within: bounds))
        }
        XCTAssertEqual(TerminalNearbyArrowPolicy.key(from: CGPoint(x: 160, y: 400), to: CGPoint(x: 160, y: 580), around: button), .down)
        XCTAssertNil(TerminalNearbyArrowPolicy.key(from: CGPoint(x: 232, y: 400), to: CGPoint(x: 232, y: 580), around: button))
        XCTAssertNil(TerminalNearbyArrowPolicy.key(from: CGPoint(x: 160, y: 400), to: CGPoint(x: 160, y: 475), around: button))
        XCTAssertNil(TerminalNearbyArrowPolicy.key(from: CGPoint(x: 160, y: 528), to: CGPoint(x: 160, y: 580), around: button))
        XCTAssertNil(TerminalNearbyArrowPolicy.key(for: CGPoint(x: 20, y: 20)))
        XCTAssertNil(TerminalNearbyArrowPolicy.key(for: CGPoint(x: 10, y: 0)))
    }

    func testWheelTapHoldAndAllFourDirections() {
        var gesture = ActionWheelGesture()
        gesture.begin(at: 1)
        XCTAssertFalse(gesture.canPresentWheel(at: 1.34))
        XCTAssertTrue(gesture.canPresentWheel(at: 1.35))
        XCTAssertEqual(gesture.end(.zero, at: 1.34), .primary)
        gesture.begin(at: 1.5)
        XCTAssertEqual(gesture.end(CGPoint(x: 6, y: 0), at: 1.6), .primary)
        gesture.begin(at: 2)
        XCTAssertTrue(gesture.canPresentWheel(at: 2.36))
        XCTAssertNil(gesture.end(.zero, at: 2.36))
        gesture.begin(at: 2.5)
        gesture.move(CGPoint(x: 12, y: 0))
        XCTAssertTrue(gesture.canPresentWheel(at: 3))
        XCTAssertNil(gesture.end(.zero, at: 2.6), "A short swipe back to center cannot become Enter")
        for (point, key) in [
            (CGPoint(x: 0, y: -35), ActionWheelDirection.up),
            (CGPoint(x: 0, y: 35), .down),
            (CGPoint(x: -35, y: 0), .left),
            (CGPoint(x: 35, y: 0), .right),
        ] {
            gesture.begin(at: 3)
            XCTAssertEqual(gesture.end(point, at: 3.1), .direction(key))
            XCTAssertFalse(gesture.isActive)
            XCTAssertNil(gesture.end(point, at: 3.2), "One gesture sends only once")
        }
    }

    func testWheelUsesFourNinetyDegreeSectors() {
        let choices: [(CGPoint, ActionWheelDirection)] = [
            (CGPoint(x: 40, y: 39), .right), (CGPoint(x: 39, y: 40), .down),
            (CGPoint(x: -39, y: 40), .down), (CGPoint(x: -40, y: 39), .left),
            (CGPoint(x: -40, y: -39), .left), (CGPoint(x: -39, y: -40), .up),
            (CGPoint(x: 39, y: -40), .up), (CGPoint(x: 40, y: -39), .right),
        ]
        for (point, expected) in choices {
            XCTAssertEqual(ActionWheelDirection.forDisplacement(point), expected)
            var gesture = ActionWheelGesture()
            gesture.begin(at: 1)
            gesture.move(point)
            XCTAssertEqual(gesture.selection, expected)
            XCTAssertEqual(gesture.end(point, at: 1.2), .direction(expected))
        }
        let wheel = ActionWheelView(frame: CGRect(x: 0, y: 0, width: 160, height: 160))
        XCTAssertEqual(wheel.segmentCount, 4)
        XCTAssertGreaterThan(wheel.segmentBounds(for: .right)?.minX ?? 0, 80)
        XCTAssertLessThan(wheel.segmentBounds(for: .left)?.maxX ?? 160, 80)
        XCTAssertLessThan(wheel.segmentBounds(for: .up)?.maxY ?? 160, 80)
        XCTAssertGreaterThan(wheel.segmentBounds(for: .down)?.minY ?? 0, 80)
        wheel.update(direction: .left, finger: CGPoint(x: 32, y: 80))
        XCTAssertEqual(wheel.selectedDirection, .left)
        XCTAssertTrue(wheel.hasVisibleDragLine)
        XCTAssertNotNil(wheel.descendant(withIdentifier: "action-wheel-cancel"))
        wheel.update(direction: nil, finger: CGPoint(x: 80, y: 80))
        XCTAssertFalse(wheel.hasVisibleDragLine)
    }

    func testWheelStaysAvailableAfterSwipeAndLongDragUntilRelease() {
        var gesture = ActionWheelGesture()
        gesture.begin(at: 1)
        gesture.move(CGPoint(x: 30, y: 0))
        XCTAssertEqual(gesture.selection, .right)
        XCTAssertFalse(gesture.canPresentWheel(at: 1.34))
        XCTAssertTrue(gesture.canPresentWheel(at: 1.35), "Swiping first does not prevent the wheel from appearing")
        gesture.move(CGPoint(x: 180, y: 0))
        XCTAssertEqual(gesture.selection, .right)
        XCTAssertTrue(gesture.isActive)
        XCTAssertTrue(gesture.canPresentWheel(at: 1.5))
        XCTAssertEqual(gesture.end(CGPoint(x: 180, y: 0), at: 1.5), .direction(.right))
        XCTAssertFalse(gesture.canPresentWheel(at: 1.6))
        XCTAssertNil(gesture.end(CGPoint(x: 180, y: 0), at: 1.6), "Release sends one arrow")

        gesture.begin(at: 2)
        gesture.move(CGPoint(x: 180, y: 0))
        gesture.move(.zero)
        XCTAssertTrue(gesture.canPresentWheel(at: 2.4))
        XCTAssertNil(gesture.end(.zero, at: 2.4), "Returning to center cancels input only on release")
        gesture.begin(at: 3)
        gesture.cancel()
        XCTAssertFalse(gesture.canPresentWheel(at: 3.4))
        XCTAssertNil(gesture.end(CGPoint(x: 30, y: 0), at: 3.1))
    }

    func testWheelOverlayAppearsAndDismissesAboveCompactBar() {
        let container = TerminalSurfaceContainer(frame: CGRect(x: 0, y: 0, width: 320, height: 640))
        let accessory = TerminalKeyboardAccessory(send: { _ in })
        container.installKeyRow(accessory)
        container.layoutIfNeeded()
        XCTAssertNil(container.descendant(withIdentifier: "terminal-action-wheel"))
        accessory.wheelChanged?(ActionWheelPreview(direction: nil, displacement: .zero))
        let centeredWheel = container.descendant(withIdentifier: "terminal-action-wheel") as? ActionWheelView
        XCTAssertFalse(centeredWheel?.hasVisibleDragLine ?? true)
        XCTAssertNil(centeredWheel?.selectedDirection)
        accessory.wheelChanged?(ActionWheelPreview(direction: .up, displacement: CGPoint(x: 0, y: -38)))
        let wheel = container.descendant(withIdentifier: "terminal-action-wheel") as? ActionWheelView
        XCTAssertNotNil(wheel)
        XCTAssertEqual(wheel?.bounds.size, CGSize(width: 160, height: 160))
        XCTAssertEqual(wheel?.isUserInteractionEnabled, false)
        XCTAssertGreaterThanOrEqual(wheel?.frame.minX ?? -1, 0)
        XCTAssertEqual(wheel?.selectedDirection, .up)
        XCTAssertTrue(wheel?.hasVisibleDragLine == true)
        accessory.wheelChanged?(ActionWheelPreview(direction: .right, displacement: CGPoint(x: 180, y: 0)))
        XCTAssertNotNil(container.descendant(withIdentifier: "terminal-action-wheel"))
        XCTAssertEqual(wheel?.selectedDirection, .right)
        accessory.wheelChanged?(nil)
        XCTAssertNil(container.descendant(withIdentifier: "terminal-action-wheel"))
        accessory.wheelChanged?(ActionWheelPreview(direction: .left, displacement: CGPoint(x: -38, y: 0)))
        accessory.setKeyboardVisible(true)
        XCTAssertNil(container.descendant(withIdentifier: "terminal-action-wheel"))
    }

    func testShiftTabSendsReverseTabSequence() throws {
        var sent: [Data] = []
        let accessory = TerminalKeyboardAccessory(send: { sent.append($0) })
        accessory.setKeyboardVisible(true)
        let shift = try XCTUnwrap(accessory.descendant(withIdentifier: "shift") as? UIButton)
        let tab = try XCTUnwrap(accessory.descendant(withIdentifier: "tab") as? UIButton)
        shift.sendActions(for: .touchUpInside)
        tab.sendActions(for: .touchUpInside)
        XCTAssertEqual(sent, [Data("\u{1b}[Z".utf8)])
    }

    func testControlCSendsInterruptByte() throws {
        var sent: [Data] = []
        let accessory = TerminalKeyboardAccessory(send: { sent.append($0) })
        accessory.setKeyboardVisible(true)
        let control = try XCTUnwrap(accessory.descendant(withIdentifier: "control") as? UIButton)
        let c = try XCTUnwrap(accessory.descendant(withIdentifier: "c") as? UIButton)
        control.sendActions(for: .touchUpInside)
        c.sendActions(for: .touchUpInside)
        XCTAssertEqual(sent, [Data([0x03])])
    }

    func testBottomControlsDoNotOverlapAtCompactIPhoneOrRegularIPadWidths() throws {
        for width: CGFloat in [320, 834] {
            let controls = TerminalBottomControls()
            controls.installKeyRow(TerminalKeyboardAccessory(send: { _ in }))
            controls.frame = CGRect(x: 0, y: 0, width: width, height: 80)
            controls.layoutIfNeeded()

            XCTAssertFalse(controls.keyRowControlFrame.intersects(controls.shortcutsControlFrame))
            XCTAssertTrue(controls.isKeyboardControlVisible)
            XCTAssertTrue(controls.isKeyRowControlVisible)
            XCTAssertTrue(controls.isShortcutsControlVisible)
            XCTAssertGreaterThan(controls.keyRowControlFrame.width, 0)
            XCTAssertLessThan(controls.shortcutsControlFrame.maxX, controls.keyRowControlFrame.minX)
            XCTAssertEqual(controls.keyRowControlFrame.maxX, controls.keyboardControlFrame.minX - 4, accuracy: 0.5)
            let enter = try XCTUnwrap(accessoryButton(in: controls, identifier: "enter") as? ActionWheelControl)
            XCTAssertEqual(enter.backgroundColor, .white)
            XCTAssertEqual(enter.title(for: .normal), "Enter")
            XCTAssertEqual(controls.keyRowControlFrame.height, 76, accuracy: 0.5)
            XCTAssertEqual(enter.bounds.width, 112, accuracy: 0.5)
            XCTAssertEqual(enter.bounds.height, 56, accuracy: 0.5)
            XCTAssertEqual(enter.convert(enter.bounds, to: controls).midX, controls.bounds.midX, accuracy: 0.5)

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
        XCTAssertEqual(actions.first?.subtitle, "git status --short")
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
