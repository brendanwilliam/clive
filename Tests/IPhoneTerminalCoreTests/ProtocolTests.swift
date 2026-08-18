import Foundation
import Testing
import Security
@testable import IPhoneTerminalCore
@testable import IPhoneTerminalSecurity

@Test func frameRoundTripAcrossPartialReads() throws {
    let frame = ProtocolFrame(kind: .terminalInput, payload: Data("echo hello\n".utf8))
    let encoded = try frame.encoded()
    var decoder = FrameDecoder()
    #expect(try decoder.append(Data(encoded.prefix(5))).isEmpty)
    #expect(try decoder.append(Data(encoded.dropFirst(5))) == [frame])
}

@Test func versionOneFramesAreRejectedByVersionTwoDecoder() throws {
    var bytes = Data(); bytes.appendUInt32(3); bytes.appendUInt16(1); bytes.append(FrameKind.sessionClose.rawValue)
    var decoder = FrameDecoder()
    #expect(throws: ProtocolError.unsupportedVersion(1)) { try decoder.append(bytes) }
}

@Test func workspaceSessionIDReplacesOnlyMatchingPhoneSession() async {
    let registry = SessionRegistry()
    let stableID = UUID()
    _ = await registry.open(deviceID: "phone-a", clientSessionID: stableID, size: TerminalSize(columns: 80, rows: 24))
    _ = await registry.open(deviceID: "phone-a", clientSessionID: stableID, size: TerminalSize(columns: 120, rows: 40))
    _ = await registry.open(deviceID: "phone-b", clientSessionID: stableID, size: TerminalSize(columns: 80, rows: 24))
    #expect(await registry.sessions(forDeviceID: "phone-a").count == 1)
    #expect(await registry.all().count == 2)
}

@Test func previewSanitizesSplitControlSequencesAndBoundsOutput() {
    var preview = TerminalPreviewAccumulator(maximumLength: 8)
    preview.consume(Data("hello\u{1b}[31".utf8))
    preview.consume(Data("m world\rnext\u{8}!\n".utf8))
    #expect(preview.preview == "nex!")
    preview.consume(Data("123456789".utf8))
    #expect(preview.preview == "12345678")
    preview.clear()
    #expect(preview.preview == nil)
}

@Test func oversizedFrameIsRejectedBeforeBuffering() {
    var data = Data()
    data.appendUInt32(100)
    var decoder = FrameDecoder(maximumPayloadSize: 8)
    #expect(throws: ProtocolError.frameTooLarge(97)) { try decoder.append(data) }
}

@Test func pairingSecretExpiresAndCannotBeReused() async throws {
    let ticket = PairingTicket(endpoint: "127.0.0.1", port: 4444, expiresAt: Date.now.addingTimeInterval(60), oneTimeSecret: "secret", daemonCertificateFingerprint: "abc")
    let secret = PairingSecret(ticket: ticket)
    try await secret.consume(secret: "secret")
    await #expect(throws: PairingError.consumed) { try await secret.consume(secret: "secret") }
}

@Test func expiredPairingSecretIsRejected() async {
    let ticket = PairingTicket(endpoint: "127.0.0.1", port: 4444, expiresAt: Date.now.addingTimeInterval(-1), oneTimeSecret: "secret", daemonCertificateFingerprint: "abc")
    let secret = PairingSecret(ticket: ticket)
    await #expect(throws: PairingError.expired) { try await secret.consume(secret: "secret") }
}

@Test func revocationClosesEveryDeviceSession() async {
    let registry = SessionRegistry()
    _ = await registry.open(deviceID: "phone-a", clientSessionID: UUID(), size: TerminalSize(columns: 80, rows: 24))
    _ = await registry.open(deviceID: "phone-a", clientSessionID: UUID(), size: TerminalSize(columns: 120, rows: 40))
    _ = await registry.open(deviceID: "phone-b", clientSessionID: UUID(), size: TerminalSize(columns: 80, rows: 24))
    #expect(await registry.closeAll(forDeviceID: "phone-a").count == 2)
    #expect(await registry.sessions(forDeviceID: "phone-a").isEmpty)
    #expect(await registry.sessions(forDeviceID: "phone-b").count == 1)
}

@Test func pairingTicketUsesQRCompatiblePayload() throws {
    let ticket = PairingTicket(endpoint: "192.168.1.10", port: 4242, expiresAt: Date(timeIntervalSince1970: 1_700_000_000), oneTimeSecret: "secret", daemonCertificateFingerprint: "abc")
    let payload = try PairingPayload.encode(ticket)
    #expect(!payload.contains("="))
    #expect(try PairingPayload.decode(payload) == ticket)
}

@Test func pairingRequestCannotConsumeSecretWhenMalformed() async throws {
    let ticket = PairingTicket(endpoint: "127.0.0.1", port: 4444, expiresAt: Date.now.addingTimeInterval(60), oneTimeSecret: "secret", daemonCertificateFingerprint: "abc")
    let secret = PairingSecret(ticket: ticket)
    let malformed = PairingRequest(oneTimeSecret: "secret", deviceID: "", deviceName: "Phone", certificate: Data())
    await #expect(throws: PairingError.malformedRequest) { try await secret.validate(request: malformed) }
    try await secret.consume(secret: "secret")
}

@Test func validPairingRequestDoesNotConsumeSecretBeforeApproval() async throws {
    let ticket = PairingTicket(endpoint: "127.0.0.1", port: 4444, expiresAt: Date.now.addingTimeInterval(60), oneTimeSecret: "secret", daemonCertificateFingerprint: "abc")
    let secret = PairingSecret(ticket: ticket)
    let request = PairingRequest(oneTimeSecret: "secret", deviceID: "phone-a", deviceName: "Phone", certificate: Data([1]))
    try await secret.validate(request: request)
    try await secret.consume(secret: request.oneTimeSecret)
    await #expect(throws: PairingError.consumed) { try await secret.validate(request: request) }
}

@Test func protocolPayloadRoundTripsPairingRequest() throws {
    let request = PairingRequest(oneTimeSecret: "secret", deviceID: "phone-a", deviceName: "Phone", certificate: Data([1, 2]))
    #expect(try ProtocolPayload.decode(PairingRequest.self, from: ProtocolPayload.encode(request)) == request)
}

@Test func approvedPairingStoresPinnedDeviceAndConsumesTicket() async throws {
    let storeURL = URL.temporaryDirectory.appending(path: "iphone-terminal-tests/\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: storeURL.deletingLastPathComponent()) }
    let store = try TrustStore(url: storeURL)
    let ticket = PairingTicket(endpoint: "127.0.0.1", port: 4444, expiresAt: Date.now.addingTimeInterval(60), oneTimeSecret: "secret", daemonCertificateFingerprint: "abc")
    let secret = PairingSecret(ticket: ticket)
    let coordinator = PairingCoordinator(secret: secret, trustStore: store, macID: "mac-a", displayName: "Mac", serviceID: "service-a", macCertificate: Data([9])) { _ in true }
    let request = PairingRequest(oneTimeSecret: "secret", deviceID: "phone-a", deviceName: "Phone", certificate: Data([1, 2]))
    #expect(try await coordinator.accept(request) == PairingAcceptance(macID: "mac-a", displayName: "Mac", serviceID: "service-a", certificate: Data([9])))
    #expect(await store.device(id: "phone-a")?.certificateFingerprint == Fingerprint.sha256(of: Data([1, 2])))
    await #expect(throws: PairingError.consumed) { try await coordinator.accept(request) }
}


@Test func multipleFramesDecodeFromOneRead() throws {
    let first = try ProtocolFrame(kind: .terminalInput, payload: Data([1])).encoded()
    let second = try ProtocolFrame(kind: .sessionClose).encoded()
    var decoder = FrameDecoder()
    #expect(try decoder.append(first + second).map(\.kind) == [.terminalInput, .sessionClose])
}

@Test func unknownAndMalformedFramesAreRejected() {
    var unknown = Data(); unknown.appendUInt32(3); unknown.appendUInt16(ProtocolFrame.version); unknown.append(0xff)
    var decoder = FrameDecoder()
    #expect(throws: ProtocolError.unknownMandatoryFrame(0xff)) { try decoder.append(unknown) }
    var malformed = Data(); malformed.appendUInt32(2)
    var otherDecoder = FrameDecoder()
    #expect(throws: ProtocolError.malformedFrame) { try otherDecoder.append(malformed) }
}

@Test func outputBackpressureUsesHysteresis() {
    var state = OutputBackpressure(highWaterMark: 10, lowWaterMark: 5)
    let belowHigh = state.enqueue(9); let atHigh = state.enqueue(1)
    #expect(!belowHigh); #expect(atHigh)
    let atLow = state.complete(5); let belowLow = state.complete(1)
    #expect(atLow); #expect(!belowLow)
}

@Test func controlMessagesAreBoundedAndNewlineDelimited() throws {
    let request = ControlRequest(command: .revoke, deviceID: "phone-a")
    let encoded = try ControlCodec.encode(request)
    #expect(encoded.last == 0x0a)
    #expect(try JSONDecoder().decode(ControlRequest.self, from: encoded.dropLast()) == request)
}

@Test func trustStorePersistsWithOwnerOnlyPermissions() async throws {
    let directory = URL.temporaryDirectory.appending(path: "iphone-terminal-trust-\(UUID().uuidString)")
    let url = directory.appending(path: "devices.json")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try TrustStore(url: url)
    try await store.upsert(PairedIPhone(id: "phone", displayName: "Phone", certificateFingerprint: String(repeating: "a", count: 64), createdAt: .now))
    let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
    #expect(permissions?.intValue == 0o600)
    let loaded = try TrustStore(url: url)
    #expect(await loaded.all().count == 1)
}
