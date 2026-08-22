import Foundation
import CliveCore
import Network

/// One authenticated TLS connection attaches to a daemon-owned PTY.
final class SessionConnectionHandler: @unchecked Sendable {
    let identifier = UUID()
    private let deviceID: String
    private let peerCertificate: Data?
    private let requiresWANGate: Bool
    private let localCapability: RendezvousCapability?
    private let sessions: TerminalSessionManager
    private let queue: DispatchQueue
    private var framed: FramedConnection?
    private var sessionID: UUID?
    private var clientSessionID: UUID?
    private var opening = false
    private var closed = false
    private let onClosed: @Sendable (UUID) -> Void
    private let validateGate: @Sendable (String, Data?) async -> Bool
    private let upgradePeer: @Sendable (String, Data, RendezvousCapability) async -> Void
    private let revokePeer: @Sendable (String, UUID) async -> Bool
    private let verifyReachability: @Sendable (String, UUID, Data?) async -> Bool

    init(deviceID: String, peerCertificate: Data? = nil, requiresWANGate: Bool = false, localCapability: RendezvousCapability? = nil, sessions: TerminalSessionManager, queue: DispatchQueue, validateGate: @escaping @Sendable (String, Data?) async -> Bool = { _, _ in true }, upgradePeer: @escaping @Sendable (String, Data, RendezvousCapability) async -> Void = { _, _, _ in }, revokePeer: @escaping @Sendable (String, UUID) async -> Bool = { _, _ in false }, verifyReachability: @escaping @Sendable (String, UUID, Data?) async -> Bool = { _, _, _ in false }, onClosed: @escaping @Sendable (UUID) -> Void = { _ in }) {
        self.deviceID = deviceID; self.sessions = sessions; self.queue = queue
        self.peerCertificate = peerCertificate; self.requiresWANGate = requiresWANGate; self.localCapability = localCapability
        self.validateGate = validateGate; self.upgradePeer = upgradePeer
        self.revokePeer = revokePeer
        self.verifyReachability = verifyReachability
        self.onClosed = onClosed
    }

    func start(_ connection: NWConnection) {
        let framed = FramedConnection(connection: connection, queue: queue, onFrame: { [weak self] frame in
            self?.handle(frame)
        }, onClosed: { [weak self] in self?.close() })
        self.framed = framed
        framed.start(alreadyStarted: true)
    }

    func close(terminateSession: Bool = false) {
        guard !closed else { return }; closed = true
        framed?.cancel(); framed = nil
        if let clientSessionID {
            if terminateSession { sessions.close(deviceID: deviceID, clientSessionID: clientSessionID, attachmentID: identifier) }
            else { sessions.detach(deviceID: deviceID, clientSessionID: clientSessionID, attachmentID: identifier) }
        }
        onClosed(identifier)
    }

    func revoke() { queue.async { [weak self] in self?.fail(.revoked, "This iPhone was revoked") } }

    private func handle(_ frame: ProtocolFrame) {
        if sessionID == nil {
            if !opening, frame.kind == .reachabilityProbe,
               let probe = try? ProtocolPayload.decode(ReachabilityProbe.self, from: frame.payload) {
                opening = true
                Task {
                    let verified = requiresWANGate
                        ? await verifyReachability(deviceID, probe.challenge, probe.wanGateToken)
                        : false
                    queue.async { [weak self] in self?.finishReachability(challenge: probe.challenge, succeeded: verified) }
                }
                return
            }
            if !opening, frame.kind == .pairingRevoke, frame.payload.isEmpty {
                opening = true
                Task {
                    let revoked = await revokePeer(deviceID, identifier)
                    queue.async { [weak self] in self?.finishRevocation(succeeded: revoked) }
                }
                return
            }
            guard !opening, frame.kind == .sessionOpen,
                  let request = try? ProtocolPayload.decode(SessionOpenRequest.self, from: frame.payload),
                  request.initialSize.isValid else {
                print("Session: invalid opening frame received.")
                return fail(.invalidFrameOrder, "session.open must be the first frame")
            }
            print("Session: opening shell.")
            opening = true
            Task {
                let gateAllowed = requiresWANGate ? await validateGate(deviceID, request.wanGateToken) : true
                guard gateAllowed else {
                    queue.async { [weak self] in self?.fail(.authenticationFailed, "Cellular access is disabled or the rendezvous record expired") }
                    return
                }
                if let certificate = peerCertificate, let capability = request.rendezvousCapability { await upgradePeer(deviceID, certificate, capability) }
                queue.async { [weak self] in self?.finishOpening(request: request) }
            }
            return
        }
        switch frame.kind {
        case .terminalInput:
            do { if let clientSessionID { try sessions.input(deviceID: deviceID, clientSessionID: clientSessionID, attachmentID: identifier, bytes: frame.payload) } }
            catch { print("Session: terminal input failed: \(error.localizedDescription)"); close() }
        case .terminalResize:
            guard let size = try? ProtocolPayload.decode(TerminalSize.self, from: frame.payload), size.isValid else {
                return fail(.protocolError, "Invalid terminal size")
            }
            if let clientSessionID { sessions.resize(deviceID: deviceID, clientSessionID: clientSessionID, attachmentID: identifier, size: size) }
        case .resizeClaim:
            if let clientSessionID { sessions.claimResize(deviceID: deviceID, clientSessionID: clientSessionID, attachmentID: identifier) }
        case .sessionClose: close(terminateSession: true)
        default: fail(.invalidFrameOrder, "Frame is not valid in an open session")
        }
    }

    private func finishReachability(challenge: UUID, succeeded: Bool) {
        guard succeeded, let data = try? ProtocolPayload.encode(ReachabilityVerified(challenge: challenge)) else {
            return fail(.authenticationFailed, "The cellular verification challenge is invalid or expired")
        }
        framed?.send(ProtocolFrame(kind: .reachabilityVerified, payload: data)) { [weak self] _ in self?.close() }
    }

    private func finishRevocation(succeeded: Bool) {
        guard succeeded else { return fail(.protocolError, "Unable to revoke this iPhone") }
        framed?.send(ProtocolFrame(kind: .pairingRevoked)) { [weak self] _ in self?.close() }
    }

    private func finishOpening(request: SessionOpenRequest) {
        guard !closed else { return }
        do {
            opening = false
            let attachment = try sessions.attach(
                deviceID: deviceID,
                clientSessionID: request.clientSessionID,
                size: request.initialSize,
                workingDirectory: request.workingDirectory,
                attachmentID: identifier,
                attachmentKind: request.attachmentKind,
                lastReceivedOffset: request.lastReceivedOffset,
                output: { [weak self] chunk, completion in
                    guard let self else { completion(); return }
                    self.queue.async { self.sendOutput(chunk, completion: completion) }
                },
                onSuperseded: { [weak self] in
                    guard let self else { return }
                    self.queue.async { self.close() }
                },
                onShellExit: { [weak self] in
                    guard let self else { return }
                    self.queue.async { self.shellExited() }
                }
            )
            clientSessionID = request.clientSessionID; sessionID = attachment.serverSessionID
            let data = try ProtocolPayload.encode(SessionOpened(serverSessionID: attachment.serverSessionID, rendezvousCapability: localCapability, disposition: attachment.disposition, replayTruncated: attachment.replayTruncated))
            framed?.send(ProtocolFrame(kind: .sessionOpened, payload: data))
            if !attachment.replay.isEmpty {
                let chunk = TerminalOutputChunk(offset: attachment.replayOffset, bytes: attachment.replay)
                framed?.send(ProtocolFrame(kind: .terminalOutput, payload: try ProtocolPayload.encode(chunk)))
            }
            print("Session: shell opened.")
        } catch PTYProcessError.invalidWorkingDirectory {
            fail(.workingDirectoryUnavailable, "The configured working directory is unavailable. Choose another directory in Settings.")
        } catch {
            print("Session: shell creation failed.")
            fail(.shellCreationFailed, "Unable to create login shell")
        }
    }

    private func sendOutput(_ chunk: TerminalOutputChunk, completion: @escaping @Sendable () -> Void) {
        guard !closed else { completion(); return }
        guard let payload = try? ProtocolPayload.encode(chunk) else { completion(); return }
        framed?.send(ProtocolFrame(kind: .terminalOutput, payload: payload)) { _ in completion() }
    }

    private func shellExited() {
        guard !closed else { return }
        framed?.send(ProtocolFrame(kind: .sessionClose)) { [weak self] _ in self?.close() }
    }

    private func fail(_ code: SessionError.Code, _ message: String) {
        if let data = try? ProtocolPayload.encode(SessionError(code: code, message: message)) {
            framed?.send(ProtocolFrame(kind: .sessionError, payload: data))
        }
        close(terminateSession: true)
    }
}
