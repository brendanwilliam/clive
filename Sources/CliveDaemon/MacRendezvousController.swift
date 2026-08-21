import Foundation
import CliveCloud
import CliveCore
import CliveSecurity
import Security

actor MacRendezvousController {
    private struct Settings: Codable {
        var enabled = false
        var manualEndpoint: RemoteEndpoint?
        var endpointMode = CellularEndpointMode.automatic
        var allowsRouterMapping = false

        enum CodingKeys: String, CodingKey { case enabled, manualEndpoint, endpointMode, allowsRouterMapping }
        init() {}
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
            manualEndpoint = try values.decodeIfPresent(RemoteEndpoint.self, forKey: .manualEndpoint)
            endpointMode = try values.decodeIfPresent(CellularEndpointMode.self, forKey: .endpointMode) ?? (manualEndpoint == nil ? .automatic : .manual)
            allowsRouterMapping = try values.decodeIfPresent(Bool.self, forKey: .allowsRouterMapping) ?? false
        }
    }

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
    private var verificationChallenge: UUID?
    private var verifiedAt: Date?
    private var activeEndpoint: RemoteEndpoint?
    private let routerMapper = RouterPortMapper()
    private var routerMapping: RouterMapping?
    private var mappingRenewal: Task<Void, Never>?

    init(state: DaemonState, trustStore: TrustStore, baseURL: URL) throws {
        self.state = state; self.trustStore = trustStore
        settingsURL = baseURL.appending(path: "cellular.json")
        if let data = try? Data(contentsOf: settingsURL) { settings = (try? JSONDecoder().decode(Settings.self, from: data)) ?? Settings() }
        else { settings = Settings() }
        let bundledContainer = Bundle.main.object(forInfoDictionaryKey: "CliveCloudContainer") as? String
        let container = ProcessInfo.processInfo.environment["CLIVE_ICLOUD_CONTAINER"]
            ?? bundledContainer
            ?? "iCloud.com.clive"
        cloud = Self.hasCloudKitEntitlement ? CloudRendezvousStore(containerIdentifier: container) : nil
        keys = try RendezvousKeyStore(service: "com.clive.mac.rendezvous").loadOrCreate()
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

    func configuration() -> CellularConfiguration {
        CellularConfiguration(listenerPort: listenerPort ?? state.effectiveListenerPort, endpointMode: settings.endpointMode, manualEndpoint: settings.manualEndpoint, allowsRouterMapping: settings.allowsRouterMapping)
    }

    func configure(_ configuration: CellularConfiguration) throws {
        guard configuration.listenerPort > 0 else { throw CellularSetupError.invalidPort }
        if configuration.endpointMode == .manual { try Self.validate(configuration.manualEndpoint) }
        settings.endpointMode = configuration.endpointMode
        settings.manualEndpoint = configuration.manualEndpoint
        settings.allowsRouterMapping = configuration.allowsRouterMapping
        removeRouterMapping()
        verifiedAt = nil
        try persistSettings()
    }

    func beginVerification() async throws {
        guard settings.enabled else { throw CellularSetupError.notEnabled }
        verificationChallenge = UUID(); verifiedAt = nil
        currentStatus = makeStatus(state: .verifying, diagnostic: "Open Clive on the paired iPhone using cellular data to verify this connection.")
        await publishAll()
    }

    func validateVerification(deviceID: String, challenge: UUID, token: Data?) -> Bool {
        guard challenge == verificationChallenge, gates.validate(deviceID: deviceID, token: token) else { return false }
        verificationChallenge = nil; verifiedAt = .now
        currentStatus = makeStatus(state: .available, diagnostic: nil)
        Task { await publishAll() }
        return true
    }

    func setEnabled(_ enabled: Bool, manualEndpoint: RemoteEndpoint?) async throws {
        if enabled && cloud == nil { throw CloudRendezvousError.entitlementUnavailable }
        if !enabled { gates.invalidateAll(); removeRouterMapping() }
        settings.enabled = enabled
        if let manualEndpoint { settings.manualEndpoint = manualEndpoint }
        try persistSettings()
        if enabled { gates.invalidateAll() }
        if enabled {
            guard let cloud else { return }
            currentStatus = makeStatus(state: .preparing)
            if accountBinding == nil { accountBinding = try await cloud.prepare() }
            await publishAll()
        } else {
            verificationChallenge = nil; verifiedAt = nil; activeEndpoint = nil
            currentStatus = makeStatus(state: .disabled)
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
            let resultName = RendezvousCrypto.recordName(macID: state.macID, deviceID: device.id, purpose: "verification-result")
            if let envelope = try? await cloud.fetch(recordName: resultName),
               let result = try? RendezvousCrypto.open(envelope, as: RendezvousReachabilityResult.self, recipientID: state.macID, recipientAgreementKey: keys.agreementPrivateKey, senderSigningKey: peer.keys.signing),
               result.challenge == verificationChallenge, !result.succeeded {
                currentStatus = makeStatus(state: .configurationRequired, diagnostic: result.diagnostic ?? "The iPhone could not reach this Mac over cellular.")
            }
            try? await cloud.delete(recordName: resultName)
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

    func shutdown() { removeRouterMapping() }

    private func publishAll() async {
        guard settings.enabled, let cloud, let listenerPort, let accountBinding else { return }
        var endpoints = PublicNetwork.publicIPv6Addresses().map { RendezvousEndpoint(host: $0, port: listenerPort, kind: .publicIPv6) }
        var mappingFailure: String?
        if endpoints.isEmpty, settings.endpointMode == .automatic, settings.allowsRouterMapping {
            do {
                let mapping = try routerMapping ?? routerMapper.open(internalPort: listenerPort)
                routerMapping = mapping; scheduleRenewal(mapping)
                endpoints.append(.init(host: mapping.host, port: mapping.externalPort, kind: .manualPublicEndpoint))
            } catch { mappingFailure = error.localizedDescription }
        }
        if settings.endpointMode == .manual, let manual = settings.manualEndpoint {
            endpoints.append(.init(host: manual.host, port: manual.port, kind: .manualPublicEndpoint))
        } else if let remote = state.remoteEndpoint {
            endpoints.append(.init(host: remote.host, port: remote.port, kind: .manualPublicEndpoint))
        }
        guard !endpoints.isEmpty else {
            activeEndpoint = nil
            gates.invalidateAll()
            let local = PrivateNetwork.eligibleAddresses().first ?? "this Mac's LAN address"
            let fallback = "Forward TCP port \(listenerPort) to \(local):\(listenerPort), then enter the public hostname or address."
            currentStatus = makeStatus(state: .configurationRequired, diagnostic: [mappingFailure, fallback].compactMap { $0 }.joined(separator: " "))
            return
        }
        if let first = endpoints.first { activeEndpoint = RemoteEndpoint(host: first.host, port: first.port) }
        let devices = await trustStore.all()
        let expiry = Date.now.addingTimeInterval(300)
        var published = 0
        var eligible = 0
        var publicationFailure: String?
        for device in devices {
            guard let capability = device.rendezvousCapability, capability.accountBinding == accountBinding else { continue }
            eligible += 1
            do {
                let token = randomToken(); let generation = UUID()
                let advertisement = RendezvousAdvertisement(generation: generation, gateToken: token, endpoints: endpoints, verificationChallenge: verificationChallenge)
                let sequence = UInt64(Date.now.timeIntervalSince1970 * 1_000)
                let envelope = try RendezvousCrypto.seal(advertisement, senderID: state.macID, recipientID: device.id, sequence: sequence, expiresAt: expiry, recipientAgreementKey: capability.keys.agreement, senderSigningKey: keys.signingPrivateKey)
                let name = RendezvousCrypto.recordName(macID: state.macID, deviceID: device.id, purpose: "endpoint")
                try await cloud.save(envelope, recordName: name, recordType: "RendezvousV1")
                gates.issue(deviceID: device.id, token: token, expiresAt: expiry); published += 1
            } catch { publicationFailure = error.localizedDescription }
        }
        if published > 0 {
            let state: CellularAccessState = verifiedAt == nil ? .configurationRequired : .available
            currentStatus = makeStatus(state: state, diagnostic: verifiedAt == nil ? "Cellular route configured. Verify it from the paired iPhone." : nil, publishedUntil: expiry)
        } else {
            let diagnostic = eligible > 0
                ? "Clive could not publish the cellular route to iCloud. \(publicationFailure ?? "Try again shortly.")"
                : "A paired iPhone must connect locally once to verify its iCloud account and upgrade rendezvous keys."
            currentStatus = makeStatus(state: .configurationRequired, diagnostic: diagnostic)
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

    private func scheduleRenewal(_ mapping: RouterMapping) {
        mappingRenewal?.cancel()
        guard mapping.lifetime > 0 else { return }
        mappingRenewal = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(60, mapping.lifetime / 2)))
            guard !Task.isCancelled, let self else { return }
            await self.renewRouterMapping(mapping)
        }
    }

    private func renewRouterMapping(_ previous: RouterMapping) async {
        guard settings.enabled, settings.allowsRouterMapping else { return }
        do {
            let renewed = try routerMapper.open(internalPort: previous.internalPort, suggestedExternalPort: previous.externalPort)
            routerMapping = renewed; scheduleRenewal(renewed); await publishAll()
        } catch {
            routerMapping = nil
            currentStatus = makeStatus(state: .configurationRequired, diagnostic: "The automatic router mapping expired. \(error.localizedDescription)")
        }
    }

    private func removeRouterMapping() {
        mappingRenewal?.cancel(); mappingRenewal = nil
        if let routerMapping { routerMapper.close(routerMapping) }
        routerMapping = nil
    }

    private func makeStatus(state statusState: CellularAccessState, diagnostic: String? = nil, publishedUntil: Date? = nil) -> CellularAccessStatus {
        let endpoint = activeEndpoint ?? settings.manualEndpoint ?? state.remoteEndpoint
        return CellularAccessStatus(enabled: settings.enabled, state: statusState, diagnostic: diagnostic, publishedUntil: publishedUntil, configuration: configuration(), advertisedEndpoint: endpoint, verifiedAt: verifiedAt, mappingMethod: routerMapping?.method.rawValue)
    }

    private static func validate(_ endpoint: RemoteEndpoint?) throws {
        guard let endpoint else { throw CellularSetupError.manualEndpointRequired }
        let host = endpoint.host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, host.count <= 255, !host.contains(where: { $0.isWhitespace || $0 == "/" }) else { throw CellularSetupError.invalidHost }
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

enum CellularSetupError: LocalizedError {
    case invalidPort, manualEndpointRequired, invalidHost, notEnabled
    var errorDescription: String? {
        switch self {
        case .invalidPort: "Choose a listener port between 1 and 65535."
        case .manualEndpointRequired: "Enter the public hostname or address and forwarded port."
        case .invalidHost: "The public hostname or address is invalid."
        case .notEnabled: "Enable cellular access before testing it."
        }
    }
}
