import CryptoKit
import Foundation
import CliveCore
import Network
import Security

struct SessionAttemptState {
    private(set) var hasOpened = false
    private(set) var isFinished = false
    private var handshakeSent = false

    mutating func beginHandshake() -> Bool {
        guard !handshakeSent, !isFinished else { return false }
        handshakeSent = true
        return true
    }

    mutating func open() -> Bool {
        guard handshakeSent, !hasOpened, !isFinished else { return false }
        hasOpened = true
        return true
    }

    mutating func finish() -> Bool {
        guard !isFinished else { return false }
        isFinished = true
        return true
    }
}

final class SessionClient: @unchecked Sendable {
    static let connectionAttemptTimeout: TimeInterval = 60
    enum ClientError: Error { case certificateChanged, protocolViolation, unavailableIdentity }
    var onOutput: ((Data, Int) -> Void)?
    var onActivityOutput: ((Data, Int) -> Void)?
    var onState: ((State, Int) -> Void)?
    var onAttachmentState: ((AttachmentState, Int) -> Void)?
    var onRendezvousUpgrade: ((Data, RendezvousCapability, Int) -> Void)?
    enum State: Equatable {
        case connecting, reconnecting(waitingForWiFi: Bool), active(UUID, SessionOpened.Disposition, Bool), disconnected, resumeUnavailable, revoked, workingDirectoryUnavailable, certificateChanged, protocolError, networkError(String)
    }
    private let queue = DispatchQueue(label: "com.clive.session")
    private let attemptTimeout: TimeInterval
    private var connection: NWConnection?
    private var decoder = FrameDecoder()
    private var attemptState = SessionAttemptState()
    private var certificateMismatch = false
    private var pendingResize: TerminalSize?
    private var peerCertificate: Data?
    private var rendezvousCapability: RendezvousCapability?
    private var wanGateToken: Data?
    private var timeout: DispatchWorkItem?
    private var generation = 0
    private var lastSize: TerminalSize?
    private var lastReceivedOffset: UInt64 = 0

    init(attemptTimeout: TimeInterval = SessionClient.connectionAttemptTimeout) {
        self.attemptTimeout = attemptTimeout
    }

    var currentGeneration: Int { queue.sync { generation } }

    func connect(host: String, port: UInt16, pinnedFingerprint: String, identity: SecIdentity, clientSessionID: UUID, serverSessionID: UUID? = nil, size: TerminalSize, rendezvousCapability: RendezvousCapability? = nil, wanGateToken: Data? = nil, workingDirectory: String? = nil, expectsResumption: Bool = false) {
        queue.sync {
            connectOnQueue(host: host, port: port, pinnedFingerprint: pinnedFingerprint, identity: identity, clientSessionID: clientSessionID, serverSessionID: serverSessionID, size: size, rendezvousCapability: rendezvousCapability, wanGateToken: wanGateToken, workingDirectory: workingDirectory, expectsResumption: expectsResumption)
        }
    }

    private func connectOnQueue(host: String, port: UInt16, pinnedFingerprint: String, identity: SecIdentity, clientSessionID: UUID, serverSessionID: UUID?, size: TerminalSize, rendezvousCapability: RendezvousCapability?, wanGateToken: Data?, workingDirectory: String?, expectsResumption: Bool) {
        generation += 1
        let attempt = generation
        let requestedSize = lastSize ?? size
        lastSize = requestedSize
        timeout?.cancel(); connection?.stateUpdateHandler = nil; connection?.cancel()
        attemptState = SessionAttemptState()
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
        self.connection = connection; onState?(expectsResumption ? .reconnecting(waitingForWiFi: false) : .connecting, attempt)
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, self.generation == attempt else { return }
            switch state {
            case .ready:
                guard self.attemptState.beginHandshake() else { return }
                let frame: ProtocolFrame
                if let serverSessionID {
                    let request = SessionAttachRequest(serverSessionID: serverSessionID, lastReceivedOffset: self.lastReceivedOffset, attachmentKind: .iPhone, initialSize: requestedSize, wanGateToken: self.wanGateToken)
                    frame = ProtocolFrame(kind: .sessionAttach, payload: (try? ProtocolPayload.encode(request)) ?? Data())
                } else {
                    let request = SessionOpenRequest(clientSessionID: clientSessionID, initialSize: requestedSize, rendezvousCapability: self.rendezvousCapability, wanGateToken: self.wanGateToken, workingDirectory: workingDirectory, lastReceivedOffset: self.lastReceivedOffset)
                    frame = ProtocolFrame(kind: .sessionOpen, payload: (try? ProtocolPayload.encode(request)) ?? Data())
                }
                self.send(frame, on: connection); self.receive(on: connection, generation: attempt, expectsResumption: expectsResumption || serverSessionID != nil)
            case .failed(let error):
                self.reportTerminalState(self.certificateMismatch ? .certificateChanged : .networkError(error.localizedDescription))
                connection.cancel()
            case .cancelled:
                self.reportTerminalState(.disconnected)
            default: break
            }
        }
        connection.start(queue: queue)
        let timeout = DispatchWorkItem { [weak self, weak connection] in
            guard let self, self.generation == attempt, !self.attemptState.hasOpened else { return }
            self.reportTerminalState(.networkError("Connection attempt timed out."))
            connection?.cancel()
        }
        self.timeout = timeout; queue.asyncAfter(deadline: .now() + attemptTimeout, execute: timeout)
    }
    func sendInput(_ data: Data) {
        queue.sync {
            guard attemptState.hasOpened, !attemptState.isFinished else { return }
            send(ProtocolFrame(kind: .terminalInput, payload: data))
        }
    }
    func resize(_ size: TerminalSize) {
        queue.sync {
            lastSize = size
            guard attemptState.hasOpened, !attemptState.isFinished else { pendingResize = size; return }
            sendResize(size)
        }
    }
    func close() { queue.sync { generation += 1; timeout?.cancel(); send(ProtocolFrame(kind: .sessionClose)); connection?.cancel(); connection = nil; attemptState = SessionAttemptState() } }
    func terminate() { queue.sync { generation += 1; timeout?.cancel(); send(ProtocolFrame(kind: .sessionTerminate)); connection?.cancel(); connection = nil; attemptState = SessionAttemptState() } }
    func detach() { queue.sync { generation += 1; timeout?.cancel(); connection?.cancel(); connection = nil; attemptState = SessionAttemptState() } }
    private func send(_ frame: ProtocolFrame, on target: NWConnection? = nil) { guard let data = try? frame.encoded() else { return }; (target ?? connection)?.send(content: data, completion: .idempotent) }
    private func receive(on target: NWConnection, generation attempt: Int, expectsResumption: Bool) {
        target.receive(minimumIncompleteLength: 1, maximumLength: ProtocolFrame.defaultMaximumPayloadSize + 7) { [weak self, weak target] data, _, complete, error in
            guard let self, let target, self.generation == attempt, !self.attemptState.isFinished else { return }
            do { for frame in try self.decoder.append(data ?? Data()) { try self.handle(frame, expectsResumption: expectsResumption) } }
            catch { self.reportTerminalState(.protocolError); self.connection?.cancel(); return }
            if complete || error != nil { target.cancel() } else { self.receive(on: target, generation: attempt, expectsResumption: expectsResumption) }
        }
    }
    private func handle(_ frame: ProtocolFrame, expectsResumption: Bool) throws {
        guard !attemptState.isFinished else { return }
        if !attemptState.hasOpened {
            if frame.kind == .sessionError { return try handleError(frame) }
            guard frame.kind == .sessionOpened else { throw ClientError.protocolViolation }
            let reply = try ProtocolPayload.decode(SessionOpened.self, from: frame.payload)
            if expectsResumption && reply.disposition != .resumed {
                reportTerminalState(.resumeUnavailable)
                if let data = try? ProtocolFrame(kind: .sessionClose).encoded(), let connection {
                    connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
                } else { connection?.cancel() }
                return
            }
            guard attemptState.open() else { throw ClientError.protocolViolation }
            timeout?.cancel()
            if let certificate = peerCertificate, let capability = reply.rendezvousCapability { onRendezvousUpgrade?(certificate, capability, generation) }
            if let pendingResize { self.pendingResize = nil; sendResize(pendingResize) }
            onState?(.active(reply.serverSessionID, reply.disposition, reply.replayTruncated), generation); return
        }
        switch frame.kind {
        case .terminalOutput:
            let chunk = try ProtocolPayload.decode(TerminalOutputChunk.self, from: frame.payload)
            guard chunk.offset <= lastReceivedOffset else { throw ClientError.protocolViolation }
            let overlap = Int(lastReceivedOffset - chunk.offset)
            if overlap < chunk.bytes.count {
                let bytes = chunk.bytes.dropFirst(overlap); lastReceivedOffset += UInt64(bytes.count)
                onActivityOutput?(Data(bytes), generation); onOutput?(Data(bytes), generation)
            }
        case .sessionClose: reportTerminalState(.resumeUnavailable); connection?.cancel()
        case .attachmentState: onAttachmentState?(try ProtocolPayload.decode(AttachmentState.self, from: frame.payload), generation)
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
    private func reportTerminalState(_ state: State) {
        guard attemptState.finish() else { return }
        timeout?.cancel()
        onState?(state, generation)
    }
    private func sendResize(_ size: TerminalSize) {
        if let data = try? ProtocolPayload.encode(size) { send(ProtocolFrame(kind: .terminalResize, payload: data)) }
    }
}
