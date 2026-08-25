import CryptoKit
import Foundation
import CliveCore
import Network
import Security

final class SessionCatalogClient: @unchecked Sendable {
    var onSessions: (([CliveCore.SessionDescriptor]) -> Void)?
    private let queue = DispatchQueue(label: "com.clive.session-catalog")
    private var connection: NWConnection?
    private var decoder = FrameDecoder()
    private var generation = 0
    private var pendingTermination: ((Result<[UUID], Error>) -> Void)?

    enum CatalogError: Error { case notConnected, invalidRequest, connectionClosed }

    func connect(host: String, port: UInt16, pinnedFingerprint: String, identity: SecIdentity, wanGateToken: Data?) {
        generation += 1
        let attempt = generation
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        decoder = FrameDecoder()

        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv13)
        if let localIdentity = sec_identity_create(identity) {
            sec_protocol_options_set_local_identity(tls.securityProtocolOptions, localIdentity)
        }
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { metadata, trust, complete in
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
            guard let self, self.generation == attempt else { return }
            guard case .ready = state else { return }
            let request = SessionListRequest(wanGateToken: wanGateToken)
            guard let payload = try? ProtocolPayload.encode(request),
                  let data = try? ProtocolFrame(kind: .sessionList, payload: payload).encoded() else { return }
            connection.send(content: data, completion: .idempotent)
            self.receive(on: connection, generation: attempt)
        }
        connection.start(queue: queue)
    }

    func close() {
        generation += 1
        pendingTermination?(.failure(CatalogError.connectionClosed)); pendingTermination = nil
        connection?.cancel()
        connection = nil
    }

    func terminate(sessionIDs: [UUID], completion: @escaping (Result<[UUID], Error>) -> Void) {
        guard !sessionIDs.isEmpty, sessionIDs.count <= SessionTerminateManyRequest.maximumSessionCount,
              let connection else { completion(.failure(CatalogError.notConnected)); return }
        guard pendingTermination == nil,
              let payload = try? ProtocolPayload.encode(SessionTerminateManyRequest(sessionIDs: sessionIDs)),
              let data = try? ProtocolFrame(kind: .sessionTerminateMany, payload: payload).encoded() else {
            completion(.failure(CatalogError.invalidRequest)); return
        }
        pendingTermination = completion
        connection.send(content: data, completion: .idempotent)
    }

    private func receive(on connection: NWConnection, generation attempt: Int) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: ProtocolFrame.defaultMaximumPayloadSize + 7) { [weak self, weak connection] data, _, complete, error in
            guard let self, let connection, self.generation == attempt else { return }
            if let data, let frames = try? self.decoder.append(data) {
                for frame in frames where frame.kind == .sessionListResult {
                    guard let result = try? ProtocolPayload.decode(SessionListResult.self, from: frame.payload) else { continue }
                    self.onSessions?(result.sessions)
                }
                for frame in frames where frame.kind == .sessionTerminateManyResult {
                    guard let result = try? ProtocolPayload.decode(SessionTerminateManyResult.self, from: frame.payload) else { continue }
                    let completion = self.pendingTermination; self.pendingTermination = nil
                    completion?(.success(result.terminatedSessionIDs))
                }
            }
            if !complete && error == nil { self.receive(on: connection, generation: attempt) }
        }
    }
}
