import XCTest
@testable import Clive

final class ConnectionSetupGuideTests: XCTestCase {
    func testAutoPresentationOccursOnceWithoutAPairedIPhone() {
        var policy = ConnectionSetupAutoPresentationPolicy()

        XCTAssertTrue(policy.shouldPresent(hasPairedIPhone: false))
        XCTAssertFalse(policy.shouldPresent(hasPairedIPhone: false))
    }

    func testAutoPresentationWaitsWhenAnIPhoneIsPaired() {
        var policy = ConnectionSetupAutoPresentationPolicy()

        XCTAssertFalse(policy.shouldPresent(hasPairedIPhone: true))
        XCTAssertTrue(policy.shouldPresent(hasPairedIPhone: false))
    }

    func testTestFlightDiscoveryURLIsPublicInvitation() {
        XCTAssertEqual(
            ConnectionSetupGuideConfiguration.testFlightURL.absoluteString,
            "https://testflight.apple.com/join/SUcN1FkH"
        )
    }
}
