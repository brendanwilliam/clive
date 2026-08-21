import CryptoKit
import Foundation
import CliveCore
import Network
import Security

final class ReachabilityProbeClient: @unchecked Sendable {
    enum ProbeError: LocalizedError {
        case unavailable, certificateChanged, rejected, timedOut
        var errorDescription: String? {
            switch self {
            case .unavailable: "The cellular route is unavailable."
            case .certificateChanged: "The Mac certificate no longer matches this pairing."
            case .rejected: "The Mac rejected the cellular verification challenge."
            case .timedOut: "The cellular verification attempt timed out."
            }
        }
    }

    private let queue = DispatchQueue(label: "com.clive.reachability-probe")
    private var connection: NWConnection?
    private var decoder = FrameDecoder()
    private var completion: CheckedContinuation<Void, Error>?
    private var finished = false

    func run(route: MacRoute, challenge: UUID, pinnedFingerprint: String, identity: SecIdentity) async throws {
        try await withCheckedThrowingContinuation { continuation in
            completion = continuation
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv13)
            guard let localIdentity = sec_identity_create(identity), let port = NWEndpoint.Port(rawValue: route.port) else {
                return finish(.failure(ProbeError.unavailable))
            }
            sec_protocol_options_set_local_identity(tls.securityProtocolOptions, localIdentity)
            sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trust, complete in
                let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
                guard let chain = SecTrustCopyCertificateChain(secTrust) as? [SecCertificate], let certificate = chain.first else { complete(false); return }
                let fingerprint = SHA256.hash(data: SecCertificateCopyData(certificate) as Data).map { String(format: "%02x", $0) }.joined()
                complete(fingerprint == pinnedFingerprint.lowercased())
            }, queue)
            let connection = NWConnection(host: NWEndpoint.Host(route.host), port: port, using: NWParameters(tls: tls, tcp: NWProtocolTCP.Options()))
            self.connection = connection
            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    guard let token = route.wanGateToken,
                          let payload = try? ProtocolPayload.encode(ReachabilityProbe(challenge: challenge, wanGateToken: token)),
                          let data = try? ProtocolFrame(kind: .reachabilityProbe, payload: payload).encoded()
                    else { return self.finish(.failure(ProbeError.rejected)) }
                    connection.send(content: data, completion: .idempotent); self.receive(challenge: challenge)
                case .failed: self.finish(.failure(ProbeError.unavailable))
                case .cancelled: if !self.finished { self.finish(.failure(ProbeError.unavailable)) }
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 8) { [weak self] in self?.finish(.failure(ProbeError.timedOut)) }
        }
    }

    private func receive(challenge: UUID) {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self else { return }
            do {
                for frame in try decoder.append(data ?? Data()) {
                    guard frame.kind == .reachabilityVerified,
                          try ProtocolPayload.decode(ReachabilityVerified.self, from: frame.payload).challenge == challenge
                    else { throw ProbeError.rejected }
                    return finish(.success(()))
                }
            } catch { return finish(.failure(error)) }
            if complete || error != nil { finish(.failure(ProbeError.unavailable)) } else { receive(challenge: challenge) }
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        guard !finished else { return }; finished = true
        connection?.cancel(); connection = nil
        let value = completion; completion = nil; value?.resume(with: result)
    }
}
