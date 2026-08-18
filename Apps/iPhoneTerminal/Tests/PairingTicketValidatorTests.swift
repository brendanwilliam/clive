import Foundation
import IPhoneTerminalCore
import XCTest
import Security
@testable import iPhoneTerminal

final class PairingTicketValidatorTests: XCTestCase {
    func testValidTicketIsAccepted() throws {
        let ticket = PairingTicket(endpoint: "192.168.1.2", port: 4242, expiresAt: .now.addingTimeInterval(60), oneTimeSecret: "secret", daemonCertificateFingerprint: String(repeating: "a", count: 64))
        XCTAssertNoThrow(try PairingTicketValidator.validate(ticket))
    }
    func testExpiredTicketIsRejected() {
        let ticket = PairingTicket(endpoint: "192.168.1.2", port: 4242, expiresAt: .now.addingTimeInterval(-1), oneTimeSecret: "secret", daemonCertificateFingerprint: String(repeating: "a", count: 64))
        XCTAssertThrowsError(try PairingTicketValidator.validate(ticket))
    }
    func testInvalidFingerprintIsRejected() {
        let ticket = PairingTicket(endpoint: "192.168.1.2", port: 4242, expiresAt: .now.addingTimeInterval(60), oneTimeSecret: "secret", daemonCertificateFingerprint: "abc")
        XCTAssertThrowsError(try PairingTicketValidator.validate(ticket))
    }

    @MainActor func testIPhoneIdentityPersistsAsP256() throws {
        let provider = IPhoneIdentityProvider()
        let first = try provider.loadOrCreate()
        let second = try provider.loadOrCreate()
        XCTAssertEqual(first.deviceID, second.deviceID)
        XCTAssertEqual(first.certificate, second.certificate)
        var key: SecKey?
        XCTAssertEqual(SecIdentityCopyPrivateKey(first.identity, &key), errSecSuccess)
        let attributes = SecKeyCopyAttributes(try XCTUnwrap(key)) as? [String: Any]
        XCTAssertEqual(attributes?[kSecAttrKeySizeInBits as String] as? Int, 256)
    }
}
