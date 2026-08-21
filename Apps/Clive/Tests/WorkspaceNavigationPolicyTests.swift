import UIKit
import XCTest
@testable import Clive

final class WorkspaceNavigationPolicyTests: XCTestCase {
    func testBoundaryActionsOnlyOccurAtOuterTerminals() {
        XCTAssertEqual(TerminalBoundaryGesturePolicy.action(direction: .right, isFirstTerminal: true, isLastTerminal: false), .openDrawer)
        XCTAssertEqual(TerminalBoundaryGesturePolicy.action(direction: .left, isFirstTerminal: false, isLastTerminal: true), .createTerminal)
        XCTAssertNil(TerminalBoundaryGesturePolicy.action(direction: .right, isFirstTerminal: false, isLastTerminal: true))
        XCTAssertNil(TerminalBoundaryGesturePolicy.action(direction: .left, isFirstTerminal: true, isLastTerminal: false))
    }

    func testBoundaryGatePreventsDuplicateActionsUntilReset() {
        var gate = TerminalBoundaryGestureGate()
        XCTAssertEqual(gate.takeAction(direction: .left, isFirstTerminal: false, isLastTerminal: true), .createTerminal)
        XCTAssertNil(gate.takeAction(direction: .left, isFirstTerminal: false, isLastTerminal: true))
        gate.reset()
        XCTAssertEqual(gate.takeAction(direction: .left, isFirstTerminal: false, isLastTerminal: true), .createTerminal)
    }

    func testTerminalUsesInteractiveKeyboardDismissal() {
        XCTAssertEqual(TerminalSurfaceConfiguration.keyboardDismissMode, .interactive)
    }

    func testDrawerRevealPolicyOpensClosesAndKeepsOneRowOpen() {
        let first = UUID(); let second = UUID()
        XCTAssertEqual(DrawerRowRevealPolicy.revealedRow(current: nil, row: first, translation: -31), first)
        XCTAssertEqual(DrawerRowRevealPolicy.toggle(current: first, row: second), second)
        XCTAssertNil(DrawerRowRevealPolicy.revealedRow(current: first, row: first, translation: 31))
        XCTAssertEqual(DrawerRowRevealPolicy.revealWidth, DrawerRowRevealPolicy.actionWidth * 2)
    }

    func testConnectionStatusAndRoutesHaveStablePresentation() {
        XCTAssertEqual(ConnectionPresentation.status(for: .connecting), .connecting)
        XCTAssertEqual(ConnectionPresentation.status(for: .reconnecting(waitingForWiFi: true)), .reconnecting)
        XCTAssertEqual(ConnectionPresentation.status(for: .certificateChanged), .attention)
        XCTAssertEqual(ConnectionPresentation.status(for: nil), .disconnected)
        XCTAssertEqual(ConnectionPresentation.routeLabel(for: .lan), "Local network")
        XCTAssertEqual(ConnectionPresentation.routeLabel(for: .privateVPN), "Private VPN")
    }

    func testFingerprintIsUppercaseColonSeparatedAndCopyable() {
        XCTAssertEqual(FingerprintFormatter.formatted("aabb01ff"), "AA:BB:01:FF")
        XCTAssertEqual(FingerprintFormatter.formatted("AA:bb 01-ff"), "AA:BB:01:FF")
    }

    func testShortcutExecutionAppendsExactlyOneReturn() {
        XCTAssertEqual(ShortcutExecutionPolicy.payload(for: "git status"), Data("git status\r".utf8))
    }
}
