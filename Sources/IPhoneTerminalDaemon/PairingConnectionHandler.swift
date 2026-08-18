import Foundation
import IPhoneTerminalCore
import Network

/// Handles exactly one pairing request. Session frames and malformed payloads are rejected;
/// a successful exchange is persisted by `PairingCoordinator` before the Mac response is sent.
final class PairingConnectionHandler: @unchecked Sendable {
    private let coordinator: PairingCoordinator
    private var framedConnection: FramedConnection?
    private let onFinished: @Sendable (Bool) -> Void

    init(coordinator: PairingCoordinator, onFinished: @escaping @Sendable (Bool) -> Void = { _ in }) {
        self.coordinator = coordinator
        self.onFinished = onFinished
    }

    func start(connection: NWConnection, queue: DispatchQueue) {
        let framed = FramedConnection(connection: connection, queue: queue, onFrame: { [weak self] frame in
            self?.handle(frame)
        }, onClosed: { [weak self] in
            self?.framedConnection = nil
        })
        framedConnection = framed
        framed.start()
    }

    private func handle(_ frame: ProtocolFrame) {
        guard frame.kind == .pairingRequest,
              let request = try? ProtocolPayload.decode(PairingRequest.self, from: frame.payload) else {
            framedConnection?.cancel()
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                let acceptance = try await coordinator.accept(request)
                let data = try ProtocolPayload.encode(acceptance)
                framedConnection?.send(ProtocolFrame(kind: .pairingAccept, payload: data))
                onFinished(true)
            } catch {
                framedConnection?.cancel()
                onFinished(false)
            }
        }
    }
}
