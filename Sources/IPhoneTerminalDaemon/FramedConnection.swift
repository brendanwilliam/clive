import Foundation
import IPhoneTerminalCore
import Network

/// Adapts Network.framework reads to the bounded protocol decoder. Protocol violations close
/// the connection immediately, before a caller can allocate a shell or mutate pairing state.
final class FramedConnection: @unchecked Sendable {
    private let connection: NWConnection
    private var decoder = FrameDecoder()
    private let queue: DispatchQueue
    private let onFrame: @Sendable (ProtocolFrame) -> Void
    private let onClosed: @Sendable () -> Void
    private let onDiagnostic: @Sendable (String) -> Void

    init(connection: NWConnection, queue: DispatchQueue, onFrame: @escaping @Sendable (ProtocolFrame) -> Void, onClosed: @escaping @Sendable () -> Void = {}, onDiagnostic: @escaping @Sendable (String) -> Void = { _ in }) {
        self.connection = connection
        self.queue = queue
        self.onFrame = onFrame
        self.onClosed = onClosed
        self.onDiagnostic = onDiagnostic
    }

    func start(alreadyStarted: Bool = false) {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.onDiagnostic("TLS ready")
                self?.receiveNextChunk()
            case .failed(let error):
                self?.onDiagnostic("TLS failed: \(error.localizedDescription)")
                self?.onClosed()
            case .cancelled: self?.onClosed()
            default: break
            }
        }
        if alreadyStarted { receiveNextChunk() } else { connection.start(queue: queue) }
    }

    func send(_ frame: ProtocolFrame, completion: (@Sendable (Bool) -> Void)? = nil) {
        do {
            let payload = try frame.encoded()
            connection.send(content: payload, completion: .contentProcessed { [weak self] error in
                completion?(error == nil)
                if error != nil { self?.connection.cancel() }
            })
        } catch {
            connection.cancel()
            completion?(false)
        }
    }

    func cancel() { connection.cancel() }

    private func receiveNextChunk() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: ProtocolFrame.defaultMaximumPayloadSize + 7) { [weak self] content, _, complete, error in
            guard let self else { return }
            if let content {
                do {
                    for frame in try decoder.append(content) { onFrame(frame) }
                } catch {
                    connection.cancel()
                    return
                }
            }
            if complete || error != nil {
                connection.cancel()
            } else {
                receiveNextChunk()
            }
        }
    }
}
