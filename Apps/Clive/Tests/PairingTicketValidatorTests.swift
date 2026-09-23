import Foundation
import CliveCore
import CliveSecurity
import XCTest
import Security
@testable import Clive

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

    func testPairingResponseDeadlineUsesRemainingTicketLifetime() {
        let now = Date(timeIntervalSince1970: 1_000)
        let fingerprint = String(repeating: "a", count: 64)
        let shortTicket = PairingTicket(endpoint: "127.0.0.1", port: 4242, expiresAt: now.addingTimeInterval(12), oneTimeSecret: "secret", daemonCertificateFingerprint: fingerprint)
        let longTicket = PairingTicket(endpoint: "127.0.0.1", port: 4242, expiresAt: now.addingTimeInterval(120), oneTimeSecret: "secret", daemonCertificateFingerprint: fingerprint)

        XCTAssertEqual(PairingClient.responseTimeout(for: shortTicket, now: now), 12)
        XCTAssertEqual(PairingClient.responseTimeout(for: longTicket, now: now), 60)
        XCTAssertEqual(PairingClient.responseTimeout(for: shortTicket, now: now.addingTimeInterval(12)), 0)
    }

    @MainActor func testIPhoneIdentityPersistsAsP256() throws {
        let store = AppleIdentityStore(label: "com.clive.tests.\(UUID().uuidString)", commonName: "test iPhone", usesDataProtectionKeychain: false)
        let first = try store.loadOrCreate()
        let second = try store.loadOrCreate()
        XCTAssertEqual(try store.certificateData(of: first), try store.certificateData(of: second))
        var key: SecKey?
        XCTAssertEqual(SecIdentityCopyPrivateKey(first, &key), errSecSuccess)
        let attributes = SecKeyCopyAttributes(try XCTUnwrap(key)) as? [String: Any]
        XCTAssertEqual(attributes?[kSecAttrKeySizeInBits as String] as? Int, 256)
    }
}
