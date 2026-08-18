import Foundation
import IPhoneTerminalCore
import Network

/// One authenticated TLS connection owns one PTY. The stable client ID permits a fresh
/// connection to replace a stale PTY after network handoff.
final class SessionConnectionHandler: @unchecked Sendable {
    let identifier = UUID()
    private let deviceID: String
    private let peerCertificate: Data?
    private let requiresWANGate: Bool
    private let localCapability: RendezvousCapability?
    private let registry: SessionRegistry
    private let queue: DispatchQueue
    private var framed: FramedConnection?
    private var shell: PTYProcess?
    private var sessionID: UUID?
    private var opening = false
    private var flow = OutputBackpressure()
    private var closed = false
    private let onClosed: @Sendable (UUID) -> Void
    private let replaceExisting: @Sendable (String, UUID, SessionConnectionHandler) async -> Void
    private let validateGate: @Sendable (String, Data?) async -> Bool
    private let upgradePeer: @Sendable (String, Data, RendezvousCapability) async -> Void

    init(deviceID: String, peerCertificate: Data? = nil, requiresWANGate: Bool = false, localCapability: RendezvousCapability? = nil, registry: SessionRegistry, queue: DispatchQueue, validateGate: @escaping @Sendable (String, Data?) async -> Bool = { _, _ in true }, upgradePeer: @escaping @Sendable (String, Data, RendezvousCapability) async -> Void = { _, _, _ in }, onClosed: @escaping @Sendable (UUID) -> Void = { _ in }, replaceExisting: @escaping @Sendable (String, UUID, SessionConnectionHandler) async -> Void = { _, _, _ in }) {
        self.deviceID = deviceID; self.registry = registry; self.queue = queue
        self.peerCertificate = peerCertificate; self.requiresWANGate = requiresWANGate; self.localCapability = localCapability
        self.validateGate = validateGate; self.upgradePeer = upgradePeer
        self.onClosed = onClosed
        self.replaceExisting = replaceExisting
    }

    func start(_ connection: NWConnection) {
        let framed = FramedConnection(connection: connection, queue: queue, onFrame: { [weak self] frame in
            self?.handle(frame)
        }, onClosed: { [weak self] in self?.close() })
        self.framed = framed
        framed.start(alreadyStarted: true)
    }

    func close() {
        guard !closed else { return }; closed = true
        shell?.terminate(); shell = nil; framed?.cancel(); framed = nil
        if let sessionID { Task { await registry.close(id: sessionID) } }
        onClosed(identifier)
    }

    func revoke() { queue.async { [weak self] in self?.fail(.revoked, "This iPhone was revoked") } }

    private func handle(_ frame: ProtocolFrame) {
        if shell == nil {
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
                await replaceExisting(deviceID, request.clientSessionID, self)
                let session = await registry.open(deviceID: deviceID, clientSessionID: request.clientSessionID, size: request.initialSize)
                queue.async { [weak self] in self?.finishOpening(session: session, size: request.initialSize) }
            }
            return
        }
        switch frame.kind {
        case .terminalInput:
            do { try shell?.write(frame.payload) }
            catch { print("Session: terminal input failed: \(error.localizedDescription)"); close() }
        case .terminalResize:
            guard let size = try? ProtocolPayload.decode(TerminalSize.self, from: frame.payload), size.isValid else {
                return fail(.protocolError, "Invalid terminal size")
            }
            shell?.resize(to: size)
        case .sessionClose: close()
        default: fail(.invalidFrameOrder, "Frame is not valid in an open session")
        }
    }

    private func finishOpening(session: TerminalSession, size: TerminalSize) {
        guard !closed else { Task { await registry.close(id: session.id) }; return }
        do {
            opening = false
            shell = try PTYProcess(size: size) { [weak self] bytes in
                guard let owner = self else { return }; owner.queue.async { [weak owner] in owner?.sendOutput(bytes) }
            }
            sessionID = session.id
            let data = try ProtocolPayload.encode(SessionOpened(serverSessionID: session.id, rendezvousCapability: localCapability))
            framed?.send(ProtocolFrame(kind: .sessionOpened, payload: data))
            print("Session: shell opened.")
        } catch {
            print("Session: shell creation failed: \(error.localizedDescription)")
            Task { await registry.close(id: session.id) }
            fail(.shellCreationFailed, "Unable to create login shell")
        }
    }

    private func sendOutput(_ bytes: Data) {
        guard !closed else { return }
        if flow.enqueue(bytes.count) { shell?.suspendOutput() }
        framed?.send(ProtocolFrame(kind: .terminalOutput, payload: bytes)) { [weak self] _ in
            guard let self else { return }
            let wasSuspended = self.flow.isSuspended
            _ = self.flow.complete(bytes.count)
            if wasSuspended && !self.flow.isSuspended { self.shell?.resumeOutput() }
        }
    }

    private func fail(_ code: SessionError.Code, _ message: String) {
        if let data = try? ProtocolPayload.encode(SessionError(code: code, message: message)) {
            framed?.send(ProtocolFrame(kind: .sessionError, payload: data))
        }
        close()
    }
}
