import UIKit
import XCTest
@testable import Clive

final class TerminalInteractionPolicyTests: XCTestCase {
    func testEveryEdgeAndCornerHasDeterministicArrowPrecedence() {
        let bounds = CGRect(x: 0, y: 0, width: 300, height: 600)
        XCTAssertEqual(TerminalEdgeGesturePolicy.sequence(at: CGPoint(x: 150, y: 1), in: bounds), "\u{1b}[A")
        XCTAssertEqual(TerminalEdgeGesturePolicy.sequence(at: CGPoint(x: 150, y: 599), in: bounds), "\u{1b}[B")
        XCTAssertEqual(TerminalEdgeGesturePolicy.sequence(at: CGPoint(x: 1, y: 300), in: bounds), "\u{1b}[D")
        XCTAssertEqual(TerminalEdgeGesturePolicy.sequence(at: CGPoint(x: 299, y: 300), in: bounds), "\u{1b}[C")
        XCTAssertEqual(TerminalEdgeGesturePolicy.sequence(at: CGPoint(x: 1, y: 1), in: bounds), "\u{1b}[A")
        XCTAssertNil(TerminalEdgeGesturePolicy.sequence(at: CGPoint(x: 150, y: 300), in: bounds))
    }

    func testMovementAndLongPressAreRejected() {
        XCTAssertTrue(TerminalEdgeGesturePolicy.accepts(movement: 10, duration: 0.34))
        XCTAssertFalse(TerminalEdgeGesturePolicy.accepts(movement: 10.1, duration: 0.1))
        XCTAssertFalse(TerminalEdgeGesturePolicy.accepts(movement: 0, duration: 0.35))
    }

    func testPreviewFrameClampsToSafeArea() {
        let safe = CGRect(x: 8, y: 20, width: 304, height: 560)
        let frame = TerminalKeyPreviewLayout.frame(source: CGRect(x: 0, y: 25, width: 20, height: 20), contentSize: CGSize(width: 100, height: 40), safeBounds: safe)
        XCTAssertTrue(safe.contains(frame))
    }
}
