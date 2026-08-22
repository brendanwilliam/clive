import UIKit
import XCTest
@testable import Clive

final class TerminalInteractionPolicyTests: XCTestCase {
    func testPreviewFrameClampsToSafeArea() {
        let safe = CGRect(x: 8, y: 20, width: 304, height: 560)
        let frame = TerminalKeyPreviewLayout.frame(source: CGRect(x: 0, y: 25, width: 20, height: 20), contentSize: CGSize(width: 100, height: 40), safeBounds: safe)
        XCTAssertTrue(safe.contains(frame))
    }
}
