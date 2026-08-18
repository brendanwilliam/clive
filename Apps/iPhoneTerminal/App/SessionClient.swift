import CryptoKit
import Foundation
import IPhoneTerminalCore
import Network
import Security

final class SessionClient: @unchecked Sendable {
    enum ClientError: Error { case certificateChanged, protocolViolation, unavailableIdentity }
    var onOutput: ((Data) -> Void)?
    var onState: ((State) -> Void)?
    enum State: Equatable {
        case connecting, active(UUID), disconnected, revoked, certificateChanged, protocolError, networkError(String)
    }
    private let queue = DispatchQueue(label: "com.iphoneterminal.session")
    private var connection: NWConnection?
    private var decoder = FrameDecoder()
    private var opened = false
    private var certificateMismatch = false

    func connect(host: String, port: UInt16, pinnedFingerprint: String, identity: SecIdentity, size: TerminalSize) {
        let tls = NWProtocolTLS.Options(); sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv13)
        if let localIdentity = sec_identity_create(identity) { sec_protocol_options_set_local_identity(tls.securityProtocolOptions, localIdentity) }
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { metadata, trust, complete in
            let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
            guard let chain = SecTrustCopyCertificateChain(secTrust) as? [SecCertificate], let certificate = chain.first else { complete(false); return }
            let fingerprint = SHA256.hash(data: SecCertificateCopyData(certificate) as Data).map { String(format: "%02x", $0) }.joined()
            let matches = fingerprint == pinnedFingerprint.lowercased()
            if !matches { self.certificateMismatch = true }
            complete(matches)
        }, queue)
        let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: NWParameters(tls: tls, tcp: NWProtocolTCP.Options()))
        self.connection = connection; onState?(.connecting)
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready: self.send(ProtocolFrame(kind: .sessionOpen, payload: (try? ProtocolPayload.encode(SessionOpenRequest(initialSize: size))) ?? Data())); self.receive()
            case .failed(let error): self.onState?(self.certificateMismatch ? .certificateChanged : .networkError(error.localizedDescription))
            case .cancelled: self.onState?(.disconnected)
            default: break
            }
        }
        connection.start(queue: queue)
    }
    func sendInput(_ data: Data) { send(ProtocolFrame(kind: .terminalInput, payload: data)) }
    func resize(_ size: TerminalSize) { if let data = try? ProtocolPayload.encode(size) { send(ProtocolFrame(kind: .terminalResize, payload: data)) } }
    func close() { send(ProtocolFrame(kind: .sessionClose)); connection?.cancel(); connection = nil }
    private func send(_ frame: ProtocolFrame) { guard let data = try? frame.encoded() else { return }; connection?.send(content: data, completion: .idempotent) }
    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: ProtocolFrame.defaultMaximumPayloadSize + 7) { [weak self] data, _, complete, error in
            guard let self else { return }
            do { for frame in try self.decoder.append(data ?? Data()) { try self.handle(frame) } }
            catch { self.onState?(.protocolError); self.connection?.cancel(); return }
            if complete || error != nil { self.connection?.cancel() } else { self.receive() }
        }
    }
    private func handle(_ frame: ProtocolFrame) throws {
        if !opened {
            if frame.kind == .sessionError { return try handleError(frame) }
            guard frame.kind == .sessionOpened else { throw ClientError.protocolViolation }
            let reply = try ProtocolPayload.decode(SessionOpened.self, from: frame.payload); opened = true; onState?(.active(reply.sessionID)); return
        }
        switch frame.kind { case .terminalOutput: onOutput?(frame.payload); case .sessionClose: connection?.cancel(); case .sessionError: try handleError(frame); default: throw ClientError.protocolViolation }
    }
    private func handleError(_ frame: ProtocolFrame) throws {
        let error = try ProtocolPayload.decode(SessionError.self, from: frame.payload)
        onState?(error.code == .revoked ? .revoked : .protocolError); connection?.cancel()
    }
}
