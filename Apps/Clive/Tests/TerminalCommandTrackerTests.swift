import Foundation
import XCTest
@testable import Clive

final class TerminalCommandTrackerTests: XCTestCase {
    func testReturnCapturesLastCommand() {
        var tracker = TerminalCommandTracker()

        tracker.consume(Data("git status\r".utf8))

        XCTAssertEqual(tracker.lastCommand, "git status")
        XCTAssertEqual(tracker.currentCommand, "")
    }

    func testEditingAndArrowSequencesUpdateCommandSafely() {
        var tracker = TerminalCommandTracker()

        tracker.consume(Data("echo xy".utf8))
        tracker.consume(Data([0x7f]))
        tracker.consume(Data("z".utf8))
        tracker.consume(Data("\u{1b}[D".utf8))
        tracker.consume(Data("\r".utf8))

        XCTAssertEqual(tracker.lastCommand, "echo xz")
    }

    func testEmptyReturnKeepsPreviousCommand() {
        var tracker = TerminalCommandTracker()
        tracker.consume(Data("pwd\r".utf8))

        tracker.consume(Data("   \r".utf8))

        XCTAssertEqual(tracker.lastCommand, "pwd")
    }
}
