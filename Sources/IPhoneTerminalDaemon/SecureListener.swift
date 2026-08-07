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

    init(identity: SecIdentity) throws {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv13)
        guard let networkIdentity = sec_identity_create(identity) else { throw SecureListenerError.unableToBind }
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, networkIdentity)
        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        listener = try NWListener(using: parameters)
        listener.service = NWListener.Service(name: nil, type: "_iphone-terminal._tcp")
        listener.newConnectionHandler = { connection in
            // Never expose a shell before a future handler completes certificate pinning and
            // application-frame authentication.
            connection.cancel()
        }
    }

    func start() {
        listener.start(queue: .main)
    }

    var port: UInt16? { listener.port?.rawValue }
}
