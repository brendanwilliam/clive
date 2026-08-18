import CryptoKit
import Foundation
import IPhoneTerminalCore
import Network
import Security

final class PairingClient: @unchecked Sendable {
    enum Error: Swift.Error { case certificateChanged, invalidAcceptance, protocolViolation }
    private let queue = DispatchQueue(label: "com.iphoneterminal.pairing")

    func pair(ticket: PairingTicket, identity: IPhoneIdentity) async throws -> PairedMac {
        try PairingTicketValidator.validate(ticket)
        let pin = PinResult()
        let options = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(options.securityProtocolOptions, .TLSv13)
        sec_protocol_options_set_verify_block(options.securityProtocolOptions, { _, trust, complete in
            let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
            guard let chain = SecTrustCopyCertificateChain(secTrust) as? [SecCertificate], let certificate = chain.first else { complete(false); return }
            let matches = Fingerprint.sha256(of: SecCertificateCopyData(certificate) as Data) == ticket.daemonCertificateFingerprint.lowercased()
            if !matches { pin.mismatch = true }; complete(matches)
        }, queue)
        guard let port = NWEndpoint.Port(rawValue: ticket.port) else { throw PairingTicketValidationError.invalidPort }
        let connection = NWConnection(host: NWEndpoint.Host(ticket.endpoint), port: port, using: NWParameters(tls: options, tcp: NWProtocolTCP.Options()))
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                let exchange = Exchange(connection: connection, ticket: ticket, identity: identity, pin: pin, continuation: continuation, queue: queue)
                exchange.start()
            }
        }, onCancel: { connection.cancel() })
    }

    private final class PinResult: @unchecked Sendable { private let lock = NSLock(); private var value = false; var mismatch: Bool { get { lock.withLock { value } } set { lock.withLock { value = newValue } } } }

    private final class Exchange: @unchecked Sendable {
        let connection: NWConnection; let ticket: PairingTicket; let identity: IPhoneIdentity
        let continuation: CheckedContinuation<PairedMac, Swift.Error>; let queue: DispatchQueue; let pin: PinResult
        var decoder = FrameDecoder(); var completed = false
        init(connection: NWConnection, ticket: PairingTicket, identity: IPhoneIdentity, pin: PinResult, continuation: CheckedContinuation<PairedMac, Swift.Error>, queue: DispatchQueue) {
            self.connection = connection; self.ticket = ticket; self.identity = identity; self.pin = pin; self.continuation = continuation; self.queue = queue
        }
        func start() {
            // NWConnection retains its state handler. Keep the exchange alive through the TLS
            // handshake and break the retain cycle in finish after the result is delivered.
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: self.sendRequest(); self.receive()
                case .failed(let error): self.finish(.failure(self.pin.mismatch ? Error.certificateChanged : error))
                case .cancelled: if !self.completed { self.finish(.failure(URLError(.cancelled))) }
                default: break
                }
            }
            connection.start(queue: queue)
        }
        func sendRequest() {
            let request = PairingRequest(oneTimeSecret: ticket.oneTimeSecret, deviceID: identity.deviceID, deviceName: identity.displayName, certificate: identity.certificate)
            guard let payload = try? ProtocolPayload.encode(request), let bytes = try? ProtocolFrame(kind: .pairingRequest, payload: payload).encoded() else { finish(.failure(Error.protocolViolation)); return }
            connection.send(content: bytes, completion: .contentProcessed { [weak self] error in if let error { self?.finish(.failure(error)) } })
        }
        func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: ProtocolFrame.defaultMaximumPayloadSize + 7) { [weak self] data, _, complete, error in
                guard let self else { return }
                do {
                    let frames = try decoder.append(data ?? Data())
                    guard frames.count <= 1 else { throw Error.protocolViolation }
                    if let frame = frames.first { try accept(frame); return }
                    if complete || error != nil { throw error ?? URLError(.networkConnectionLost) }
                    receive()
                } catch { finish(.failure(error)) }
            }
        }
        func accept(_ frame: ProtocolFrame) throws {
            guard frame.kind == .pairingAccept else { throw Error.protocolViolation }
            let acceptance = try ProtocolPayload.decode(PairingAcceptance.self, from: frame.payload)
            let fingerprint = Fingerprint.sha256(of: acceptance.certificate)
            guard fingerprint == ticket.daemonCertificateFingerprint.lowercased(), !acceptance.macID.isEmpty, !acceptance.serviceID.isEmpty else { throw Error.invalidAcceptance }
            finish(.success(PairedMac(id: acceptance.macID, displayName: acceptance.displayName, serviceID: acceptance.serviceID, certificateFingerprint: fingerprint, createdAt: .now)))
        }
        func finish(_ result: Result<PairedMac, Swift.Error>) {
            guard !completed else { return }
            completed = true
            connection.stateUpdateHandler = nil
            connection.cancel()
            continuation.resume(with: result)
        }
    }
}
