import CryptoKit
import Foundation
import CliveCore
import Network
import Security

struct SessionCatalogResponseState {
    enum Event {
        case sessions([CliveCore.SessionDescriptor])
        case terminated([UUID])
    }

    private(set) var receivedInitialList = false

    mutating func accept(_ frame: ProtocolFrame, awaitingTermination: Bool) throws -> Event {
        if frame.kind == .sessionListResult {
            let result = try ProtocolPayload.decode(SessionListResult.self, from: frame.payload)
            receivedInitialList = true
            return .sessions(result.sessions)
        }
        if receivedInitialList, awaitingTermination, frame.kind == .sessionTerminateManyResult {
            let result = try ProtocolPayload.decode(SessionTerminateManyResult.self, from: frame.payload)
            return .terminated(result.terminatedSessionIDs)
        }
        throw SessionCatalogClient.CatalogError.protocolViolation
    }
}

final class SessionCatalogClient: @unchecked Sendable {
    static let initialResponseTimeout: TimeInterval = 60
    static let terminationResponseTimeout: TimeInterval = 15

    var onSessions: (([CliveCore.SessionDescriptor], Int) -> Void)?
    var onFailure: ((Int) -> Void)?
    private let queue = DispatchQueue(label: "com.clive.session-catalog")
    private let initialTimeoutInterval: TimeInterval
    private let terminationTimeoutInterval: TimeInterval
    private var connection: NWConnection?
    private var decoder = FrameDecoder()
    private var generation = 0
    private var requestSent = false
    private var responseState = SessionCatalogResponseState()
    private var failed = false
    private var initialTimeout: DispatchWorkItem?
    private var terminationTimeout: DispatchWorkItem?
    private var pendingTermination: ((Result<[UUID], Error>) -> Void)?

    enum CatalogError: Error { case notConnected, invalidRequest, connectionClosed, timedOut, protocolViolation }
    var currentGeneration: Int { queue.sync { generation } }

    init(initialTimeout: TimeInterval = SessionCatalogClient.initialResponseTimeout, terminationTimeout: TimeInterval = SessionCatalogClient.terminationResponseTimeout) {
        initialTimeoutInterval = initialTimeout
        terminationTimeoutInterval = terminationTimeout
    }

    func connect(host: String, port: UInt16, pinnedFingerprint: String, identity: SecIdentity, wanGateToken: Data?) {
        queue.sync { connectOnQueue(host: host, port: port, pinnedFingerprint: pinnedFingerprint, identity: identity, wanGateToken: wanGateToken) }
    }

    private func connectOnQueue(host: String, port: UInt16, pinnedFingerprint: String, identity: SecIdentity, wanGateToken: Data?) {
        invalidate(notify: false)
        generation += 1
        let attempt = generation
        decoder = FrameDecoder()
        requestSent = false
        responseState = SessionCatalogResponseState()
        failed = false
        onFailure?(attempt)

        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv13)
        if let localIdentity = sec_identity_create(identity) {
            sec_protocol_options_set_local_identity(tls.securityProtocolOptions, localIdentity)
        }
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trust, complete in
            let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
            guard let certificate = (SecTrustCopyCertificateChain(secTrust) as? [SecCertificate])?.first else {
                complete(false)
                return
            }
            let fingerprint = SHA256.hash(data: SecCertificateCopyData(certificate) as Data)
                .map { String(format: "%02x", $0) }
                .joined()
            complete(self.generation == attempt && fingerprint == pinnedFingerprint.lowercased())
        }, queue)

        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!,
            using: NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        )
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, self.generation == attempt, !self.failed else { return }
            switch state {
            case .ready:
                guard !self.requestSent else { return }
                self.requestSent = true
                let request = SessionListRequest(wanGateToken: wanGateToken)
                guard let payload = try? ProtocolPayload.encode(request),
                      let data = try? ProtocolFrame(kind: .sessionList, payload: payload).encoded() else {
                    self.fail(.invalidRequest)
                    return
                }
                connection.send(content: data, completion: .idempotent)
                self.receive(on: connection, generation: attempt)
            case .failed, .cancelled: self.fail(.connectionClosed)
            default: break
            }
        }
        connection.start(queue: queue)
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.generation == attempt, !self.responseState.receivedInitialList else { return }
            self.fail(.timedOut)
        }
        initialTimeout = timeout
        queue.asyncAfter(deadline: .now() + initialTimeoutInterval, execute: timeout)
    }

    func close() {
        queue.sync {
            generation += 1
            invalidate(notify: true)
        }
    }

    func terminate(sessionIDs: [UUID], completion: @escaping (Result<[UUID], Error>) -> Void) {
        queue.sync { terminateOnQueue(sessionIDs: sessionIDs, completion: completion) }
    }

    private func terminateOnQueue(sessionIDs: [UUID], completion: @escaping (Result<[UUID], Error>) -> Void) {
        guard !sessionIDs.isEmpty, sessionIDs.count <= SessionTerminateManyRequest.maximumSessionCount,
              let connection, responseState.receivedInitialList, !failed else {
            completion(.failure(CatalogError.notConnected)); return
        }
        guard pendingTermination == nil,
              let payload = try? ProtocolPayload.encode(SessionTerminateManyRequest(sessionIDs: sessionIDs)),
              let data = try? ProtocolFrame(kind: .sessionTerminateMany, payload: payload).encoded() else {
            completion(.failure(CatalogError.invalidRequest)); return
        }
        pendingTermination = completion
        connection.send(content: data, completion: .idempotent)
        let attempt = generation
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.generation == attempt, self.pendingTermination != nil else { return }
            self.fail(.timedOut)
        }
        terminationTimeout = timeout
        queue.asyncAfter(deadline: .now() + terminationTimeoutInterval, execute: timeout)
    }

    private func receive(on connection: NWConnection, generation attempt: Int) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: ProtocolFrame.defaultMaximumPayloadSize + 7) { [weak self, weak connection] data, _, complete, error in
            guard let self, let connection, self.generation == attempt, !self.failed else { return }
            do {
                for frame in try self.decoder.append(data ?? Data()) { try self.handle(frame, attempt: attempt) }
            } catch {
                self.fail(.protocolViolation)
                return
            }
            guard !self.failed else { return }
            if complete || error != nil { self.fail(.connectionClosed) }
            else { self.receive(on: connection, generation: attempt) }
        }
    }

    private func handle(_ frame: ProtocolFrame, attempt: Int) throws {
        switch try responseState.accept(frame, awaitingTermination: pendingTermination != nil) {
        case .sessions(let sessions):
            initialTimeout?.cancel()
            onSessions?(sessions, attempt)
        case .terminated(let terminated):
            terminationTimeout?.cancel()
            let completion = pendingTermination
            pendingTermination = nil
            completion?(.success(terminated))
        }
    }

    private func fail(_ error: CatalogError) {
        guard !failed else { return }
        failed = true
        invalidate(notify: true, error: error)
    }

    private func invalidate(notify: Bool, error: CatalogError = .connectionClosed) {
        initialTimeout?.cancel(); initialTimeout = nil
        terminationTimeout?.cancel(); terminationTimeout = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel(); connection = nil
        let completion = pendingTermination
        pendingTermination = nil
        completion?(.failure(error))
        if notify { onFailure?(generation) }
    }
}
