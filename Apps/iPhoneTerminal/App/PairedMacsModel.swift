import Foundation
import IPhoneTerminalCore
import Observation

@MainActor @Observable
final class PairedMacsModel {
    enum State: Equatable { case idle, pairing, failed(String) }
    private(set) var devices: [PairedMac] = []
    private(set) var routes: [String: MacRoute] = [:]
    var state: State = .idle
    private let store = PairedMacStore()
    private let discovery = BonjourDiscovery()
    private var records: [PairedMac] = []

    func start() {
        do { records = try store.load() } catch { state = .failed("Paired Mac records could not be read.") }
        discovery.onChange = { [weak self] routes in Task { @MainActor in self?.update(routes) } }
        discovery.start(); update([:])
    }
    func stop() { discovery.stop() }
    func route(for device: PairedMac) -> MacRoute? { routes[device.serviceID] }
    func pair(_ ticket: PairingTicket) async {
        state = .pairing
        do {
            let identity = try IPhoneIdentityProvider().loadOrCreate()
            let record = try await PairingClient().pair(ticket: ticket, identity: identity)
            try store.upsert(record); records = try store.load(); update(routes); state = .idle
        } catch { state = .failed(pairingMessage(error)) }
    }
    private func update(_ routes: [String: MacRoute]) {
        self.routes = routes
        devices = records.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }
    private func pairingMessage(_ error: Error) -> String {
        switch error {
        case PairingTicketValidationError.expired: "The pairing code expired."
        case PairingClient.Error.certificateChanged: "The Mac certificate did not match the QR code."
        default: "Pairing failed: \(error.localizedDescription)"
        }
    }
}
