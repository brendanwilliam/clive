import CryptoKit
import Foundation
import CliveCore
import Network
import Security

final class SessionClient: @unchecked Sendable {
    enum ClientError: Error { case certificateChanged, protocolViolation, unavailableIdentity }
    var onOutput: ((Data) -> Void)?
    var onActivityOutput: ((Data) -> Void)?
    var onState: ((State) -> Void)?
    var onRendezvousUpgrade: ((Data, RendezvousCapability) -> Void)?
    enum State: Equatable {
        case connecting, active(UUID), disconnected, revoked, certificateChanged, protocolError, networkError(String)
    }
    private let queue = DispatchQueue(label: "com.clive.session")
    private var connection: NWConnection?
    private var decoder = FrameDecoder()
    private var opened = false
    private var certificateMismatch = false
    private var terminalStateReported = false
    private var pendingResize: TerminalSize?
    private var peerCertificate: Data?
    private var rendezvousCapability: RendezvousCapability?
    private var wanGateToken: Data?
    private var timeout: DispatchWorkItem?

    func connect(host: String, port: UInt16, pinnedFingerprint: String, identity: SecIdentity, clientSessionID: UUID, size: TerminalSize, rendezvousCapability: RendezvousCapability? = nil, wanGateToken: Data? = nil) {
        opened = false
        terminalStateReported = false
        pendingResize = nil
        peerCertificate = nil; self.rendezvousCapability = rendezvousCapability; self.wanGateToken = wanGateToken
        let tls = NWProtocolTLS.Options(); sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv13)
        if let localIdentity = sec_identity_create(identity) { sec_protocol_options_set_local_identity(tls.securityProtocolOptions, localIdentity) }
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { metadata, trust, complete in
            let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
            guard let chain = SecTrustCopyCertificateChain(secTrust) as? [SecCertificate], let certificate = chain.first else { complete(false); return }
            let fingerprint = SHA256.hash(data: SecCertificateCopyData(certificate) as Data).map { String(format: "%02x", $0) }.joined()
            let matches = fingerprint == pinnedFingerprint.lowercased()
            if matches { self.peerCertificate = SecCertificateCopyData(certificate) as Data }
            if !matches { self.certificateMismatch = true }
            complete(matches)
        }, queue)
        let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: NWParameters(tls: tls, tcp: NWProtocolTCP.Options()))
        self.connection = connection; onState?(.connecting)
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.timeout?.cancel()
                self.send(ProtocolFrame(kind: .sessionOpen, payload: (try? ProtocolPayload.encode(SessionOpenRequest(clientSessionID: clientSessionID, initialSize: size, rendezvousCapability: self.rendezvousCapability, wanGateToken: self.wanGateToken))) ?? Data())); self.receive()
            case .failed(let error):
                self.timeout?.cancel()
                self.terminalStateReported = true
                self.onState?(self.certificateMismatch ? .certificateChanged : .networkError(error.localizedDescription))
            case .cancelled:
                if !self.terminalStateReported { self.onState?(.disconnected) }
            default: break
            }
        }
        connection.start(queue: queue)
        let timeout = DispatchWorkItem { [weak self, weak connection] in
            guard let self, !self.opened else { return }
            self.terminalStateReported = true; self.onState?(.networkError("Connection attempt timed out.")); connection?.cancel()
        }
        self.timeout = timeout; queue.asyncAfter(deadline: .now() + 5, execute: timeout)
    }
    func sendInput(_ data: Data) {
        guard opened else { return }
        send(ProtocolFrame(kind: .terminalInput, payload: data))
    }
    func resize(_ size: TerminalSize) {
        guard opened else { pendingResize = size; return }
        sendResize(size)
    }
    func close() { send(ProtocolFrame(kind: .sessionClose)); connection?.cancel(); connection = nil }
    private func send(_ frame: ProtocolFrame) { guard let data = try? frame.encoded() else { return }; connection?.send(content: data, completion: .idempotent) }
    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: ProtocolFrame.defaultMaximumPayloadSize + 7) { [weak self] data, _, complete, error in
            guard let self else { return }
            do { for frame in try self.decoder.append(data ?? Data()) { try self.handle(frame) } }
            catch { self.reportTerminalState(.protocolError); self.connection?.cancel(); return }
            if complete || error != nil { self.connection?.cancel() } else { self.receive() }
        }
    }
    private func handle(_ frame: ProtocolFrame) throws {
        if !opened {
            if frame.kind == .sessionError { return try handleError(frame) }
            guard frame.kind == .sessionOpened else { throw ClientError.protocolViolation }
            let reply = try ProtocolPayload.decode(SessionOpened.self, from: frame.payload)
            opened = true
            if let certificate = peerCertificate, let capability = reply.rendezvousCapability { onRendezvousUpgrade?(certificate, capability) }
            if let pendingResize { self.pendingResize = nil; sendResize(pendingResize) }
            onState?(.active(reply.serverSessionID)); return
        }
        switch frame.kind { case .terminalOutput: onActivityOutput?(frame.payload); onOutput?(frame.payload); case .sessionClose: connection?.cancel(); case .sessionError: try handleError(frame); default: throw ClientError.protocolViolation }
    }
    private func handleError(_ frame: ProtocolFrame) throws {
        let error = try ProtocolPayload.decode(SessionError.self, from: frame.payload)
        reportTerminalState(error.code == .revoked ? .revoked : .protocolError); connection?.cancel()
    }
    private func reportTerminalState(_ state: State) { terminalStateReported = true; onState?(state) }
    private func sendResize(_ size: TerminalSize) {
        if let data = try? ProtocolPayload.encode(size) { send(ProtocolFrame(kind: .terminalResize, payload: data)) }
    }
}
