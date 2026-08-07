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

    init(connection: NWConnection, queue: DispatchQueue, onFrame: @escaping @Sendable (ProtocolFrame) -> Void, onClosed: @escaping @Sendable () -> Void = {}) {
        self.connection = connection
        self.queue = queue
        self.onFrame = onFrame
        self.onClosed = onClosed
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.receiveNextChunk()
            case .failed, .cancelled: self?.onClosed()
            default: break
            }
        }
        connection.start(queue: queue)
    }

    func send(_ frame: ProtocolFrame) {
        do {
            let payload = try frame.encoded()
            connection.send(content: payload, completion: .contentProcessed { [weak self] error in
                if error != nil { self?.connection.cancel() }
            })
        } catch {
            connection.cancel()
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
