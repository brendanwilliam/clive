import Foundation
import Testing
import Security
@testable import CliveCore
@testable import CliveSecurity

private enum StartupTestError: Error, Equatable { case unavailable, failed }

@Test func routeSelectorPrefersLANAndDebouncesRecovery() {
    let now = Date(timeIntervalSince1970: 100)
    let lan = RouteCandidate(id: UUID(), kind: .lan, host: "mac.local", port: 64236, health: .healthy)
    let cellular = RouteCandidate(id: UUID(), kind: .directWANCellular, host: "198.51.100.10", port: 64236, health: .healthy)
    var selector = ConnectivityRouteStateMachine()

    #expect(selector.evaluate([cellular], at: now) == .selected(cellular))
    #expect(selector.evaluate([lan, cellular], at: now) == .noChange)
    #expect(selector.evaluate([lan, cellular], at: now.addingTimeInterval(4.9)) == .noChange)
    #expect(selector.evaluate([lan, cellular], at: now.addingTimeInterval(5)) == .handedOff(from: cellular.id, to: lan))
    #expect(selector.selectedRouteID == lan.id)
}

@Test func routeSelectorFailsOverImmediatelyButDoesNotCreateAReplacement() {
    let now = Date(timeIntervalSince1970: 100)
    let lan = RouteCandidate(id: UUID(), kind: .lan, host: "mac.local", port: 64236, health: .failed)
    let vpn = RouteCandidate(id: UUID(), kind: .privateVPN, host: "mac.vpn", port: 64236, health: .healthy)
    var selector = ConnectivityRouteStateMachine(selectedRouteID: lan.id)

    #expect(selector.evaluate([lan, vpn], at: now) == .handedOff(from: lan.id, to: vpn))
    #expect(selector.selectedRouteID == vpn.id)
}

@Test func expiredOrUnauthorizedRoutesAreUnavailable() {
    let now = Date(timeIntervalSince1970: 100)
    let expired = RouteCandidate(kind: .lan, host: "mac.local", port: 64236, expiresAt: now, health: .healthy)
    let unauthorized = RouteCandidate(kind: .privateVPN, host: "mac.vpn", port: 64236, authorization: .unauthorized, health: .healthy)
    #expect(expired.state(at: now) == .unavailable)
    #expect(unauthorized.state(at: now) == .unavailable)
}

@Test func companionStartupReturnsWithoutLaunchingWhenDaemonIsAvailable() throws {
    var launches = 0
    let result = try CompanionStartupPolicy.run(
        companionIsInstalled: true,
        launch: { launches += 1 },
        request: { "ready" },
        isUnavailable: { _ in true }
    )

    #expect(result == "ready")
    #expect(launches == 0)
}

@Test func companionStartupLaunchesAndRetriesUntilAvailable() throws {
    var attempts = 0
    var launches = 0
    var time = Date(timeIntervalSince1970: 0)
    let result = try CompanionStartupPolicy.run(
        companionIsInstalled: true,
        now: { time },
        sleep: { time.addTimeInterval($0) },
        launch: { launches += 1 },
        request: {
            attempts += 1
            if attempts < 3 { throw StartupTestError.unavailable }
            return "ready"
        },
        isUnavailable: { ($0 as? StartupTestError) == .unavailable }
    )

    #expect(result == "ready")
    #expect(launches == 1)
    #expect(attempts == 3)
}

@Test func companionStartupDoesNotLaunchWhenAppIsMissing() {
    #expect(throws: StartupTestError.unavailable) {
        try CompanionStartupPolicy.run(
            companionIsInstalled: false,
            launch: {},
            request: { throw StartupTestError.unavailable },
            isUnavailable: { ($0 as? StartupTestError) == .unavailable }
        ) as String
    }
}

@Test func companionStartupStopsRetryingAtDeadline() {
    var time = Date(timeIntervalSince1970: 0)
    #expect(throws: StartupTestError.unavailable) {
        try CompanionStartupPolicy.run(
            companionIsInstalled: true,
            timeout: 0.2,
            retryInterval: 0.1,
            now: { time },
            sleep: { time.addTimeInterval($0) },
            launch: {},
            request: { throw StartupTestError.unavailable },
            isUnavailable: { ($0 as? StartupTestError) == .unavailable }
        ) as String
    }
}

@Test func frameRoundTripAcrossPartialReads() throws {
    let frame = ProtocolFrame(kind: .terminalInput, payload: Data("echo hello\n".utf8))
    let encoded = try frame.encoded()
    var decoder = FrameDecoder()
    #expect(try decoder.append(Data(encoded.prefix(5))).isEmpty)
    #expect(try decoder.append(Data(encoded.dropFirst(5))) == [frame])
}

@Test func versionTwoFramesAreRejectedByVersionThreeDecoder() throws {
    var bytes = Data(); bytes.appendUInt32(3); bytes.appendUInt16(2); bytes.append(FrameKind.sessionClose.rawValue)
    var decoder = FrameDecoder()
    #expect(throws: ProtocolError.unsupportedVersion(2)) { try decoder.append(bytes) }
}

@Test func v3SessionAndOutputDescriptorsRoundTrip() throws {
    let id = UUID()
    let descriptor = SessionDescriptor(id: id, label: "build", attachmentCount: 2, resizeOwner: .macCLI, outputOffset: 42)
    #expect(try ProtocolPayload.decode(SessionDescriptor.self, from: ProtocolPayload.encode(descriptor)) == descriptor)
    let chunk = TerminalOutputChunk(offset: 42, bytes: Data("ok".utf8))
    #expect(try ProtocolPayload.decode(TerminalOutputChunk.self, from: ProtocolPayload.encode(chunk)) == chunk)
    #expect(chunk.endOffset == 44)
}

@Test func sessionAttachAndAttachmentStateRoundTrip() throws {
    let id = UUID(), size = TerminalSize(columns: 132, rows: 40)
    let gate = Data("wan-gate".utf8)
    let request = SessionAttachRequest(serverSessionID: id, lastReceivedOffset: 19, attachmentKind: .iPhone, initialSize: size, wanGateToken: gate)
    #expect(try ProtocolPayload.decode(SessionAttachRequest.self, from: ProtocolPayload.encode(request)) == request)
    let list = SessionListRequest(wanGateToken: gate)
    #expect(try ProtocolPayload.decode(SessionListRequest.self, from: ProtocolPayload.encode(list)) == list)
    let state = AttachmentState(sessionID: id, attachmentCount: 2, resizeOwner: .macCLI, outputOffset: 41)
    #expect(try ProtocolPayload.decode(AttachmentState.self, from: ProtocolPayload.encode(state)) == state)
    #expect(SessionError.Code.sessionUnavailable != .slowConsumer)
}

@Test func bulkSessionTerminationRoundTripsAndIsBounded() throws {
    let ids = [UUID(), UUID()]
    let request = SessionTerminateManyRequest(sessionIDs: ids)
    #expect(request.isValid)
    #expect(try ProtocolPayload.decode(SessionTerminateManyRequest.self, from: ProtocolPayload.encode(request)) == request)
    let result = SessionTerminateManyResult(terminatedSessionIDs: ids)
    #expect(try ProtocolPayload.decode(SessionTerminateManyResult.self, from: ProtocolPayload.encode(result)) == result)
    #expect(!SessionTerminateManyRequest(sessionIDs: []).isValid)
    #expect(!SessionTerminateManyRequest(sessionIDs: (0...SessionTerminateManyRequest.maximumSessionCount).map { _ in UUID() }).isValid)
}

@Test func malformedBulkSessionTerminationIsRejected() {
    #expect(throws: (any Error).self) {
        try ProtocolPayload.decode(SessionTerminateManyRequest.self, from: Data(#"{"sessionIDs":"invalid"}"#.utf8))
    }
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

@Test func sessionOpenedRoundTripsResumeMetadata() throws {
    let value = SessionOpened(serverSessionID: UUID(), disposition: .resumed, replayTruncated: true)
    #expect(try ProtocolPayload.decode(SessionOpened.self, from: ProtocolPayload.encode(value)) == value)
}

@Test func sessionOpenedRejectsMissingRequiredCurrentFields() throws {
    let id = UUID()
    let data = Data(#"{"serverSessionID":"\#(id.uuidString)"}"#.utf8)
    #expect(throws: (any Error).self) { try ProtocolPayload.decode(SessionOpened.self, from: data) }
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

@Test func pairingTicketUsesCompactV2QRPayload() throws {
    let ticket = PairingTicket(endpoint: "192.168.1.10", port: 4242, expiresAt: Date(timeIntervalSince1970: 1_700_000_000), oneTimeSecret: Data(repeating: 7, count: 32).base64EncodedString().replacingOccurrences(of: "=", with: ""), daemonCertificateFingerprint: String(repeating: "ab", count: 32))
    let payload = try PairingPayload.encode(ticket)
    #expect(payload.hasPrefix("CL2:"))
    #expect(payload.dropFirst(4).allSatisfy { "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ $%*+-./:".contains($0) })
    #expect(try PairingPayload.decode(payload) == ticket)
}

@Test func legacyV1PairingPayloadIsRejected() throws {
    let ticket = PairingTicket(endpoint: "127.0.0.1", port: 4242, expiresAt: Date(timeIntervalSince1970: 1_700_000_000), oneTimeSecret: "legacy", daemonCertificateFingerprint: "abc")
    let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
    let payload = try encoder.encode(ticket).base64EncodedString().replacingOccurrences(of: "=", with: "")
    #expect(throws: PairingPayloadError.malformed) { try PairingPayload.decode(payload) }
}

@Test func malformedV2PairingPayloadIsRejected() {
    #expect(throws: PairingPayloadError.malformed) { try PairingPayload.decode("CL2:0") }
    #expect(throws: PairingPayloadError.malformed) { try PairingPayload.decode("CL2:@@") }
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
    let storeURL = URL.temporaryDirectory.appending(path: "clive-tests/\(UUID().uuidString).json")
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

@Test func cellularSetupControlRequestRoundTrips() throws {
    let configuration = CellularConfiguration(listenerPort: 64236, endpointMode: .manual, manualEndpoint: .init(host: "terminal.example.com", port: 443))
    let request = ControlRequest(command: .configureCellular, cellularConfiguration: configuration)
    let encoded = try ControlCodec.encode(request)
    #expect(try JSONDecoder().decode(ControlRequest.self, from: encoded.dropLast()) == request)
}

@Test func reachabilityProbeFramesRoundTripWithoutOpeningASession() throws {
    let challenge = UUID(); let token = Data(repeating: 4, count: 32)
    let request = ProtocolFrame(kind: .reachabilityProbe, payload: try ProtocolPayload.encode(ReachabilityProbe(challenge: challenge, wanGateToken: token)))
    let response = ProtocolFrame(kind: .reachabilityVerified, payload: try ProtocolPayload.encode(ReachabilityVerified(challenge: challenge)))
    var decoder = FrameDecoder(); let frames = try decoder.append(request.encoded() + response.encoded())
    #expect(frames.map(\.kind) == [.reachabilityProbe, .reachabilityVerified])
    #expect(try ProtocolPayload.decode(ReachabilityProbe.self, from: frames[0].payload).wanGateToken == token)
}

@Test func trustStorePersistsWithOwnerOnlyPermissions() async throws {
    let directory = URL.temporaryDirectory.appending(path: "clive-trust-\(UUID().uuidString)")
    let url = directory.appending(path: "devices.json")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try TrustStore(url: url)
    try await store.upsert(PairedIPhone(id: "phone", displayName: "Phone", certificateFingerprint: String(repeating: "a", count: 64), createdAt: .now))
    let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
    #expect(permissions?.intValue == 0o600)
    let loaded = try TrustStore(url: url)
    #expect(await loaded.all().count == 1)
}

@Test func rendezvousEnvelopeRoundTripsAndRejectsReplayAndTampering() throws {
    let sender = RendezvousKeyPair(); let recipient = RendezvousKeyPair()
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let payload = RendezvousAdvertisement(generation: UUID(), gateToken: Data(repeating: 7, count: 32), endpoints: [.init(host: "2001:db8::1", port: 22022, kind: .publicIPv6)])
    let envelope = try RendezvousCrypto.seal(payload, senderID: "mac", recipientID: "phone", sequence: 4, issuedAt: now, expiresAt: now.addingTimeInterval(300), recipientAgreementKey: recipient.publicKeys.agreement, senderSigningKey: sender.signingPrivateKey)
    let opened = try RendezvousCrypto.open(envelope, as: RendezvousAdvertisement.self, recipientID: "phone", recipientAgreementKey: recipient.agreementPrivateKey, senderSigningKey: sender.publicKeys.signing, minimumSequence: 3, now: now)
    #expect(opened == payload)
    #expect(throws: RendezvousError.replayed) {
        try RendezvousCrypto.open(envelope, as: RendezvousAdvertisement.self, recipientID: "phone", recipientAgreementKey: recipient.agreementPrivateKey, senderSigningKey: sender.publicKeys.signing, minimumSequence: 4, now: now)
    }
    let tampered = RendezvousEnvelope(senderID: envelope.senderID, recipientID: envelope.recipientID, sequence: envelope.sequence, issuedAt: envelope.issuedAt, expiresAt: envelope.expiresAt, ephemeralPublicKey: envelope.ephemeralPublicKey, ciphertext: envelope.ciphertext + Data([0]), signature: envelope.signature)
    #expect(throws: RendezvousError.invalidSignature) {
        try RendezvousCrypto.open(tampered, as: RendezvousAdvertisement.self, recipientID: "phone", recipientAgreementKey: recipient.agreementPrivateKey, senderSigningKey: sender.publicKeys.signing, now: now)
    }
}

@Test func rendezvousAdvertisementCarriesVerificationChallenge() throws {
    let challenge = UUID()
    let advertisement = RendezvousAdvertisement(generation: UUID(), gateToken: Data(repeating: 1, count: 32), endpoints: [], verificationChallenge: challenge)
    let encoded = try JSONEncoder().encode(advertisement)
    #expect(try JSONDecoder().decode(RendezvousAdvertisement.self, from: encoded).verificationChallenge == challenge)
    let legacy = Data(#"{"generation":"00000000-0000-0000-0000-000000000001","gateToken":"AQ==","endpoints":[]}"#.utf8)
    #expect(try JSONDecoder().decode(RendezvousAdvertisement.self, from: legacy).verificationChallenge == nil)
}

@Test func rendezvousEnvelopeRejectsWrongRecipientAndExpiry() throws {
    let sender = RendezvousKeyPair(); let recipient = RendezvousKeyPair()
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let envelope = try RendezvousCrypto.seal(RendezvousReachabilityHint(), senderID: "phone", recipientID: "mac", sequence: 1, issuedAt: now, expiresAt: now.addingTimeInterval(30), recipientAgreementKey: recipient.publicKeys.agreement, senderSigningKey: sender.signingPrivateKey)
    #expect(throws: RendezvousError.wrongRecipient) {
        try RendezvousCrypto.open(envelope, as: RendezvousReachabilityHint.self, recipientID: "other", recipientAgreementKey: recipient.agreementPrivateKey, senderSigningKey: sender.publicKeys.signing, now: now)
    }
    #expect(throws: RendezvousError.expired) {
        try RendezvousCrypto.open(envelope, as: RendezvousReachabilityHint.self, recipientID: "mac", recipientAgreementKey: recipient.agreementPrivateKey, senderSigningKey: sender.publicKeys.signing, now: now.addingTimeInterval(31))
    }
}

@Test func rendezvousRecordNamesAndAccountBindingsAreStableAndOpaque() {
    #expect(RendezvousCrypto.recordName(macID: "mac", deviceID: "phone", purpose: "endpoint").count == 64)
    #expect(RendezvousCrypto.recordName(macID: "mac", deviceID: "phone", purpose: "endpoint") != RendezvousCrypto.recordName(macID: "mac", deviceID: "phone", purpose: "hint"))
    #expect(RendezvousCrypto.accountBinding(containerIdentifier: "iCloud.example", userRecordName: "user") == RendezvousCrypto.accountBinding(containerIdentifier: "iCloud.example", userRecordName: "user"))
}

@Test func wanGateExpiresAndInvalidatesBeforeCloudCleanup() {
    let now = Date(timeIntervalSince1970: 1_700_000_000); let token = Data(repeating: 9, count: 32)
    var gates = WANGateRegistry(); gates.issue(deviceID: "phone", token: token, expiresAt: now.addingTimeInterval(30))
    #expect(gates.validate(deviceID: "phone", token: token, now: now))
    #expect(!gates.validate(deviceID: "other", token: token, now: now))
    #expect(!gates.validate(deviceID: "phone", token: token, now: now.addingTimeInterval(31)))
    gates.invalidateAll()
    #expect(!gates.validate(deviceID: "phone", token: token, now: now))
}

@Test func sessionOpenRejectsMissingRequiredCurrentFields() throws {
    let legacyOpen = Data(#"{"clientSessionID":"00000000-0000-0000-0000-000000000001","initialSize":{"columns":80,"rows":24}}"#.utf8)
    #expect(throws: (any Error).self) { try JSONDecoder().decode(SessionOpenRequest.self, from: legacyOpen) }
}

@Test func sessionOpenRoundTripsWorkingDirectory() throws {
    let request = SessionOpenRequest(
        clientSessionID: UUID(),
        initialSize: TerminalSize(columns: 100, rows: 30),
        workingDirectory: "~/Projects/clive"
    )
    let encoded = try ProtocolPayload.encode(request)
    #expect(try ProtocolPayload.decode(SessionOpenRequest.self, from: encoded) == request)
}

@Test func selfRevocationFramesRoundTrip() throws {
    let bytes = try ProtocolFrame(kind: .pairingRevoke).encoded() + ProtocolFrame(kind: .pairingRevoked).encoded()
    var decoder = FrameDecoder()
    #expect(try decoder.append(bytes).map(\.kind) == [.pairingRevoke, .pairingRevoked])
}
