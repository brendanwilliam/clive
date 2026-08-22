import XCTest
@testable import Clive

final class InitialCommandBufferTests: XCTestCase {
    func testInitialCommandIsDeliveredOnlyOnce() {
        var buffer = InitialCommandBuffer("git status --short")

        XCTAssertEqual(buffer.take(), "git status --short")
        XCTAssertNil(buffer.take())
    }

    func testEmptyInitialCommandRemainsAbsent() {
        var buffer = InitialCommandBuffer(nil)

        XCTAssertNil(buffer.take())
    }
}
