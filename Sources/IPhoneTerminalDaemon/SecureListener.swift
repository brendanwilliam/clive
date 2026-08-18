import CryptoKit
import Dispatch
import Foundation
import Network
import Security

enum SecureListenerError: LocalizedError {
    case unableToBind, failed(String)
    var errorDescription: String? {
        switch self {
        case .unableToBind: "Could not start the local TLS listener."
        case .failed(let message): "TLS listener failed: \(message)"
        }
    }
}

final class PeerTrustCache: @unchecked Sendable {
    private let lock = NSLock()
    private var devicesByFingerprint: [String: String] = [:]
    private var verifiedMetadata: [ObjectIdentifier: String] = [:]

    func replace(devices: [String: String]) { lock.withLock { devicesByFingerprint = devices } }

    func verify(metadata: sec_protocol_metadata_t, trust: sec_trust_t) -> Bool {
        let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
        guard let chain = SecTrustCopyCertificateChain(secTrust) as? [SecCertificate], let certificate = chain.first else { return false }
        let fingerprint = SHA256.hash(data: SecCertificateCopyData(certificate) as Data).map { String(format: "%02x", $0) }.joined()
        return lock.withLock {
            guard let deviceID = devicesByFingerprint[fingerprint] else { return false }
            verifiedMetadata[ObjectIdentifier(metadata)] = deviceID
            return true
        }
    }

    func consume(metadata: sec_protocol_metadata_t) -> String? {
        lock.withLock { verifiedMetadata.removeValue(forKey: ObjectIdentifier(metadata)) }
    }
}

final class SecureListener: @unchecked Sendable {
    typealias ConnectionHandler = @Sendable (NWConnection, DispatchQueue, String?) -> Void
    private let listener: NWListener
    private let queue: DispatchQueue
    private let peerTrust: PeerTrustCache?
    private let onConnection: ConnectionHandler
    private let onReady: @Sendable (UInt16) -> Void

    init(identity: SecIdentity, serviceID: String? = nil, peerTrust: PeerTrustCache? = nil, onReady: @escaping @Sendable (UInt16) -> Void = { _ in }, onConnection: @escaping ConnectionHandler) throws {
        self.peerTrust = peerTrust
        self.onConnection = onConnection
        self.onReady = onReady
        queue = DispatchQueue(label: "com.iphoneterminal.listener.\(UUID().uuidString)")
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv13)
        guard let networkIdentity = sec_identity_create(identity) else { throw SecureListenerError.unableToBind }
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, networkIdentity)
        if let peerTrust {
            sec_protocol_options_set_peer_authentication_required(tls.securityProtocolOptions, true)
            sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { metadata, trust, complete in
                complete(peerTrust.verify(metadata: metadata, trust: trust))
            }, queue)
        }
        listener = try NWListener(using: NWParameters(tls: tls, tcp: NWProtocolTCP.Options()))
        if let serviceID {
            let txt = NetService.data(fromTXTRecord: ["id": Data(serviceID.utf8), "v": Data(String(1).utf8)])
            listener.service = NWListener.Service(name: serviceID, type: "_iphone-terminal._tcp", txtRecord: txt)
        }
        listener.newConnectionHandler = { [weak self] connection in self?.prepare(connection) }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .ready = state, let port = listener.port?.rawValue { onReady(port) }
        }
    }

    func start() { listener.start(queue: queue) }
    func cancel() { listener.cancel() }
    var port: UInt16? { listener.port?.rawValue }

    private func prepare(_ connection: NWConnection) {
        guard peerTrust != nil else { onConnection(connection, queue, nil); return }
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            if case .ready = state {
                guard let metadata = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata,
                      let deviceID = peerTrust?.consume(metadata: metadata.securityProtocolMetadata) else {
                    connection.cancel(); return
                }
                onConnection(connection, queue, deviceID)
            }
        }
        connection.start(queue: queue)
    }
}
