import Foundation
import CliveCore
import Network
import Security

final class DaemonRuntime: @unchecked Sendable {
    private let lock = NSLock()
    private let identity: SecIdentity
    private let identityStore: TLSIdentityStore
    private let state: DaemonState
    private let trustStore: TrustStore
    private let rendezvous: MacRendezvousController
    private let registry = SessionRegistry()
    private let peerTrust = PeerTrustCache()
    private var sessionListener: SecureListener?
    private var controlServer: ControlSocketServer?
    private var pairing: PairingOperation?
    private var handlers: [UUID: (deviceID: String, handler: SessionConnectionHandler)] = [:]
    private var handlersByWorkspaceSession: [String: UUID] = [:]
    private var trustedDeviceIDs: Set<String> = []
    private var stopped = false
    private let onStopped: @Sendable () -> Void

    init(paths: RuntimePaths, onStopped: @escaping @Sendable () -> Void) throws {
        identityStore = TLSIdentityStore(baseURL: paths.baseURL)
        identity = try identityStore.loadOrCreate()
        state = try DaemonState.loadOrCreate(url: paths.stateURL)
        trustStore = try TrustStore(url: paths.pairingStoreURL)
        rendezvous = try MacRendezvousController(state: state, trustStore: trustStore, baseURL: paths.baseURL)
        self.onStopped = onStopped
        controlServer = try ControlSocketServer(url: paths.controlSocketURL) { [weak self] request, channel in
            await self?.handle(request, channel: channel)
        }
        sessionListener = try SecureListener(identity: identity, port: state.remoteEndpoint?.port, serviceID: state.serviceID, peerTrust: peerTrust, onReady: { [remoteEndpoint = state.remoteEndpoint, rendezvous] port in
            if let remoteEndpoint {
                print("clive listening on private VPN port \(port) for \(remoteEndpoint.host).")
            } else {
                print("clive listening on port \(port).")
            }
            Task { await rendezvous.prepare(listenerPort: port) }
        }, onConnection: { [weak self] connection, queue, deviceID, certificate, requiresWANGate in
            guard let self, let deviceID else { connection.cancel(); return }
            Task {
                let capability = await self.rendezvous.capability()
                self.openSession(connection: connection, queue: queue, deviceID: deviceID, certificate: certificate, requiresWANGate: requiresWANGate, localCapability: capability)
            }
        })
    }

    func start() async {
        await refreshTrust()
        controlServer?.start()
        sessionListener?.start()
    }

    func cloudDidChange() { Task { await rendezvous.cloudDidChange() } }

    private func handle(_ request: ControlRequest, channel: ControlChannel) async {
        switch request.command {
        case .status:
            let sessions = await registry.all()
            let devices = await trustStore.all().map { device in
                ControlDevice(id: device.id, displayName: device.displayName, certificateFingerprint: device.certificateFingerprint, activeSessionCount: sessions.filter { $0.deviceID == device.id }.count)
            }
            try? channel.send(ControlResponse(success: true, devices: devices, cellularStatus: await rendezvous.status()))
        case .revoke:
            guard let deviceID = request.deviceID else { try? channel.send(ControlResponse(success: false, message: "A device ID is required.")); return }
            do {
                guard try await trustStore.revoke(id: deviceID) else { try channel.send(ControlResponse(success: false, message: "No paired device with ID \(deviceID).")); return }
                await rendezvous.revoke(deviceID: deviceID)
                await refreshTrust()
                let owned = lock.withLock { handlers.values.filter { $0.deviceID == deviceID }.map(\.handler) }
                owned.forEach { $0.revoke() }
                _ = await registry.closeAll(forDeviceID: deviceID)
                try channel.send(ControlResponse(success: true, message: "Revoked \(deviceID)."))
            } catch { try? channel.send(ControlResponse(success: false, message: error.localizedDescription)) }
        case .pair:
            guard lock.withLock({ pairing == nil }) else { try? channel.send(ControlResponse(success: false, message: "Another pairing operation is active.")); return }
            guard let endpoint = PrivateNetwork.eligibleAddresses().first else { try? channel.send(ControlResponse(success: false, message: "No eligible private network interface.")); return }
            do {
                let operation = try PairingOperation(identity: identity, identityStore: identityStore, state: state, trustStore: trustStore, endpoint: endpoint, channel: channel, rendezvousCapability: await rendezvous.capability(), onPaired: { [weak self] in await self?.refreshTrust(); await self?.rendezvous.pairingChanged() }) { [weak self] in
                    self?.lock.withLock { self?.pairing = nil }
                    Task { await self?.refreshTrust() }
                }
                lock.withLock { pairing = operation }
            } catch { try? channel.send(ControlResponse(success: false, message: error.localizedDescription)) }
        case .stop:
            try? channel.send(ControlResponse(success: true, message: "Stopping daemon."))
            stop()
        case .approvePairing:
            try? channel.send(ControlResponse(success: false, message: "Approval is only valid on an active pairing channel."))
        case .cancelPairing:
            let active = lock.withLock { pairing }
            guard let active else { try? channel.send(ControlResponse(success: false, message: "No pairing operation is active.")); return }
            active.cancel()
            try? channel.send(ControlResponse(success: true, message: "Pairing cancelled."))
        case .setCellularAccess:
            guard let enabled = request.cellularEnabled else { try? channel.send(ControlResponse(success: false, message: "An enabled value is required.")); return }
            do {
                try await rendezvous.setEnabled(enabled, manualEndpoint: request.manualEndpoint)
                try channel.send(ControlResponse(success: true, cellularStatus: await rendezvous.status()))
            } catch { try? channel.send(ControlResponse(success: false, message: error.localizedDescription, cellularStatus: await rendezvous.status())) }
        }
    }

    private func refreshTrust() async {
        let mapping = Dictionary(uniqueKeysWithValues: await trustStore.all().map { ($0.certificateFingerprint, $0.id) })
        lock.withLock { trustedDeviceIDs = Set(mapping.values) }
        peerTrust.replace(devices: mapping)
    }

    private func openSession(connection: NWConnection, queue: DispatchQueue, deviceID: String, certificate: Data?, requiresWANGate: Bool, localCapability: RendezvousCapability?) {
        let handler = SessionConnectionHandler(deviceID: deviceID, peerCertificate: certificate, requiresWANGate: requiresWANGate, localCapability: localCapability, registry: registry, queue: queue, validateGate: { [weak rendezvous] deviceID, token in
            await rendezvous?.validateGate(deviceID: deviceID, token: token) == true
        }, upgradePeer: { [weak trustStore, weak rendezvous] deviceID, certificate, capability in
            guard let trustStore, (try? await trustStore.upgrade(id: deviceID, certificate: certificate, rendezvousCapability: capability)) == true else { return }
            await rendezvous?.pairingChanged()
        }, revokePeer: { [weak self] deviceID, requestingHandlerID in
            await self?.revokeFromPhone(deviceID: deviceID, requestingHandlerID: requestingHandlerID) == true
        }, onClosed: { [weak self] id in
            _ = self?.lock.withLock {
                self?.handlers.removeValue(forKey: id)
                self?.handlersByWorkspaceSession = self?.handlersByWorkspaceSession.filter { $0.value != id } ?? [:]
            }
        }, replaceExisting: { [weak self] deviceID, clientSessionID, replacement in
            guard let self else { return }
            let key = "\(deviceID):\(clientSessionID.uuidString.lowercased())"
            let previous = self.lock.withLock { () -> SessionConnectionHandler? in
                let oldID = self.handlersByWorkspaceSession[key]
                self.handlersByWorkspaceSession[key] = replacement.identifier
                return oldID.flatMap { self.handlers[$0]?.handler }
            }
            // close sends SIGHUP to the process group and reaps it; replacement never leaves
            // two handlers registered for the same phone/workspace session key.
            if previous?.identifier != replacement.identifier { previous?.close() }
        })
        let accepted = lock.withLock { () -> Bool in
            guard trustedDeviceIDs.contains(deviceID), !stopped else { return false }
            handlers[handler.identifier] = (deviceID, handler); return true
        }
        guard accepted else { connection.cancel(); return }
        handler.start(connection)
    }

    private func revokeFromPhone(deviceID: String, requestingHandlerID: UUID) async -> Bool {
        do {
            guard try await trustStore.revoke(id: deviceID) else { return false }
            await rendezvous.revoke(deviceID: deviceID)
            await refreshTrust()
            let owned = lock.withLock {
                handlers.filter { $0.key != requestingHandlerID && $0.value.deviceID == deviceID }.map { $0.value.handler }
            }
            owned.forEach { $0.revoke() }
            _ = await registry.closeAll(forDeviceID: deviceID)
            return true
        } catch {
            return false
        }
    }

    func stop() {
        let shouldStop = lock.withLock { () -> Bool in guard !stopped else { return false }; stopped = true; return true }
        guard shouldStop else { return }
        pairing?.cancel(message: "Daemon stopped.")
        sessionListener?.cancel(); controlServer?.stop()
        let active = lock.withLock { handlers.values.map(\.handler) }
        active.forEach { $0.close() }
        onStopped()
    }
}

struct RuntimePaths: Sendable {
    let baseURL: URL
    var pairingStoreURL: URL { baseURL.appending(path: "Pairings/devices.json") }
    var stateURL: URL { baseURL.appending(path: "daemon.json") }
    var controlSocketURL: URL { baseURL.appending(path: "control.sock") }

    static var live: RuntimePaths {
        let base = ProcessInfo.processInfo.environment["CLIVE_STATE_DIRECTORY"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "clive")
        return RuntimePaths(baseURL: base)
    }
}
