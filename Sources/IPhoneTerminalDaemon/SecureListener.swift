import Dispatch
import Foundation
import Network
import Security

enum SecureListenerError: LocalizedError {
    case unableToBind

    var errorDescription: String? { "Could not start the local TLS listener." }
}

/// TLS 1.3 listener advertising the non-secret Bonjour service metadata. Connections are
/// deliberately rejected until the pairing/session frame handler has authenticated the peer.
final class SecureListener {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.iphoneterminal.listener")
    private let onConnection: @Sendable (NWConnection, DispatchQueue) -> Void

    init(identity: SecIdentity, onConnection: @escaping @Sendable (NWConnection, DispatchQueue) -> Void = { connection, _ in connection.cancel() }) throws {
        self.onConnection = onConnection
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv13)
        guard let networkIdentity = sec_identity_create(identity) else { throw SecureListenerError.unableToBind }
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, networkIdentity)
        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        listener = try NWListener(using: parameters)
        listener.service = NWListener.Service(name: nil, type: "_iphone-terminal._tcp")
        listener.newConnectionHandler = { [onConnection, queue] connection in onConnection(connection, queue) }
    }

    func start() {
        listener.start(queue: queue)
    }

    var port: UInt16? { listener.port?.rawValue }
}
