import UIKit
import XCTest
@testable import Clive

final class WorkspaceNavigationPolicyTests: XCTestCase {
    func testTitleSwipeSelectsAdjacentTerminalWithoutWrapping() {
        let first = UUID(), second = UUID(), last = UUID()
        let terminalIDs = [first, second, last]
        XCTAssertEqual(TerminalTitleNavigationPolicy.adjacentTerminal(from: second, terminalIDs: terminalIDs, direction: .left), last)
        XCTAssertEqual(TerminalTitleNavigationPolicy.adjacentTerminal(from: second, terminalIDs: terminalIDs, direction: .right), first)
        XCTAssertNil(TerminalTitleNavigationPolicy.adjacentTerminal(from: first, terminalIDs: terminalIDs, direction: .right))
        XCTAssertNil(TerminalTitleNavigationPolicy.adjacentTerminal(from: last, terminalIDs: terminalIDs, direction: .left))
    }

    func testTitleSwipeRequiresDistanceAndHorizontalDominance() {
        XCTAssertEqual(TerminalTitleNavigationPolicy.direction(translation: CGSize(width: 50, height: 10)), .right)
        XCTAssertEqual(TerminalTitleNavigationPolicy.direction(translation: CGSize(width: -50, height: 10)), .left)
        XCTAssertNil(TerminalTitleNavigationPolicy.direction(translation: CGSize(width: 30, height: 0)))
        XCTAssertNil(TerminalTitleNavigationPolicy.direction(translation: CGSize(width: 50, height: 48)))
    }

    func testTerminalDoubleTapRegionsMapToOneKeyEach() {
        XCTAssertEqual(TerminalContentGesturePolicy.region(forDoubleTapAt: 10, height: 90), .up)
        XCTAssertEqual(TerminalContentGesturePolicy.region(forDoubleTapAt: 45, height: 90), .enter)
        XCTAssertEqual(TerminalContentGesturePolicy.region(forDoubleTapAt: 80, height: 90), .down)
        XCTAssertEqual(TerminalContentGesturePolicy.input(for: .up), Data("\u{1b}[A".utf8))
        XCTAssertEqual(TerminalContentGesturePolicy.input(for: .enter), Data("\r".utf8))
        XCTAssertEqual(TerminalContentGesturePolicy.input(for: .down), Data("\u{1b}[B".utf8))
        XCTAssertNil(TerminalContentGesturePolicy.region(forDoubleTapAt: 0, height: 0))
    }

    func testTerminalKeepsScrollHistoryConfiguration() {
        XCTAssertEqual(TerminalSurfaceConfiguration.keyboardDismissMode, .none)
        XCTAssertFalse(TerminalSurfaceConfiguration.scrollsToTop)
        XCTAssertEqual(TerminalSurfaceConfiguration.contentPadding, 2)
    }

    func testDrawerRevealPolicyOpensClosesAndKeepsOneRowOpen() {
        let first = UUID(); let second = UUID()
        XCTAssertEqual(DrawerRowRevealPolicy.revealedRow(current: nil, row: first, translation: -31), first)
        XCTAssertEqual(DrawerRowRevealPolicy.toggle(current: first, row: second), second)
        XCTAssertNil(DrawerRowRevealPolicy.revealedRow(current: first, row: first, translation: 31))
        XCTAssertEqual(DrawerRowRevealPolicy.revealWidth, DrawerRowRevealPolicy.actionWidth * 2)
        XCTAssertEqual(DrawerRowRevealPolicy.minimumRowHeight, 48)
        XCTAssertEqual(DrawerRowRevealPolicy.rowSpacing, 0)
    }

    func testConnectionStatusAndRoutesHaveStablePresentation() {
        XCTAssertEqual(ConnectionPresentation.status(for: .connecting), .connecting)
        XCTAssertEqual(ConnectionPresentation.status(for: .reconnecting(waitingForWiFi: true)), .reconnecting)
        XCTAssertEqual(ConnectionPresentation.status(for: .certificateChanged), .attention)
        XCTAssertEqual(ConnectionPresentation.status(for: nil), .disconnected)
        XCTAssertEqual(ConnectionPresentation.routeLabel(for: .lan), "Local network")
        XCTAssertEqual(ConnectionPresentation.routeLabel(for: .privateVPN), "Private VPN")
    }

    func testConnectionPresentationCoversHealthTrustAndReplayStates() {
        let active = ConnectionStatusPresentation.make(state: .active(UUID(), .created, false), deviceName: "Mac", route: .lan)
        XCTAssertEqual(active.text, "Connected"); XCTAssertEqual(active.certificatePin, "Verified")
        XCTAssertEqual(ConnectionStatusPresentation.make(state: .connecting, deviceName: "Mac", route: nil).text, "Connecting")
        XCTAssertEqual(ConnectionStatusPresentation.make(state: .reconnecting(waitingForWiFi: true), deviceName: "Mac", route: nil).text, "Reconnecting")
        XCTAssertEqual(ConnectionStatusPresentation.make(state: .disconnected, deviceName: "Mac", route: nil).text, "Offline")
        XCTAssertEqual(ConnectionStatusPresentation.make(state: .revoked, deviceName: "Mac", route: nil).text, "Revoked")
        XCTAssertEqual(ConnectionStatusPresentation.make(state: .certificateChanged, deviceName: "Mac", route: nil).certificatePin, "Mismatch")
        XCTAssertEqual(ConnectionStatusPresentation.make(state: .protocolError, deviceName: "Mac", route: nil).text, "Protocol error")
        XCTAssertNotNil(ConnectionStatusPresentation.make(state: .active(UUID(), .resumed, true), deviceName: "Mac", route: .privateVPN).replayWarning)
    }

    func testFingerprintIsUppercaseColonSeparatedAndCopyable() {
        XCTAssertEqual(FingerprintFormatter.formatted("aabb01ff"), "AA:BB:01:FF")
        XCTAssertEqual(FingerprintFormatter.formatted("AA:bb 01-ff"), "AA:BB:01:FF")
    }

    func testShortcutExecutionAppendsExactlyOneReturn() {
        XCTAssertEqual(ShortcutExecutionPolicy.payload(for: "git status"), Data("git status\r".utf8))
        XCTAssertTrue(ShortcutExecutionPolicy.canRun(command: "git status", state: .active(UUID(), .created, false)))
        XCTAssertFalse(ShortcutExecutionPolicy.canRun(command: "git status", state: .connecting))
        XCTAssertFalse(ShortcutExecutionPolicy.canRun(command: "  ", state: .active(UUID(), .created, false)))
    }
}
