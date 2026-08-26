import Foundation
import Testing
@testable import CliveCore

private func testTicket(expiresAt: Date = Date(timeIntervalSince1970: floor(Date.now.timeIntervalSince1970) + 60)) -> PairingTicket {
    PairingTicket(endpoint: "192.168.1.2", port: 4242, expiresAt: expiresAt, oneTimeSecret: Data(repeating: 7, count: 32).base64EncodedString().replacingOccurrences(of: "=", with: ""), daemonCertificateFingerprint: String(repeating: "ab", count: 32))
}

@Test func pairingLinkRoundTripsTicketWithoutQueryMaterial() throws {
    let ticket = testTicket(); let url = try PairingLink.makeURL(for: ticket)
    #expect(url.absoluteString.hasPrefix("https://pair.clive.app/pair#"))
    #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.query == nil)
    #expect(PairingLink.route(url) == .pairing(ticket))
}

@Test func pairingLinkRejectsExpiredAndUnsupportedLinks() throws {
    let url = try PairingLink.makeURL(for: testTicket(expiresAt: .now.addingTimeInterval(-1)))
    #expect(PairingLink.route(url) == .invalid)
    #expect(PairingLink.route(url, supportsCurrentVersion: false) == .updateRequired)
    #expect(PairingLink.route(url, supportsPlatform: false) == .unsupported)
}

@Test func pairingLinkRejectsUnexpectedQueryAndVersion() throws {
    var components = try #require(URLComponents(url: PairingLink.makeURL(for: testTicket()), resolvingAgainstBaseURL: false))
    components.query = "ticket=secret"
    #expect(PairingLink.route(try #require(components.url)) == .invalid)
    components.query = nil; components.fragment = "v=99&ticket=secret"
    #expect(PairingLink.route(try #require(components.url)) == .invalid)
}
