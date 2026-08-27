import Foundation
import Testing
import CliveCore
import CliveCloud
@testable import CliveDaemon

@Suite("Legacy daemon state")
struct LegacyStateDecodingTests {
    @Test("daemon state defaults a missing listener port")
    func daemonStateDefaultsMissingListenerPort() throws {
        let data = Data(#"{"macID":"mac","serviceID":"service","remoteEndpoint":null}"#.utf8)

        let state = try JSONDecoder().decode(DaemonState.self, from: data)

        #expect(state.macID == "mac")
        #expect(state.serviceID == "service")
        #expect(state.remoteEndpoint == nil)
        #expect(state.listenerPort == 64236)
    }

    @Test("rendezvous settings reject missing current fields")
    func rendezvousSettingsRejectMissingCurrentFields() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(#"{"enabled":true,"manualEndpoint":null}"#.utf8).write(to: root.appending(path: "cellular.json"))
        let state = DaemonState(macID: "mac", serviceID: "service", remoteEndpoint: nil, listenerPort: 64236)
        let trustStore = try TrustStore(url: root.appending(path: "devices.json"))

        #expect(throws: (any Error).self) {
            try MacRendezvousController(state: state, trustStore: trustStore, baseURL: root)
        }
    }

    @Test("enabled cellular access starts a fresh verification challenge")
    func enabledCellularAccessStartsVerificationAfterControllerRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(#"{"enabled":true,"manualEndpoint":{"host":"198.51.100.10","port":64236},"endpointMode":"manual","allowsRouterMapping":false}"#.utf8).write(to: root.appending(path: "cellular.json"))
        let state = DaemonState(macID: "mac", serviceID: "service", remoteEndpoint: nil, listenerPort: 64236)
        let trustStore = try TrustStore(url: root.appending(path: "devices.json"))
        let cloud = MockCloudRendezvous()
        let phoneKeys = RendezvousKeyPair()
        try await trustStore.upsert(.init(id: "phone", displayName: "iPhone", certificateFingerprint: "fingerprint", createdAt: .now, rendezvousCapability: .init(keys: try phoneKeys.publicKeys, accountBinding: "account")))
        let controller = try MacRendezvousController(state: state, trustStore: trustStore, baseURL: root, cloudOverride: cloud)

        await controller.prepare(listenerPort: 64236)

        let status = await controller.status()
        #expect(status.state == .verifying)
        #expect(status.diagnostic == "Open Clive on the paired iPhone using cellular data to verify this connection.")
        let envelope = try #require(await cloud.savedEnvelopes.first)
        let capability = try #require(await controller.capability())
        let advertisement = try RendezvousCrypto.open(envelope, as: RendezvousAdvertisement.self, recipientID: "phone", recipientAgreementKey: phoneKeys.agreementPrivateKey, senderSigningKey: capability.keys.signing)
        #expect(advertisement.verificationChallenge != nil)
    }
}

private actor MockCloudRendezvous: CloudRendezvousProviding {
    var savedEnvelopes: [RendezvousEnvelope] = []

    func prepare() async throws -> String { "account" }
    func save(_ envelope: RendezvousEnvelope, recordName: String, recordType: String) async throws { savedEnvelopes.append(envelope) }
    func fetch(recordName: String) async throws -> RendezvousEnvelope? { nil }
    func delete(recordName: String) async throws {}
}
