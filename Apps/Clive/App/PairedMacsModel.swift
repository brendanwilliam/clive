import Foundation
import CliveCore
import Observation

@MainActor @Observable
final class PairedMacsModel {
    enum State: Equatable { case idle, pairing, failed(String) }
    private(set) var devices: [PairedMac] = []
    private(set) var routes: [String: MacRoute] = [:]
    private(set) var wanRoutes: [String: [MacRoute]] = [:]
    private(set) var rendezvousDiagnostics: [String: String] = [:]
    var state: State = .idle
    private let store = PairedMacStore()
    private let discovery = BonjourDiscovery()
    private var records: [PairedMac] = []
    private let rendezvous = try? IPhoneRendezvousService()
    private(set) var localRendezvousCapability: RendezvousCapability?
    private var cloudObserver: NSObjectProtocol?

    func start() {
        do { records = try store.load() } catch { state = .failed("Paired Mac records could not be read.") }
        discovery.onChange = { [weak self] routes in Task { @MainActor in self?.update(routes) } }
        discovery.start(); update([:])
        cloudObserver = NotificationCenter.default.addObserver(forName: .cloudRendezvousChanged, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in await self?.refreshRendezvous() } }
        Task { await refreshRendezvous() }
    }
    func stop() { discovery.stop(); if let cloudObserver { NotificationCenter.default.removeObserver(cloudObserver); self.cloudObserver = nil } }
    func route(for device: PairedMac) -> MacRoute? { routes[device.serviceID] }
    func cellularRoutes(for device: PairedMac) -> [MacRoute] { wanRoutes[device.id] ?? [] }
    func pair(_ ticket: PairingTicket) async {
        state = .pairing
        do {
            let identity = try IPhoneIdentityProvider().loadOrCreate()
            let capability = try await rendezvous?.prepare()
            localRendezvousCapability = capability
            let record = try await PairingClient().pair(ticket: ticket, identity: identity, rendezvousCapability: capability)
            try store.upsert(record); records = try store.load(); update(routes); state = .idle
            await refreshRendezvous()
        } catch { state = .failed(pairingMessage(error)) }
    }
    func upgrade(macID: String, certificate: Data, capability: RendezvousCapability) {
        guard let current = records.first(where: { $0.id == macID }), Fingerprint.sha256(of: certificate) == current.certificateFingerprint else { return }
        let upgraded = PairedMac(id: current.id, displayName: current.displayName, serviceID: current.serviceID, certificateFingerprint: current.certificateFingerprint, createdAt: current.createdAt, remoteEndpoint: current.remoteEndpoint, certificate: certificate, rendezvousCapability: capability)
        try? store.upsert(upgraded); records = (try? store.load()) ?? records; update(routes)
        Task { await refreshRendezvous() }
    }
    func forget(_ mac: PairedMac) throws {
        try store.remove(id: mac.id)
        records = try store.load()
        routes = routes.filter { $0.key != mac.serviceID }
        wanRoutes.removeValue(forKey: mac.id)
        rendezvousDiagnostics.removeValue(forKey: mac.id)
        update(routes)
    }
    func refreshRendezvous() async {
        guard let rendezvous, let identity = try? IPhoneIdentityProvider().loadOrCreate() else { return }
        localRendezvousCapability = try? await rendezvous.prepare()
        var newRoutes: [String: [MacRoute]] = [:]; var diagnostics: [String: String] = [:]
        for mac in records {
            let result = await rendezvous.routes(for: mac, deviceID: identity.deviceID)
            newRoutes[mac.id] = result.routes; diagnostics[mac.id] = result.diagnostic
        }
        wanRoutes = newRoutes; rendezvousDiagnostics = diagnostics
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
