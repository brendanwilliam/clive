import Foundation
import CliveCore
import Network
import Security

final class PairingOperation: @unchecked Sendable {
    private let lock = NSLock()
    private var listener: SecureListener?
    private var handlers: [PairingConnectionHandler] = []
    private var finished = false
    private let channel: ControlChannel
    private let coordinator: PairingCoordinator
    private let endpoint: String
    private let fingerprint: String
    private let onEnded: @Sendable () -> Void

    init(identity: SecIdentity, identityStore: TLSIdentityStore, state: DaemonState, trustStore: TrustStore, endpoint: String, channel: ControlChannel, rendezvousCapability: RendezvousCapability? = nil, onPaired: @escaping @Sendable () async -> Void, onEnded: @escaping @Sendable () -> Void) throws {
        self.channel = channel
        self.endpoint = endpoint
        self.onEnded = onEnded
        fingerprint = try identityStore.fingerprint(of: identity)
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw ControlSocketError.unavailable }
        let secretBytes = Data(bytes)
        let secretValue = secretBytes.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let placeholder = PairingTicket(endpoint: endpoint, port: 1, expiresAt: .now.addingTimeInterval(300), oneTimeSecret: secretValue, daemonCertificateFingerprint: fingerprint)
        let secret = PairingSecret(ticket: placeholder)
        coordinator = PairingCoordinator(secret: secret, trustStore: trustStore, macID: state.macID, displayName: Host.current().localizedName ?? "Mac", serviceID: state.serviceID, macCertificate: try identityStore.certificateData(of: identity), rendezvousCapability: rendezvousCapability, approval: { request in
            let prompt = PairingPrompt(deviceID: request.deviceID, displayName: request.deviceName, certificateFingerprint: Fingerprint.sha256(of: request.certificate))
            do {
                try channel.send(ControlResponse(kind: .pairingPrompt, success: true, pairingPrompt: prompt))
                let response = try channel.readRequest()
                return response.command == .approvePairing && response.approved == true
            } catch { return false }
        }, didPair: onPaired)
        listener = try SecureListener(identity: identity, onReady: { [weak self] port in
            guard let self else { return }
            let ticket = PairingTicket(endpoint: endpoint, port: port, expiresAt: placeholder.expiresAt, oneTimeSecret: secretValue, daemonCertificateFingerprint: fingerprint, remoteEndpoint: state.remoteEndpoint)
            // Recreate the ticket's externally visible port without changing the secret validation fields.
            try? channel.send(ControlResponse(kind: .pairingTicket, success: true, pairingTicket: ticket))
        }, onConnection: { [weak self] connection, queue, _, _, _ in self?.accept(connection, queue: queue) })
        listener?.start()
        DispatchQueue.global().asyncAfter(deadline: .now() + 300) { [weak self] in self?.finish(success: false, message: "Pairing ticket expired.") }
    }

    func cancel(message: String = "Pairing cancelled.") { finish(success: false, message: message) }

    private func accept(_ connection: NWConnection, queue: DispatchQueue) {
        print("Pairing: connection received.")
        let handler = PairingConnectionHandler(coordinator: coordinator, onFinished: { [weak self] success in self?.pairingFinished(success) }, onDiagnostic: { message in
            print("Pairing: \(message).")
        })
        lock.withLock { handlers.append(handler) }
        handler.start(connection: connection, queue: queue)
    }

    private func pairingFinished(_ success: Bool) {
        finish(success: success, message: success ? "Pairing approved." : "Pairing rejected or failed.")
    }

    private func finish(success: Bool, message: String) {
        let shouldFinish = lock.withLock { () -> Bool in
            guard !finished else { return false }; finished = true; return true
        }
        guard shouldFinish else { return }
        listener?.cancel()
        try? channel.send(ControlResponse(success: success, message: message))
        onEnded()
    }
}
