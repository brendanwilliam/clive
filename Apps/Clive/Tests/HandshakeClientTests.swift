import CliveCore
import CliveSecurity
import Foundation
import Network
import Security
import XCTest
@testable import Clive

private final class StalledTLSPeer: @unchecked Sendable {
    let identity: SecIdentity
    let fingerprint: String
    let listener: NWListener
    private let queue = DispatchQueue(label: "test.handshake.peer")
    private let lock = NSLock()
    private var accepted: [NWConnection] = []
    private var readyReported = false

    init(listenerReady: XCTestExpectation, peerReady: XCTestExpectation, onReady: @escaping @Sendable (NWConnection) -> Void = { _ in }) throws {
        let store = AppleIdentityStore(label: "com.clive.tests.handshake-peer", commonName: "Handshake test peer", usesDataProtectionKeychain: false)
        identity = try store.loadOrCreate()
        fingerprint = Fingerprint.sha256(of: try store.certificateData(of: identity))
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv13)
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, try XCTUnwrap(sec_identity_create(identity)))
        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters, on: .any)
        listener.stateUpdateHandler = { state in
            if case .ready = state { listenerReady.fulfill() }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.lock.withLock { self.accepted.append(connection) }
            connection.stateUpdateHandler = { state in
                if case .ready = state {
                    let reportReady = self.lock.withLock { () -> Bool in
                        guard !self.readyReported else { return false }
                        self.readyReported = true
                        return true
                    }
                    if reportReady { peerReady.fulfill() }
                    onReady(connection)
                }
            }
            connection.start(queue: self.queue)
        }
        listener.start(queue: queue)
    }

    var port: UInt16? { listener.port?.rawValue }
    func close() {
        listener.cancel()
        lock.withLock { accepted.forEach { $0.cancel() }; accepted.removeAll() }
    }
}

final class HandshakeClientTests: XCTestCase {
    @MainActor func testTLSReadySessionPeerWithoutOpenedResponseTimesOutOnce() async throws {
        let listening = expectation(description: "Listener ready")
        let tlsReady = expectation(description: "TLS ready")
        let peer = try StalledTLSPeer(listenerReady: listening, peerReady: tlsReady)
        defer { peer.close() }
        await fulfillment(of: [listening], timeout: 5)
        let timedOut = expectation(description: "Session handshake timed out")
        let client = SessionClient(attemptTimeout: 2)
        var terminalResults = 0
        client.onState = { state, _ in
            if case .networkError(let message) = state, message == "Connection attempt timed out." {
                terminalResults += 1
                timedOut.fulfill()
            }
        }
        client.connect(host: "127.0.0.1", port: try XCTUnwrap(peer.port), pinnedFingerprint: peer.fingerprint, identity: peer.identity, clientSessionID: UUID(), size: TerminalSize(columns: 80, rows: 24))
        defer { client.detach() }

        await fulfillment(of: [tlsReady, timedOut], timeout: 5)
        XCTAssertEqual(terminalResults, 1)
    }

    @MainActor func testTLSReadyCatalogPeerWithoutInitialListTimesOut() async throws {
        let listening = expectation(description: "Listener ready")
        let tlsReady = expectation(description: "TLS ready")
        let peer = try StalledTLSPeer(listenerReady: listening, peerReady: tlsReady)
        defer { peer.close() }
        await fulfillment(of: [listening], timeout: 5)
        let failed = expectation(description: "Catalog handshake timed out")
        let catalog = SessionCatalogClient(initialTimeout: 2)
        var failures = 0
        catalog.onFailure = { _ in
            failures += 1
            if failures == 2 { failed.fulfill() }
        }
        catalog.connect(host: "127.0.0.1", port: try XCTUnwrap(peer.port), pinnedFingerprint: peer.fingerprint, identity: peer.identity, wanGateToken: nil)
        defer { catalog.close() }

        await fulfillment(of: [tlsReady, failed], timeout: 5)
        XCTAssertEqual(failures, 2)
    }

    @MainActor func testCatalogReplacementFailsPendingTerminationOnce() async throws {
        let listening = expectation(description: "Listener ready")
        let tlsReady = expectation(description: "TLS ready")
        let listPayload = try ProtocolPayload.encode(SessionListResult(sessions: []))
        let listFrame = try ProtocolFrame(kind: .sessionListResult, payload: listPayload).encoded()
        let peer = try StalledTLSPeer(listenerReady: listening, peerReady: tlsReady) { connection in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { _, _, _, _ in
                connection.send(content: listFrame, completion: .idempotent)
            }
        }
        defer { peer.close() }
        await fulfillment(of: [listening], timeout: 5)
        let listed = expectation(description: "Initial catalog received")
        let completed = expectation(description: "Pending termination failed")
        let catalog = SessionCatalogClient()
        catalog.onSessions = { _, _ in listed.fulfill() }
        catalog.connect(host: "127.0.0.1", port: try XCTUnwrap(peer.port), pinnedFingerprint: peer.fingerprint, identity: peer.identity, wanGateToken: nil)
        defer { catalog.close() }
        await fulfillment(of: [tlsReady, listed], timeout: 5)
        catalog.onSessions = nil

        var completions = 0
        catalog.terminate(sessionIDs: [UUID()]) { result in
            completions += 1
            if case .failure = result { completed.fulfill() }
        }
        catalog.connect(host: "127.0.0.1", port: try XCTUnwrap(peer.port), pinnedFingerprint: peer.fingerprint, identity: peer.identity, wanGateToken: nil)
        await fulfillment(of: [completed], timeout: 5)
        XCTAssertEqual(completions, 1)
    }

    @MainActor func testPairingPeerWithoutAcceptanceStopsAtTicketExpiry() async throws {
        let listening = expectation(description: "Listener ready")
        let tlsReady = expectation(description: "TLS ready")
        let peer = try StalledTLSPeer(listenerReady: listening, peerReady: tlsReady)
        defer { peer.close() }
        await fulfillment(of: [listening], timeout: 5)
        let ticket = PairingTicket(
            endpoint: "127.0.0.1", port: try XCTUnwrap(peer.port),
            expiresAt: .now.addingTimeInterval(2), oneTimeSecret: "test-secret",
            daemonCertificateFingerprint: peer.fingerprint
        )
        let identity = IPhoneIdentity(deviceID: "test-phone", displayName: "Test phone", identity: peer.identity, certificate: Data())
        let task = Task { try await PairingClient().pair(ticket: ticket, identity: identity) }
        await fulfillment(of: [tlsReady], timeout: 5)
        do {
            _ = try await task.value
            XCTFail("A peer without pairing acceptance must time out")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .timedOut)
        }
    }

    @MainActor func testPairingTaskCancellationEndsPendingExchange() async throws {
        let listening = expectation(description: "Listener ready")
        let tlsReady = expectation(description: "TLS ready")
        let peer = try StalledTLSPeer(listenerReady: listening, peerReady: tlsReady)
        defer { peer.close() }
        await fulfillment(of: [listening], timeout: 5)
        let ticket = PairingTicket(
            endpoint: "127.0.0.1", port: try XCTUnwrap(peer.port),
            expiresAt: .now.addingTimeInterval(60), oneTimeSecret: "test-secret",
            daemonCertificateFingerprint: peer.fingerprint
        )
        let identity = IPhoneIdentity(deviceID: "test-phone", displayName: "Test phone", identity: peer.identity, certificate: Data())
        let task = Task { try await PairingClient().pair(ticket: ticket, identity: identity) }
        await fulfillment(of: [tlsReady], timeout: 5)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancellation must end the pairing exchange")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .cancelled)
        }
    }
}
