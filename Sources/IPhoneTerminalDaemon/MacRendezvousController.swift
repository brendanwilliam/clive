import Foundation
import IPhoneTerminalCloud
import IPhoneTerminalCore
import IPhoneTerminalSecurity
import Security

actor MacRendezvousController {
    private struct Settings: Codable { var enabled = false; var manualEndpoint: RemoteEndpoint? }

    private let state: DaemonState
    private let trustStore: TrustStore
    private let settingsURL: URL
    private let cloud: CloudRendezvousStore?
    private let keys: RendezvousKeyPair
    private var settings: Settings
    private var accountBinding: String?
    private var listenerPort: UInt16?
    private var gates = WANGateRegistry()
    private var hintSequences: [String: UInt64] = [:]
    private var currentStatus = CellularAccessStatus(enabled: false, state: .disabled)

    init(state: DaemonState, trustStore: TrustStore, baseURL: URL) throws {
        self.state = state; self.trustStore = trustStore
        settingsURL = baseURL.appending(path: "cellular.json")
        if let data = try? Data(contentsOf: settingsURL) { settings = (try? JSONDecoder().decode(Settings.self, from: data)) ?? Settings() }
        else { settings = Settings() }
        let bundledContainer = Bundle.main.object(forInfoDictionaryKey: "IPhoneTerminalCloudContainer") as? String
        let container = ProcessInfo.processInfo.environment["IPHONE_TERMINAL_ICLOUD_CONTAINER"]
            ?? bundledContainer
            ?? "iCloud.com.iphoneterminal"
        cloud = Self.hasCloudKitEntitlement ? CloudRendezvousStore(containerIdentifier: container) : nil
        keys = try RendezvousKeyStore(service: "com.iphoneterminal.mac.rendezvous").loadOrCreate()
        currentStatus = CellularAccessStatus(enabled: settings.enabled, state: settings.enabled ? .preparing : .disabled)
    }

    func prepare(listenerPort: UInt16) async {
        self.listenerPort = listenerPort
        guard let cloud else {
            currentStatus = CellularAccessStatus(
                enabled: settings.enabled,
                state: settings.enabled ? .blocked : .disabled,
                diagnostic: settings.enabled ? CloudRendezvousError.entitlementUnavailable.localizedDescription : nil
            )
            return
        }
        do {
            accountBinding = try await cloud.prepare()
            if settings.enabled { await publishAll() }
        } catch {
            currentStatus = CellularAccessStatus(enabled: settings.enabled, state: settings.enabled ? .blocked : .disabled, diagnostic: error.localizedDescription)
        }
    }

    func capability() -> RendezvousCapability? {
        guard let accountBinding, let publicKeys = try? keys.publicKeys else { return nil }
        return RendezvousCapability(keys: publicKeys, accountBinding: accountBinding)
    }

    func status() -> CellularAccessStatus { currentStatus }

    func setEnabled(_ enabled: Bool, manualEndpoint: RemoteEndpoint?) async throws {
        if enabled && cloud == nil { throw CloudRendezvousError.entitlementUnavailable }
        if !enabled { gates.invalidateAll() }
        settings.enabled = enabled
        if let manualEndpoint { settings.manualEndpoint = manualEndpoint }
        try persistSettings()
        if enabled { gates.invalidateAll() }
        if enabled {
            guard let cloud else { return }
            currentStatus = CellularAccessStatus(enabled: true, state: .preparing)
            if accountBinding == nil { accountBinding = try await cloud.prepare() }
            await publishAll()
        } else {
            currentStatus = CellularAccessStatus(enabled: false, state: .disabled)
            await deleteAllRecords()
        }
    }

    func pairingChanged() async { if settings.enabled { await publishAll() } }

    func revoke(deviceID: String) async {
        gates.revoke(deviceID: deviceID)
        guard let cloud else { return }
        let name = RendezvousCrypto.recordName(macID: state.macID, deviceID: deviceID, purpose: "endpoint")
        try? await cloud.delete(recordName: name)
    }

    func cloudDidChange() async {
        guard settings.enabled, let cloud else { return }
        var receivedValidHint = false
        for device in await trustStore.all() {
            guard let peer = device.rendezvousCapability else { continue }
            let name = RendezvousCrypto.recordName(macID: state.macID, deviceID: device.id, purpose: "hint")
            guard let envelope = try? await cloud.fetch(recordName: name) else { continue }
            if (try? RendezvousCrypto.open(envelope, as: RendezvousReachabilityHint.self, recipientID: state.macID, recipientAgreementKey: keys.agreementPrivateKey, senderSigningKey: peer.keys.signing, minimumSequence: hintSequences[device.id])) != nil {
                hintSequences[device.id] = envelope.sequence; receivedValidHint = true
            }
            try? await cloud.delete(recordName: name)
        }
        if receivedValidHint { await publishAll() }
    }

    func validateGate(deviceID: String, token: Data?) -> Bool {
        settings.enabled && gates.validate(deviceID: deviceID, token: token)
    }

    func disableImmediatelyForAccountChange() {
        gates.invalidateAll(); accountBinding = nil
        currentStatus = CellularAccessStatus(enabled: settings.enabled, state: settings.enabled ? .blocked : .disabled, diagnostic: "The iCloud account changed. Connect locally to verify the same Apple Account.")
    }

    private func publishAll() async {
        guard settings.enabled, let cloud, let listenerPort, let accountBinding else { return }
        var endpoints = PublicNetwork.publicIPv6Addresses().map { RendezvousEndpoint(host: $0, port: listenerPort, kind: .publicIPv6) }
        if let manual = settings.manualEndpoint ?? state.remoteEndpoint {
            endpoints.append(.init(host: manual.host, port: manual.port, kind: .manualPublicEndpoint))
        }
        guard !endpoints.isEmpty else {
            gates.invalidateAll()
            currentStatus = CellularAccessStatus(enabled: true, state: .configurationRequired, diagnostic: "No public IPv6 address is available. Configure a private-beta public hostname and forwarded port.")
            return
        }
        let devices = await trustStore.all()
        let expiry = Date.now.addingTimeInterval(300)
        var published = 0
        for device in devices {
            guard let capability = device.rendezvousCapability, capability.accountBinding == accountBinding else { continue }
            do {
                let token = randomToken(); let generation = UUID()
                let advertisement = RendezvousAdvertisement(generation: generation, gateToken: token, endpoints: endpoints)
                let sequence = UInt64(Date.now.timeIntervalSince1970 * 1_000)
                let envelope = try RendezvousCrypto.seal(advertisement, senderID: state.macID, recipientID: device.id, sequence: sequence, expiresAt: expiry, recipientAgreementKey: capability.keys.agreement, senderSigningKey: keys.signingPrivateKey)
                let name = RendezvousCrypto.recordName(macID: state.macID, deviceID: device.id, purpose: "endpoint")
                try await cloud.save(envelope, recordName: name, recordType: "RendezvousV1")
                gates.issue(deviceID: device.id, token: token, expiresAt: expiry); published += 1
            } catch { /* Other paired devices remain independently usable. */ }
        }
        if published > 0 {
            currentStatus = CellularAccessStatus(enabled: true, state: .available, publishedUntil: expiry)
        } else if state.remoteEndpoint != nil {
            currentStatus = CellularAccessStatus(enabled: true, state: .available)
        } else {
            currentStatus = CellularAccessStatus(enabled: true, state: .configurationRequired, diagnostic: "A paired iPhone must connect locally once to verify its iCloud account and upgrade rendezvous keys.")
        }
    }

    private func deleteAllRecords() async {
        guard let cloud else { return }
        for device in await trustStore.all() {
            let name = RendezvousCrypto.recordName(macID: state.macID, deviceID: device.id, purpose: "endpoint")
            try? await cloud.delete(recordName: name)
        }
    }

    private func persistSettings() throws {
        try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(settings).write(to: settingsURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: settingsURL.path)
    }

    private func randomToken() -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return Data(UUID().uuidString.utf8) }
        return Data(bytes)
    }

    private static var hasCloudKitEntitlement: Bool {
        guard let task = SecTaskCreateFromSelf(nil),
              let services = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-services" as CFString, nil) as? [String]
        else { return false }
        return services.contains("CloudKit") || services.contains("CloudKit-Anonymous")
    }
}
