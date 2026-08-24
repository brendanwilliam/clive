import UIKit
import XCTest
@testable import Clive

final class TerminalInteractionPolicyTests: XCTestCase {
    func testTerminalLinkPolicyAllowsWebLinksOnly() {
        XCTAssertEqual(
            TerminalLinkPolicy.destination(for: "https://example.com/docs")?.absoluteString,
            "https://example.com/docs"
        )
        XCTAssertEqual(
            TerminalLinkPolicy.destination(for: "HTTP://example.com")?.scheme?.lowercased(),
            "http"
        )
        XCTAssertNil(TerminalLinkPolicy.destination(for: "file:///private/secret.txt"))
        XCTAssertNil(TerminalLinkPolicy.destination(for: "javascript:alert(1)"))
        XCTAssertNil(TerminalLinkPolicy.destination(for: "not a link"))
    }

    func testTerminalLeavesVerticalScrollAndKeyboardDismissalToExplicitControls() {
        XCTAssertEqual(TerminalSurfaceConfiguration.keyboardDismissMode, .none)
        XCTAssertFalse(TerminalSurfaceConfiguration.scrollsToTop)
    }
}
