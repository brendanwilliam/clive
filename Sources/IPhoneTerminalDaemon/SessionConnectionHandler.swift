import Foundation
import IPhoneTerminalCore
import Network

/// Implements the V1 invariant that one authenticated TLS connection owns one shell.
final class SessionConnectionHandler: @unchecked Sendable {
    private let deviceID: String
    private let registry: SessionRegistry
    private let queue: DispatchQueue
    private var framed: FramedConnection?
    private var shell: PTYProcess?
    private var sessionID: UUID?
    private var flow = OutputBackpressure()
    private var closed = false

    init(deviceID: String, registry: SessionRegistry, queue: DispatchQueue) {
        self.deviceID = deviceID; self.registry = registry; self.queue = queue
    }

    func start(_ connection: NWConnection) {
        let framed = FramedConnection(connection: connection, queue: queue, onFrame: { [weak self] frame in
            self?.handle(frame)
        }, onClosed: { [weak self] in self?.close() })
        self.framed = framed
        framed.start()
    }

    func close() {
        guard !closed else { return }; closed = true
        shell?.terminate(); shell = nil; framed?.cancel(); framed = nil
        if let sessionID { Task { await registry.close(id: sessionID) } }
    }

    private func handle(_ frame: ProtocolFrame) {
        if shell == nil {
            guard frame.kind == .sessionOpen,
                  let request = try? ProtocolPayload.decode(SessionOpenRequest.self, from: frame.payload),
                  request.initialSize.isValid else { return fail(.invalidFrameOrder, "session.open must be the first frame") }
            do {
                shell = try PTYProcess(size: request.initialSize) { [weak self] bytes in
                    guard let owner = self else { return }
                    owner.queue.async { [weak owner] in owner?.sendOutput(bytes) }
                }
                Task {
                    let session = await registry.open(deviceID: deviceID, size: request.initialSize)
                    queue.async { [weak self] in
                        guard let self, !closed else { return }
                        sessionID = session.id
                        if let data = try? ProtocolPayload.encode(SessionOpened(sessionID: session.id)) {
                            framed?.send(ProtocolFrame(kind: .sessionOpened, payload: data))
                        }
                    }
                }
            } catch { fail(.shellCreationFailed, "Unable to create login shell") }
            return
        }
        switch frame.kind {
        case .terminalInput: do { try shell?.write(frame.payload) } catch { close() }
        case .terminalResize:
            guard let size = try? ProtocolPayload.decode(TerminalSize.self, from: frame.payload), size.isValid else {
                return fail(.protocolError, "Invalid terminal size")
            }
            shell?.resize(to: size)
        case .sessionClose: close()
        default: fail(.invalidFrameOrder, "Frame is not valid in an open session")
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
