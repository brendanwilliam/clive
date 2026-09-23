import Foundation
import Network
import XCTest
@testable import CliveDaemon
import CliveCore

private final class HandshakeTestProcess: TerminalProcess, @unchecked Sendable {
    func write(_ bytes: Data) throws {}
    func resize(to size: TerminalSize) {}
    func suspendOutput() {}
    func resumeOutput() {}
    func terminate() {}
}

private final class OpenedFrameReceiver: @unchecked Sendable {
    private let connection: NWConnection
    private let opened: XCTestExpectation
    private var decoder = FrameDecoder()

    init(connection: NWConnection, opened: XCTestExpectation) {
        self.connection = connection
        self.opened = opened
    }

    func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [self] data, _, complete, error in
            guard let data, let frames = try? decoder.append(data) else { return }
            if frames.contains(where: { $0.kind == .sessionOpened }) { opened.fulfill() }
            else if !complete, error == nil { receive() }
        }
    }
}

final class SessionConnectionHandlerTests: XCTestCase {
    private func connect(to handler: SessionConnectionHandler, queue: DispatchQueue) throws -> (NWListener, NWConnection) {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters, on: .any)
        let listenerReady = expectation(description: "Listener ready")
        listener.newConnectionHandler = { connection in
            connection.stateUpdateHandler = { state in
                if case .ready = state { handler.start(connection) }
            }
            connection.start(queue: queue)
        }
        listener.stateUpdateHandler = { state in
            if case .ready = state { listenerReady.fulfill() }
        }
        listener.start(queue: queue)
        wait(for: [listenerReady], timeout: 3)
        let clientReady = expectation(description: "Client ready")
        let client = NWConnection(host: "127.0.0.1", port: try XCTUnwrap(listener.port), using: .tcp)
        client.stateUpdateHandler = { state in
            if case .ready = state { clientReady.fulfill() }
        }
        client.start(queue: queue)
        wait(for: [clientReady], timeout: 3)
        return (listener, client)
    }

    private func makeManager() -> TerminalSessionManager {
        TerminalSessionManager(registry: SessionRegistry(), processFactory: { _, _, _, _ in HandshakeTestProcess() })
    }

    func testIdleAuthenticatedConnectionClosesWithoutAllocatingPTY() throws {
        let queue = DispatchQueue(label: "test.session.idle")
        let manager = makeManager()
        defer { manager.shutdown() }
        let closed = expectation(description: "Idle handler closed")
        let handler = SessionConnectionHandler(
            deviceID: "phone", sessions: manager, queue: queue, firstFrameTimeout: 0.1,
            onClosed: { _ in closed.fulfill() }
        )
        let (listener, client) = try connect(to: handler, queue: queue)
        defer { client.cancel(); listener.cancel() }

        wait(for: [closed], timeout: 2)
        XCTAssertTrue(manager.descriptors(deviceID: "phone").isEmpty)
    }

    func testMalformedFirstFrameClosesWithoutAllocatingPTY() throws {
        let queue = DispatchQueue(label: "test.session.malformed")
        let manager = makeManager()
        defer { manager.shutdown() }
        let closed = expectation(description: "Malformed handler closed")
        let handler = SessionConnectionHandler(
            deviceID: "phone", sessions: manager, queue: queue,
            onClosed: { _ in closed.fulfill() }
        )
        let (listener, client) = try connect(to: handler, queue: queue)
        defer { client.cancel(); listener.cancel() }
        client.send(content: try ProtocolFrame(kind: .terminalInput, payload: Data("x".utf8)).encoded(), completion: .idempotent)

        wait(for: [closed], timeout: 2)
        XCTAssertTrue(manager.descriptors(deviceID: "phone").isEmpty)
    }

    func testDelayedRendezvousUpgradeDoesNotDelaySessionOpened() throws {
        let queue = DispatchQueue(label: "test.session.upgrade")
        let manager = makeManager()
        defer { manager.shutdown() }
        let upgradeFinished = expectation(description: "Upgrade finished")
        let capability = RendezvousCapability(
            keys: RendezvousPublicKeys(agreement: Data([1]), signing: Data([2])),
            accountBinding: "test-account"
        )
        let handler = SessionConnectionHandler(
            deviceID: "phone", peerCertificate: Data([3]), sessions: manager, queue: queue,
            upgradePeer: { _, _, _ in
                try? await Task.sleep(for: .seconds(1))
                upgradeFinished.fulfill()
            }
        )
        let (listener, client) = try connect(to: handler, queue: queue)
        defer { client.cancel(); listener.cancel(); handler.close() }
        let opened = expectation(description: "Session opened")
        let request = SessionOpenRequest(
            clientSessionID: UUID(), initialSize: TerminalSize(columns: 80, rows: 24),
            rendezvousCapability: capability
        )
        let payload = try ProtocolPayload.encode(request)
        OpenedFrameReceiver(connection: client, opened: opened).receive()
        client.send(content: try ProtocolFrame(kind: .sessionOpen, payload: payload).encoded(), completion: .idempotent)

        wait(for: [opened], timeout: 0.7)
        XCTAssertEqual(manager.descriptors(deviceID: "phone").count, 1)
        wait(for: [upgradeFinished], timeout: 2)
    }
}
