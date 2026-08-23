import UIKit
import XCTest
@testable import Clive

final class WorkspaceNavigationPolicyTests: XCTestCase {
    func testPagerSelectsNormalPagesBidirectionally() {
        let first = UUID(), last = UUID(); var policy = TerminalPagerPolicy()
        XCTAssertEqual(policy.transition(to: .terminal(last), terminalIDs: [first, last]), .select(last))
        XCTAssertEqual(policy.transition(to: .terminal(first), terminalIDs: [first, last]), .select(first))
    }

    func testPagerRestoresFirstPageBeforeOpeningDrawer() {
        let first = UUID(), last = UUID(); var policy = TerminalPagerPolicy()
        XCTAssertEqual(policy.transition(to: .leading, terminalIDs: [first, last]), .openDrawer(restoring: first))
        XCTAssertEqual(policy.transition(to: .leading, terminalIDs: [first, last]), .restore(first))
    }

    func testPagerCreatesAtTrailingBoundary() {
        let first = UUID(), last = UUID(); var policy = TerminalPagerPolicy()
        XCTAssertEqual(policy.transition(to: .trailing, terminalIDs: [first, last]), .createTerminal)
    }

    func testPagerKeepsDrawerAndNewTerminalGesturesAvailableWithoutSessions() {
        var policy = TerminalPagerPolicy()
        XCTAssertEqual(policy.transition(to: .leading, terminalIDs: []), .openDrawer(restoring: nil))
        XCTAssertEqual(policy.transition(to: .trailing, terminalIDs: []), .createTerminal)
    }

    func testPagerPreventsDuplicateSentinelEventsAndCreatesOnlyOnce() {
        let first = UUID(), last = UUID(); var policy = TerminalPagerPolicy()
        XCTAssertEqual(policy.transition(to: .trailing, terminalIDs: [first, last]), .createTerminal)
        let created = UUID()
        XCTAssertEqual(policy.transition(to: .trailing, terminalIDs: [first, last, created]), .restore(created))
    }

    func testHorizontalDirectionRequiresDistanceAndHorizontalDominance() {
        XCTAssertEqual(TerminalPagerPolicy.horizontalDirection(translation: CGSize(width: 50, height: 10)), .right)
        XCTAssertEqual(TerminalPagerPolicy.horizontalDirection(translation: CGSize(width: -50, height: 10)), .left)
        XCTAssertNil(TerminalPagerPolicy.horizontalDirection(translation: CGSize(width: 30, height: 0)))
        XCTAssertNil(TerminalPagerPolicy.horizontalDirection(translation: CGSize(width: 50, height: 48)))
    }

    func testTerminalUsesInteractiveKeyboardDismissal() {
        XCTAssertEqual(TerminalSurfaceConfiguration.keyboardDismissMode, .interactive)
        XCTAssertFalse(TerminalSurfaceConfiguration.scrollsToTop)
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
