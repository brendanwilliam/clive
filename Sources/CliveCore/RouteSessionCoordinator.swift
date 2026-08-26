import Foundation

/// Owns the transport-independent part of one terminal session.
///
/// Adapters only establish a route-specific connection. This coordinator keeps
/// authentication, attachment, traffic, and handoff ordering identical for
/// every route and never replaces a working connection until the new one has
/// replayed from the requested offset.
public actor RouteSessionCoordinator {
    private var connection: (any RouteConnection)?
    public private(set) var selectedCandidate: RouteCandidate?

    public init() {}

    @discardableResult
    public func connect(
        using adapter: any RouteAdapter,
        candidate: RouteCandidate,
        serverSessionID: UUID,
        lastReceivedOffset: UInt64,
        initialSize: TerminalSize
    ) async throws -> SessionOpened {
        let replacement = try await prepareConnection(
            using: adapter,
            candidate: candidate,
            serverSessionID: serverSessionID,
            lastReceivedOffset: lastReceivedOffset,
            initialSize: initialSize
        )
        connection = replacement.connection
        selectedCandidate = candidate
        return replacement.opened
    }

    @discardableResult
    public func handoff(
        using adapter: any RouteAdapter,
        candidate: RouteCandidate,
        serverSessionID: UUID,
        lastReceivedOffset: UInt64,
        initialSize: TerminalSize
    ) async throws -> SessionOpened {
        let replacement = try await prepareConnection(
            using: adapter,
            candidate: candidate,
            serverSessionID: serverSessionID,
            lastReceivedOffset: lastReceivedOffset,
            initialSize: initialSize
        )
        let previous = connection
        connection = replacement.connection
        selectedCandidate = candidate
        await previous?.close()
        return replacement.opened
    }

    public func sendInput(_ data: Data) async throws {
        guard let connection else { throw RouteSessionError.notConnected }
        try await connection.sendInput(data)
    }

    public func resize(_ size: TerminalSize) async throws {
        guard let connection else { throw RouteSessionError.notConnected }
        try await connection.resize(size)
    }

    public func receiveOutput() async throws -> TerminalOutputChunk {
        guard let connection else { throw RouteSessionError.notConnected }
        return try await connection.receiveOutput()
    }

    public func close() async {
        await connection?.close()
        connection = nil
        selectedCandidate = nil
    }

    private func prepareConnection(
        using adapter: any RouteAdapter,
        candidate: RouteCandidate,
        serverSessionID: UUID,
        lastReceivedOffset: UInt64,
        initialSize: TerminalSize
    ) async throws -> (connection: any RouteConnection, opened: SessionOpened) {
        let candidateConnection = try await adapter.connect(to: candidate)
        do {
            try await candidateConnection.authenticate()
            let opened = try await candidateConnection.attach(
                serverSessionID: serverSessionID,
                lastReceivedOffset: lastReceivedOffset,
                initialSize: initialSize
            )
            return (candidateConnection, opened)
        } catch {
            await candidateConnection.close()
            throw error
        }
    }
}

public enum RouteSessionError: Error, Equatable, Sendable {
    case notConnected
}
