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

    var devices: [PairedMac] = []
    var state: ConnectionState = .disconnected

    func refresh() {
        do { devices = try PairedMacStore().load() }
        catch { state = .failed("Paired Mac records could not be read.") }
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
