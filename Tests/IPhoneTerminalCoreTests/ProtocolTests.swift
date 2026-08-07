import Foundation
import Testing
@testable import IPhoneTerminalCore

@Test func frameRoundTripAcrossPartialReads() throws {
    let frame = ProtocolFrame(kind: .terminalInput, payload: Data("echo hello\n".utf8))
    let encoded = try frame.encoded()
    var decoder = FrameDecoder()
    #expect(try decoder.append(Data(encoded.prefix(5))).isEmpty)
    #expect(try decoder.append(Data(encoded.dropFirst(5))) == [frame])
}

@Test func oversizedFrameIsRejectedBeforeBuffering() {
    var data = Data()
    data.appendUInt32(100)
    var decoder = FrameDecoder(maximumPayloadSize: 8)
    #expect(throws: ProtocolError.frameTooLarge(97)) { try decoder.append(data) }
}

@Test func pairingSecretExpiresAndCannotBeReused() async throws {
    let ticket = PairingTicket(endpoint: "127.0.0.1", port: 4444, expiresAt: Date.now.addingTimeInterval(60), oneTimeSecret: "secret", pairingCertificateFingerprint: "abc")
    let secret = PairingSecret(ticket: ticket)
    try await secret.consume(secret: "secret")
    await #expect(throws: PairingError.consumed) { try await secret.consume(secret: "secret") }
}

@Test func expiredPairingSecretIsRejected() async {
    let ticket = PairingTicket(endpoint: "127.0.0.1", port: 4444, expiresAt: Date.now.addingTimeInterval(-1), oneTimeSecret: "secret", pairingCertificateFingerprint: "abc")
    let secret = PairingSecret(ticket: ticket)
    await #expect(throws: PairingError.expired) { try await secret.consume(secret: "secret") }
}

@Test func revocationClosesEveryDeviceSession() async {
    let registry = SessionRegistry()
    _ = await registry.open(deviceID: "phone-a", size: TerminalSize(columns: 80, rows: 24))
    _ = await registry.open(deviceID: "phone-a", size: TerminalSize(columns: 120, rows: 40))
    _ = await registry.open(deviceID: "phone-b", size: TerminalSize(columns: 80, rows: 24))
    #expect(await registry.closeAll(forDeviceID: "phone-a").count == 2)
    #expect(await registry.sessions(forDeviceID: "phone-a").isEmpty)
    #expect(await registry.sessions(forDeviceID: "phone-b").count == 1)
}
