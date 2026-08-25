import XCTest
@testable import CliveDaemon

final class TerminalColorEnvironmentTests: XCTestCase {
    func testColorEnvironmentEnablesInteractiveTerminalColor() {
        XCTAssertEqual(TerminalColorEnvironment.variables["TERM"], "xterm-256color")
        XCTAssertEqual(TerminalColorEnvironment.variables["COLORTERM"], "truecolor")
        XCTAssertEqual(TerminalColorEnvironment.variables["CLICOLOR"], "1")
        XCTAssertEqual(TerminalColorEnvironment.variables["CLICOLOR_FORCE"], "1")
        XCTAssertEqual(TerminalColorEnvironment.variables["FORCE_COLOR"], "1")
    }
}
