import Foundation
import IPhoneTerminalCore
import Network
import Security

final class DaemonRuntime: @unchecked Sendable {
    private let lock = NSLock()
    private let identity: SecIdentity
    private let identityStore: TLSIdentityStore
    private let state: DaemonState
    private let trustStore: TrustStore
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
        self.onStopped = onStopped
        controlServer = try ControlSocketServer(url: paths.controlSocketURL) { [weak self] request, channel in
            await self?.handle(request, channel: channel)
        }
        sessionListener = try SecureListener(identity: identity, serviceID: state.serviceID, peerTrust: peerTrust, onReady: { port in
            print("iphone-terminald listening on port \(port).")
        }, onConnection: { [weak self] connection, queue, deviceID in
            guard let self, let deviceID else { connection.cancel(); return }
            self.openSession(connection: connection, queue: queue, deviceID: deviceID)
        })
    }

    func start() async {
        await refreshTrust()
        controlServer?.start()
        sessionListener?.start()
    }

    private func handle(_ request: ControlRequest, channel: ControlChannel) async {
        switch request.command {
        case .status:
            let sessions = await registry.all()
            let devices = await trustStore.all().map { device in
                ControlDevice(id: device.id, displayName: device.displayName, certificateFingerprint: device.certificateFingerprint, activeSessionCount: sessions.filter { $0.deviceID == device.id }.count)
            }
            try? channel.send(ControlResponse(success: true, devices: devices))
        case .revoke:
            guard let deviceID = request.deviceID else { try? channel.send(ControlResponse(success: false, message: "A device ID is required.")); return }
            do {
                guard try await trustStore.revoke(id: deviceID) else { try channel.send(ControlResponse(success: false, message: "No paired device with ID \(deviceID).")); return }
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
                let operation = try PairingOperation(identity: identity, identityStore: identityStore, state: state, trustStore: trustStore, endpoint: endpoint, channel: channel, onPaired: { [weak self] in await self?.refreshTrust() }) { [weak self] in
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
        }
    }

    private func refreshTrust() async {
        let mapping = Dictionary(uniqueKeysWithValues: await trustStore.all().map { ($0.certificateFingerprint, $0.id) })
        lock.withLock { trustedDeviceIDs = Set(mapping.values) }
        peerTrust.replace(devices: mapping)
    }

    private func openSession(connection: NWConnection, queue: DispatchQueue, deviceID: String) {
        let handler = SessionConnectionHandler(deviceID: deviceID, registry: registry, queue: queue, onClosed: { [weak self] id in
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
        let base = ProcessInfo.processInfo.environment["IPHONE_TERMINAL_STATE_DIRECTORY"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "iphone-terminal")
        return RuntimePaths(baseURL: base)
    }
}
