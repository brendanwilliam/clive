import Foundation
import IPhoneTerminalCore
import Observation

struct WorkspaceSnapshot: Codable {
    var selectedMacID: String?
    var sessionsByMac: [String: [SessionDescriptor]]
}

struct SessionDescriptor: Codable, Identifiable, Equatable {
    let id: UUID
    var label: String
    init(id: UUID = UUID(), label: String) { self.id = id; self.label = label }
}

@MainActor @Observable final class WorkspaceSession: Identifiable {
    let descriptor: SessionDescriptor
    nonisolated let id: UUID
    let client = SessionClient()
    var state: SessionClient.State = .connecting
    var preview: String?
    var lastActivityAt: Date?
    private var accumulator = TerminalPreviewAccumulator()

    private let routes: [MacRoute]
    private let device: PairedMac
    private let identity: IPhoneIdentity
    private var routeIndex = 0

    init(descriptor: SessionDescriptor, device: PairedMac, routes: [MacRoute], identity: IPhoneIdentity) {
        self.descriptor = descriptor
        self.id = descriptor.id
        self.routes = routes
        self.device = device
        self.identity = identity
        client.onState = { [weak self] value in DispatchQueue.main.async { self?.handleState(value) } }
        client.onActivityOutput = { [weak self] bytes in DispatchQueue.main.async {
            guard let self else { return }; self.accumulator.consume(bytes); self.preview = self.accumulator.preview; self.lastActivityAt = .now
        } }
        connectCurrentRoute()
    }

    func noteInput() { lastActivityAt = .now }
    func clearTransientActivity() { accumulator.clear(); preview = nil; lastActivityAt = nil }
    func close() { clearTransientActivity(); client.close() }

    private func handleState(_ value: SessionClient.State) {
        state = value
        guard case .networkError = value, routeIndex + 1 < routes.count else { return }
        // Bonjour/LAN is always first. A failed attempt may fall back once to the
        // pinned private-overlay endpoint; certificate validation is unchanged.
        routeIndex += 1
        clearTransientActivity()
        state = .connecting
        connectCurrentRoute()
    }

    private func connectCurrentRoute() {
        let route = routes[routeIndex]
        client.connect(host: route.host, port: route.port, pinnedFingerprint: device.certificateFingerprint, identity: identity.identity, clientSessionID: descriptor.id, size: TerminalSize(columns: 80, rows: 24))
    }
}

@MainActor @Observable final class WorkspaceCoordinator {
    enum State: Equatable { case locked, authenticating, active, authenticationCancelled, failed(String) }
    let macs = PairedMacsModel()
    var state: State = .locked
    var selectedMacID: String?
    var sessions: [WorkspaceSession] = []
    var selectedSessionID: UUID?
    private var snapshot = WorkspaceSnapshot(selectedMacID: nil, sessionsByMac: [:])
    private var identity: IPhoneIdentity?

    func start() { macs.start(); snapshot = (try? WorkspaceStore().load()) ?? snapshot; selectedMacID = snapshot.selectedMacID }
    func stop() { closeLiveSessions(); macs.stop() }
    var selectedMac: PairedMac? { macs.devices.first { $0.id == selectedMacID } }

    func authorize() async {
        state = .authenticating
        do {
            try await LocalAuthenticator.authorizeConnection(); identity = try IPhoneIdentityProvider().loadOrCreate(); state = .active
            if selectedMac == nil { selectedMacID = macs.devices.first?.id }
            restoreSelectedMac()
        } catch { state = .authenticationCancelled }
    }

    func selectMac(_ mac: PairedMac) {
        guard mac.id != selectedMacID else { return }
        saveCurrentDescriptors(); closeLiveSessions(); selectedMacID = mac.id; snapshot.selectedMacID = mac.id; persist(); restoreSelectedMac()
    }

    func addShell() {
        guard let mac = selectedMac, let identity else { return }
        let routes = routes(for: mac); guard !routes.isEmpty else { return }
        let descriptor = SessionDescriptor(label: "Shell \(sessions.count + 1)")
        let session = WorkspaceSession(descriptor: descriptor, device: mac, routes: routes, identity: identity)
        sessions.append(session); selectedSessionID = session.id; saveCurrentDescriptors(); persist()
    }

    func close(_ session: WorkspaceSession) {
        session.close(); sessions.removeAll { $0.id == session.id }; if selectedSessionID == session.id { selectedSessionID = sessions.last?.id }
        saveCurrentDescriptors(); persist()
    }

    func sceneDidBackground() { saveCurrentDescriptors(); persist(); closeLiveSessions(); state = .locked }

    private func restoreSelectedMac() {
        guard state == .active, let mac = selectedMac, let identity else { return }
        let routes = routes(for: mac); guard !routes.isEmpty else { return }
        let descriptors = snapshot.sessionsByMac[mac.id] ?? [SessionDescriptor(label: "Shell 1")]
        sessions = descriptors.map { WorkspaceSession(descriptor: $0, device: mac, routes: routes, identity: identity) }
        selectedSessionID = sessions.first?.id
        saveCurrentDescriptors(); persist()
    }

    private func routes(for mac: PairedMac) -> [MacRoute] {
        var values: [MacRoute] = []
        if let lan = macs.route(for: mac) { values.append(lan) }
        if let remote = mac.remoteEndpoint {
            let remoteRoute = MacRoute(host: remote.host, port: remote.port)
            if !values.contains(remoteRoute) { values.append(remoteRoute) }
        }
        return values
    }
    private func closeLiveSessions() { sessions.forEach { $0.close() }; sessions.removeAll(); selectedSessionID = nil }
    private func saveCurrentDescriptors() { guard let id = selectedMacID else { return }; snapshot.sessionsByMac[id] = sessions.map(\.descriptor); snapshot.selectedMacID = id }
    private func persist() { try? WorkspaceStore().save(snapshot) }
}

private struct WorkspaceStore {
    private var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "iPhoneTerminal/workspace.json")
    }
    func load() throws -> WorkspaceSnapshot { try JSONDecoder().decode(WorkspaceSnapshot.self, from: Data(contentsOf: url)) }
    func save(_ snapshot: WorkspaceSnapshot) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
    }
}
