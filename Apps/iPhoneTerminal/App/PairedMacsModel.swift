import Foundation
import IPhoneTerminalCore
import Observation

@Observable
final class PairedMacsModel {
    enum ConnectionState: Equatable {
        case disconnected
        case connecting
        case connected
        case failed(String)
    }

    var devices: [PairedDevice] = []
    var state: ConnectionState = .disconnected

    func refresh() {
        // The iOS Keychain-backed store and Bonjour resolver are added with the transport layer.
    }

    func unlockBeforeConnecting() async {
        do {
            state = .connecting
            try await LocalAuthenticator.authorizeConnection()
            state = .disconnected
        } catch {
            state = .failed("Authentication was cancelled or unavailable.")
        }
    }
}
