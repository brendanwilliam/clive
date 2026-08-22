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
    var onAttachmentState: ((AttachmentState) -> Void)?
    var onRendezvousUpgrade: ((Data, RendezvousCapability) -> Void)?
    enum State: Equatable {
        case connecting, reconnecting(waitingForWiFi: Bool), active(UUID, SessionOpened.Disposition, Bool), disconnected, resumeUnavailable, revoked, workingDirectoryUnavailable, certificateChanged, protocolError, networkError(String)
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
    private var generation = 0
    private var lastSize: TerminalSize?
    private var lastReceivedOffset: UInt64 = 0

    func connect(host: String, port: UInt16, pinnedFingerprint: String, identity: SecIdentity, clientSessionID: UUID, size: TerminalSize, rendezvousCapability: RendezvousCapability? = nil, wanGateToken: Data? = nil, workingDirectory: String? = nil, expectsResumption: Bool = false) {
        generation += 1
        let attempt = generation
        let requestedSize = lastSize ?? size
        lastSize = requestedSize
        timeout?.cancel(); connection?.stateUpdateHandler = nil; connection?.cancel()
        opened = false
        terminalStateReported = false
        decoder = FrameDecoder(); certificateMismatch = false
        peerCertificate = nil
        self.rendezvousCapability = rendezvousCapability; self.wanGateToken = wanGateToken
        let tls = NWProtocolTLS.Options(); sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv13)
        if let localIdentity = sec_identity_create(identity) { sec_protocol_options_set_local_identity(tls.securityProtocolOptions, localIdentity) }
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { metadata, trust, complete in
            let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
            guard let chain = SecTrustCopyCertificateChain(secTrust) as? [SecCertificate], let certificate = chain.first else { complete(false); return }
            let fingerprint = SHA256.hash(data: SecCertificateCopyData(certificate) as Data).map { String(format: "%02x", $0) }.joined()
            let matches = fingerprint == pinnedFingerprint.lowercased()
            guard self.generation == attempt else { complete(false); return }
            if matches { self.peerCertificate = SecCertificateCopyData(certificate) as Data }
            if !matches { self.certificateMismatch = true }
            complete(matches)
        }, queue)
        let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: NWParameters(tls: tls, tcp: NWProtocolTCP.Options()))
        self.connection = connection; onState?(expectsResumption ? .reconnecting(waitingForWiFi: false) : .connecting)
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, self.generation == attempt else { return }
            switch state {
            case .ready:
                self.timeout?.cancel()
                self.send(ProtocolFrame(kind: .sessionOpen, payload: (try? ProtocolPayload.encode(SessionOpenRequest(clientSessionID: clientSessionID, initialSize: requestedSize, rendezvousCapability: self.rendezvousCapability, wanGateToken: self.wanGateToken, workingDirectory: workingDirectory, lastReceivedOffset: self.lastReceivedOffset))) ?? Data()), on: connection); self.receive(on: connection, generation: attempt, expectsResumption: expectsResumption)
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
            guard let self, self.generation == attempt, !self.opened else { return }
            self.terminalStateReported = true; self.onState?(.networkError("Connection attempt timed out.")); connection?.cancel()
        }
        self.timeout = timeout; queue.asyncAfter(deadline: .now() + 5, execute: timeout)
    }
    func sendInput(_ data: Data) {
        guard opened else { return }
        send(ProtocolFrame(kind: .terminalInput, payload: data))
    }
    func resize(_ size: TerminalSize) {
        lastSize = size
        guard opened else { pendingResize = size; return }
        sendResize(size)
    }
    func close() { generation += 1; timeout?.cancel(); send(ProtocolFrame(kind: .sessionClose)); connection?.cancel(); connection = nil; opened = false }
    func terminate() { generation += 1; timeout?.cancel(); send(ProtocolFrame(kind: .sessionTerminate)); connection?.cancel(); connection = nil; opened = false }
    func detach() { generation += 1; timeout?.cancel(); terminalStateReported = true; connection?.cancel(); connection = nil; opened = false }
    private func send(_ frame: ProtocolFrame, on target: NWConnection? = nil) { guard let data = try? frame.encoded() else { return }; (target ?? connection)?.send(content: data, completion: .idempotent) }
    private func receive(on target: NWConnection, generation attempt: Int, expectsResumption: Bool) {
        target.receive(minimumIncompleteLength: 1, maximumLength: ProtocolFrame.defaultMaximumPayloadSize + 7) { [weak self, weak target] data, _, complete, error in
            guard let self, let target, self.generation == attempt else { return }
            do { for frame in try self.decoder.append(data ?? Data()) { try self.handle(frame, expectsResumption: expectsResumption) } }
            catch { self.reportTerminalState(.protocolError); self.connection?.cancel(); return }
            if complete || error != nil { target.cancel() } else { self.receive(on: target, generation: attempt, expectsResumption: expectsResumption) }
        }
    }
    private func handle(_ frame: ProtocolFrame, expectsResumption: Bool) throws {
        if !opened {
            if frame.kind == .sessionError { return try handleError(frame) }
            guard frame.kind == .sessionOpened else { throw ClientError.protocolViolation }
            let reply = try ProtocolPayload.decode(SessionOpened.self, from: frame.payload)
            if expectsResumption && reply.disposition != .resumed {
                terminalStateReported = true
                onState?(.resumeUnavailable)
                if let data = try? ProtocolFrame(kind: .sessionClose).encoded(), let connection {
                    connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
                } else { connection?.cancel() }
                return
            }
            opened = true
            if let certificate = peerCertificate, let capability = reply.rendezvousCapability { onRendezvousUpgrade?(certificate, capability) }
            if let pendingResize { self.pendingResize = nil; sendResize(pendingResize) }
            onState?(.active(reply.serverSessionID, reply.disposition, reply.replayTruncated)); return
        }
        switch frame.kind {
        case .terminalOutput:
            let chunk = try ProtocolPayload.decode(TerminalOutputChunk.self, from: frame.payload)
            guard chunk.offset <= lastReceivedOffset else { throw ClientError.protocolViolation }
            let overlap = Int(lastReceivedOffset - chunk.offset)
            if overlap < chunk.bytes.count {
                let bytes = chunk.bytes.dropFirst(overlap); lastReceivedOffset += UInt64(bytes.count)
                onActivityOutput?(Data(bytes)); onOutput?(Data(bytes))
            }
        case .sessionClose: reportTerminalState(.resumeUnavailable); connection?.cancel()
        case .attachmentState: onAttachmentState?(try ProtocolPayload.decode(AttachmentState.self, from: frame.payload))
        case .sessionError: try handleError(frame)
        default: throw ClientError.protocolViolation
        }
    }
    private func handleError(_ frame: ProtocolFrame) throws {
        let error = try ProtocolPayload.decode(SessionError.self, from: frame.payload)
        let state: State = switch error.code {
        case .revoked: .revoked
        case .workingDirectoryUnavailable: .workingDirectoryUnavailable
        case .authenticationFailed: .networkError("The route could not be authenticated.")
        case .sessionUnavailable: .resumeUnavailable
        case .slowConsumer: .networkError("This connection could not keep up with terminal output.")
        default: .protocolError
        }
        reportTerminalState(state); connection?.cancel()
    }
    private func reportTerminalState(_ state: State) { terminalStateReported = true; onState?(state) }
    private func sendResize(_ size: TerminalSize) {
        if let data = try? ProtocolPayload.encode(size) { send(ProtocolFrame(kind: .terminalResize, payload: data)) }
    }
}
