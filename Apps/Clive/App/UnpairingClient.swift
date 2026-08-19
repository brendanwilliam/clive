import CliveCore
import CryptoKit
import Foundation
import Network
import Security

final class UnpairingClient: @unchecked Sendable {
    enum Error: LocalizedError {
        case noRoute
        case notAcknowledged
        case certificateChanged

        var errorDescription: String? {
            switch self {
            case .noRoute: "The Mac is unavailable. Connect to it before disconnecting."
            case .notAcknowledged: "The Mac did not confirm that this iPhone was unpaired."
            case .certificateChanged: "The Mac certificate changed. Verify and pair it again locally."
            }
        }
    }

    func revoke(device: PairedMac, routes: [MacRoute], identity: SecIdentity) async throws {
        guard !routes.isEmpty else { throw Error.noRoute }
        var lastError: Swift.Error = Error.notAcknowledged
        for route in routes {
            do {
                try await revoke(device: device, route: route, identity: identity)
                return
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private func revoke(device: PairedMac, route: MacRoute, identity: SecIdentity) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let attempt = Attempt(device: device, route: route, identity: identity, continuation: continuation)
            attempt.start()
        }
    }

    private final class Attempt: @unchecked Sendable {
        private let queue = DispatchQueue(label: "com.clive.unpair")
        private let expectedFingerprint: String
        private let connection: NWConnection
        private let continuation: CheckedContinuation<Void, Swift.Error>
        private var decoder = FrameDecoder()
        private var completed = false
        private let mismatch: MismatchBox

        init(device: PairedMac, route: MacRoute, identity: SecIdentity, continuation: CheckedContinuation<Void, Swift.Error>) {
            expectedFingerprint = device.certificateFingerprint.lowercased()
            self.continuation = continuation
            let mismatch = MismatchBox()
            self.mismatch = mismatch
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv13)
            if let localIdentity = sec_identity_create(identity) {
                sec_protocol_options_set_local_identity(tls.securityProtocolOptions, localIdentity)
            }
            let expected = expectedFingerprint
            sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trust, complete in
                let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
                guard let chain = SecTrustCopyCertificateChain(secTrust) as? [SecCertificate], let certificate = chain.first else {
                    complete(false)
                    return
                }
                let fingerprint = SHA256.hash(data: SecCertificateCopyData(certificate) as Data).map { String(format: "%02x", $0) }.joined()
                let matches = fingerprint == expected
                if !matches { mismatch.value = true }
                complete(matches)
            }, queue)
            connection = NWConnection(host: NWEndpoint.Host(route.host), port: NWEndpoint.Port(rawValue: route.port)!, using: NWParameters(tls: tls, tcp: NWProtocolTCP.Options()))
        }

        func start() {
            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.sendRequest()
                    self.receive()
                case .failed:
                    self.finish(.failure(self.mismatch.value ? Error.certificateChanged : Error.notAcknowledged))
                case .cancelled:
                    self.finish(.failure(Error.notAcknowledged))
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 5) { [weak self] in self?.finish(.failure(Error.notAcknowledged)) }
        }

        private final class MismatchBox: @unchecked Sendable { var value = false }

        private func sendRequest() {
            guard let data = try? ProtocolFrame(kind: .pairingRevoke).encoded() else {
                finish(.failure(Error.notAcknowledged))
                return
            }
            connection.send(content: data, completion: .idempotent)
        }

        private func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: ProtocolFrame.defaultMaximumPayloadSize + 7) { [weak self] data, _, complete, error in
                guard let self else { return }
                do {
                    for frame in try self.decoder.append(data ?? Data()) where frame.kind == .pairingRevoked && frame.payload.isEmpty {
                        self.finish(.success(()))
                        return
                    }
                } catch {
                    self.finish(.failure(Error.notAcknowledged))
                    return
                }
                if complete || error != nil { self.finish(.failure(Error.notAcknowledged)) }
                else { self.receive() }
            }
        }

        private func finish(_ result: Result<Void, Swift.Error>) {
            guard !completed else { return }
            completed = true
            connection.cancel()
            continuation.resume(with: result)
        }
    }
}
