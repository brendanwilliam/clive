import XCTest
@testable import Clive

final class ConnectionSetupGuideTests: XCTestCase {
    func testGuideAutoPresentsOnceWhenNoMacIsPaired() {
        var policy = ConnectionSetupPresentationPolicy()

        XCTAssertTrue(policy.shouldAutoPresent(hasPairedDevice: false))
        XCTAssertFalse(policy.shouldAutoPresent(hasPairedDevice: false))
    }

    func testGuideDoesNotAutoPresentAfterPairingCompletes() {
        var policy = ConnectionSetupPresentationPolicy()

        policy.completePairing()
        XCTAssertFalse(policy.shouldAutoPresent(hasPairedDevice: false))
        XCTAssertFalse(policy.shouldAutoPresent(hasPairedDevice: true))
    }

    func testGuideDoesNotPresentWhileAPairedMacExists() {
        var policy = ConnectionSetupPresentationPolicy()

        XCTAssertFalse(policy.shouldAutoPresent(hasPairedDevice: true))
    }

    func testTestFlightDestinationIsThePublicInvitation() {
        XCTAssertEqual(
            ConnectionSetupGuideConfiguration.testFlightURL.absoluteString,
            "https://testflight.apple.com/join/SUcN1FkH"
        )
    }
}
