import Foundation
import CliveCore
import Observation

struct WorkspaceSnapshot: Codable {
    var selectedMacID: String?
    var sessionsByMac: [String: [SessionDescriptor]]
}

struct SessionDescriptor: Codable, Identifiable, Equatable {
    let id: UUID
    var label: String
    var serverSessionID: UUID?
    init(id: UUID = UUID(), label: String, serverSessionID: UUID? = nil) {
        self.id = id; self.label = label; self.serverSessionID = serverSessionID
    }
}

struct RestorableDestination: Codable, Equatable {
    static let currentVersion = 1

    enum Screen: String, Codable { case terminal, terminalList }

    let version: Int
    let screen: Screen
    let macID: String
    let sessionID: UUID?

    init(screen: Screen, macID: String, sessionID: UUID? = nil) {
        self.version = Self.currentVersion
        self.screen = screen
        self.macID = macID
        self.sessionID = sessionID
    }

    var isSupported: Bool {
        version == Self.currentVersion && (screen != .terminal || sessionID != nil)
    }
}

enum WorkspaceLaunchResolution: Equatable {
    case restoreTerminal(macID: String, sessionID: UUID)
    case restoreTerminalList(macID: String)
    case startTerminal(macID: String)
    case connectionSetup
}

enum WorkspaceLaunchResolver {
    static func resolve(
        destination: RestorableDestination?,
        selectedMacID: String?,
        pairedMacIDs: [String],
        descriptorsByMac: [String: [SessionDescriptor]]
    ) -> WorkspaceLaunchResolution {
        if let destination, destination.isSupported, pairedMacIDs.contains(destination.macID) {
            switch destination.screen {
            case .terminal:
                if let sessionID = destination.sessionID,
                   descriptorsByMac[destination.macID]?.contains(where: { $0.id == sessionID }) == true {
                    return .restoreTerminal(macID: destination.macID, sessionID: sessionID)
                }
            case .terminalList:
                return .restoreTerminalList(macID: destination.macID)
            }
        }
        if let selectedMacID, pairedMacIDs.contains(selectedMacID) { return .startTerminal(macID: selectedMacID) }
        if let defaultMacID = pairedMacIDs.first { return .startTerminal(macID: defaultMacID) }
        return .connectionSetup
    }
}

struct TerminalLaunchConfiguration: Equatable {
    let workingDirectory: String?
    let initialCommand: String?
}

enum WorkspaceTerminalLaunchResolver {
    static func resolve(action: ExternalLaunchURL.Action, preferences: AppPreferences) -> TerminalLaunchConfiguration {
        let shortcut: CLIShortcut?
        switch action {
        case .shortcut(let id): shortcut = preferences.shortcuts.first { $0.id == id }
        case .newTerminal, .resumeOrStart: shortcut = preferences.newTerminalDefaultShortcutID.flatMap { id in preferences.shortcuts.first { $0.id == id } }
        }
        let directory = shortcut?.workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let trimmedCommand = shortcut?.command.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return TerminalLaunchConfiguration(
            workingDirectory: directory.isEmpty ? nil : directory,
            initialCommand: trimmedCommand.isEmpty ? nil : shortcut?.command
        )
    }
}

struct InitialCommandBuffer {
    private var command: String?

    init(_ command: String?) { self.command = command }

    mutating func take() -> String? {
        defer { command = nil }
        return command
    }
}

struct SessionReconnectPolicy: Equatable {
    static let standard = SessionReconnectPolicy()
    let retryDelays: [TimeInterval]
    let detachmentDeadline: TimeInterval
    let cloudRefreshInterval: TimeInterval

    init(retryDelays: [TimeInterval] = [1, 2, 4, 8, 15], detachmentDeadline: TimeInterval = 30 * 60, cloudRefreshInterval: TimeInterval = 30) {
        self.retryDelays = retryDelays
        self.detachmentDeadline = detachmentDeadline
        self.cloudRefreshInterval = cloudRefreshInterval
    }

    func retryDelay(afterCycle cycle: Int) -> TimeInterval {
        retryDelays[min(max(cycle, 0), retryDelays.count - 1)]
    }

    func isExpired(startedAt: Date, now: Date) -> Bool { now.timeIntervalSince(startedAt) >= detachmentDeadline }
    func shouldRefreshCloud(lastRefresh: Date?, now: Date) -> Bool { lastRefresh.map { now.timeIntervalSince($0) >= cloudRefreshInterval } ?? true }
}

struct AuthenticationGracePolicy: Equatable {
    static let standard = AuthenticationGracePolicy(duration: 5 * 60)
    let duration: TimeInterval

    func permitsAccess(lastSuccessfulAuthentication: Date?, now: Date) -> Bool {
        guard let lastSuccessfulAuthentication else { return false }
        let elapsed = now.timeIntervalSince(lastSuccessfulAuthentication)
        return elapsed >= 0 && elapsed <= duration
    }
}

@MainActor @Observable final class WorkspaceSession: Identifiable {
    var descriptor: SessionDescriptor
    nonisolated let id: UUID
    let client = SessionClient()
    var state: SessionClient.State = .connecting
    var preview: String?
    var lastActivityAt: Date?
    var attachmentState: AttachmentState?
    private var accumulator = TerminalPreviewAccumulator()

    private var routes: [MacRoute]
    private let device: PairedMac
    private let identity: IPhoneIdentity
    private var routeIndex = 0
    private let workingDirectory: String?
    private var initialCommand: InitialCommandBuffer
    private let localRendezvousCapability: RendezvousCapability?
    private let onUpgrade: (Data, RendezvousCapability) -> Void
    private(set) var activeRouteKind: MacRouteKind?
    private var hasOpened = false
    private var reconnecting = false
    private var reconnectStartedAt: Date?
    private var retryIndex = 0
    private var retryTask: Task<Void, Never>?
    private var lastRouteRefresh: Date?
    private let refreshRoutes: @MainActor () async -> Void
    private let reconnectPolicy = SessionReconnectPolicy.standard
    private let now: () -> Date
    private let schedule: (TimeInterval, @escaping @MainActor () -> Void) -> Task<Void, Never>

    init(descriptor: SessionDescriptor, device: PairedMac, routes: [MacRoute], identity: IPhoneIdentity, workingDirectory: String?, initialCommand: String? = nil, localRendezvousCapability: RendezvousCapability?, refreshRoutes: @escaping @MainActor () async -> Void = {}, now: @escaping () -> Date = Date.init, schedule: @escaping (TimeInterval, @escaping @MainActor () -> Void) -> Task<Void, Never> = { delay, action in Task { try? await Task.sleep(for: .seconds(delay)); guard !Task.isCancelled else { return }; await action() } }, onUpgrade: @escaping (Data, RendezvousCapability) -> Void) {
        self.descriptor = descriptor
        self.id = descriptor.id
        self.routes = routes
        self.device = device
        self.identity = identity
        self.workingDirectory = workingDirectory
        self.initialCommand = InitialCommandBuffer(initialCommand)
        self.refreshRoutes = refreshRoutes
        self.now = now; self.schedule = schedule
        self.localRendezvousCapability = localRendezvousCapability; self.onUpgrade = onUpgrade
        client.onState = { [weak self] value in DispatchQueue.main.async { self?.handleState(value) } }
        client.onAttachmentState = { [weak self] value in DispatchQueue.main.async { self?.attachmentState = value } }
        client.onActivityOutput = { [weak self] bytes in DispatchQueue.main.async {
            guard let self else { return }; self.accumulator.consume(bytes); self.preview = self.accumulator.preview; self.lastActivityAt = .now
        } }
        client.onRendezvousUpgrade = { certificate, capability in DispatchQueue.main.async { onUpgrade(certificate, capability) } }
        connectCurrentRoute()
    }

    func noteInput() { lastActivityAt = .now }
    func clearTransientActivity() { accumulator.clear(); preview = nil; lastActivityAt = nil }
    func close() { retryTask?.cancel(); clearTransientActivity(); client.close() }
    func terminate() { retryTask?.cancel(); clearTransientActivity(); client.terminate() }
    func detach() { retryTask?.cancel(); client.detach() }

    func updateRoutes(_ newRoutes: [MacRoute]) {
        let changed = newRoutes != routes
        routes = newRoutes
        guard changed else { return }
        retryTask?.cancel()
        if reconnecting { routeIndex = 0; attemptReconnect() }
        else if hasOpened {
            let activeDirectWAN = activeRouteKind == .publicIPv6 || activeRouteKind == .manualPublicEndpoint
            let directWANWasRemoved = activeDirectWAN && !routes.contains { $0.kind == activeRouteKind }
            if directWANWasRemoved || (activeRouteKind != .lan && routes.first?.kind == .lan) { beginReconnect() }
        }
    }

    private func handleState(_ value: SessionClient.State) {
        state = value
        if case .active(let serverSessionID, let disposition, _) = value {
            descriptor.serverSessionID = serverSessionID
            retryTask?.cancel(); reconnecting = false; reconnectStartedAt = nil; retryIndex = 0; hasOpened = true
            activeRouteKind = routes[routeIndex].kind
            if disposition == .created, let command = initialCommand.take() {
                client.sendInput(Data((command + "\r").utf8))
                noteInput()
            }
        }
        switch value {
        case .networkError, .disconnected:
            if hasOpened {
                if reconnecting { advanceReconnect() } else { beginReconnect() }
            } else if routeIndex + 1 < routes.count {
                routeIndex += 1; connectCurrentRoute()
            }
        case .certificateChanged, .revoked, .protocolError, .resumeUnavailable, .workingDirectoryUnavailable:
            retryTask?.cancel(); reconnecting = false
        default: break
        }
    }

    private func beginReconnect() {
        reconnecting = true; reconnectStartedAt = now(); retryIndex = 0; routeIndex = 0
        attemptReconnect()
    }

    private func advanceReconnect() {
        guard reconnecting else { return }
        if routeIndex + 1 < routes.count { routeIndex += 1; attemptReconnect(); return }
        scheduleRetry()
    }

    private func attemptReconnect() {
        guard reconnecting else { return }
        guard let started = reconnectStartedAt, !reconnectPolicy.isExpired(startedAt: started, now: now()) else {
            reconnecting = false; state = .resumeUnavailable; return
        }
        guard !routes.isEmpty else { state = .reconnecting(waitingForWiFi: true); scheduleRetry(); return }
        routeIndex = min(routeIndex, routes.count - 1)
        connectCurrentRoute(expectsResumption: true)
    }

    private func scheduleRetry() {
        guard reconnecting else { return }
        routeIndex = 0
        let delay = reconnectPolicy.retryDelay(afterCycle: retryIndex)
        retryIndex += 1
        if reconnectPolicy.shouldRefreshCloud(lastRefresh: lastRouteRefresh, now: now()) {
            lastRouteRefresh = now()
            Task { await refreshRoutes() }
        }
        retryTask?.cancel()
        retryTask = schedule(delay) { [weak self] in self?.attemptReconnect() }
    }

    private func connectCurrentRoute(expectsResumption: Bool = false) {
        let route = routes[routeIndex]
        client.connect(host: route.host, port: route.port, pinnedFingerprint: device.certificateFingerprint, identity: identity.identity, clientSessionID: descriptor.id, serverSessionID: descriptor.serverSessionID, size: TerminalSize(columns: 80, rows: 24), rendezvousCapability: localRendezvousCapability, wanGateToken: route.wanGateToken, workingDirectory: workingDirectory, expectsResumption: expectsResumption)
    }
}

@MainActor @Observable final class WorkspaceCoordinator {
    enum State: Equatable { case locked, authenticating, active, authenticationCancelled, failed(String) }
    enum PresentedScreen: Equatable { case terminalList, connectionMenu, settings }
    enum Recovery: Equatable { case unavailableMac(String), noPairedMac, disconnected }

    let macs = PairedMacsModel()
    let preferences = AppPreferencesModel()
    var state: State = .locked
    var selectedMacID: String?
    var sessions: [WorkspaceSession] = []
    var selectedSessionID: UUID?
    var presentedScreen: PresentedScreen?
    var recovery: Recovery?
    var isDisconnecting = false
    var disconnectError: String?

    private var snapshot = WorkspaceSnapshot(selectedMacID: nil, sessionsByMac: [:])
    private var restorableDestination: RestorableDestination?
    private var identity: IPhoneIdentity?
    private var suppressDestinationUpdates = false
    private var pendingExternalAction: ExternalLaunchURL.Action?
    private let authenticate: @Sendable () async throws -> Void
    private let provideIdentity: @MainActor () throws -> IPhoneIdentity
    private let authenticationGracePolicy: AuthenticationGracePolicy
    private let now: () -> Date
    private var lastSuccessfulAuthentication: Date?
    private var isSceneActive = false
    private var hasCapturedForeground = false
    private var authenticationInFlight = false

    init(
        authenticate: @escaping @Sendable () async throws -> Void = { try await LocalAuthenticator.authorizeConnection() },
        provideIdentity: @escaping @MainActor () throws -> IPhoneIdentity = { try IPhoneIdentityProvider().loadOrCreate() },
        authenticationGracePolicy: AuthenticationGracePolicy = .standard,
        now: @escaping () -> Date = Date.init
    ) {
        self.authenticate = authenticate
        self.provideIdentity = provideIdentity
        self.authenticationGracePolicy = authenticationGracePolicy
        self.now = now
    }

    func start() {
        macs.start()
        macs.onRoutesChanged = { [weak self] in self?.updateLiveSessionRoutes() }
        snapshot = (try? WorkspaceStore().load()) ?? snapshot
        restorableDestination = try? RestorableDestinationStore().load()
        selectedMacID = snapshot.selectedMacID
    }

    func stop() { detachLiveSessions(); macs.stop() }
    var selectedMac: PairedMac? { macs.devices.first { $0.id == selectedMacID } }

    func authorize() async {
        guard !authenticationInFlight else { return }
        authenticationInFlight = true
        defer { authenticationInFlight = false }
        state = .authenticating
        do {
            try await authenticate()
            identity = try provideIdentity()
            lastSuccessfulAuthentication = now()
            guard isSceneActive else { state = .locked; return }
            state = .active
            if let action = pendingExternalAction {
                pendingExternalAction = nil
                performExternalLaunch(action)
            } else {
                resolveExternalLaunch()
            }
        } catch { state = isSceneActive ? .authenticationCancelled : .locked }
    }

    func sceneDidBecomeActive() async {
        guard !isSceneActive else { return }
        isSceneActive = true
        hasCapturedForeground = false
        guard !authenticationInFlight else { return }
        if authenticationGracePolicy.permitsAccess(lastSuccessfulAuthentication: lastSuccessfulAuthentication, now: now()) {
            guard identity != nil else { await authorize(); return }
            state = .active
            resolveExternalLaunch()
        } else {
            await authorize()
        }
    }

    func handleExternalLaunch() {
        guard state == .active else { return }
        resolveExternalLaunch()
    }

    func handleExternalLaunch(_ action: ExternalLaunchURL.Action) {
        guard state == .active else { pendingExternalAction = action; return }
        performExternalLaunch(action)
    }

    func selectMac(_ mac: PairedMac) {
        guard mac.id != selectedMacID else { presentedScreen = nil; return }
        saveCurrentDescriptors(); closeLiveSessions(); selectedMacID = mac.id; snapshot.selectedMacID = mac.id; recovery = nil; persist()
        startFreshTerminal(on: mac)
    }

    func selectSession(_ id: UUID?) {
        selectedSessionID = id
        guard !suppressDestinationUpdates, let id, let macID = selectedMacID else { return }
        recordDestination(RestorableDestination(screen: .terminal, macID: macID, sessionID: id))
    }

    func runShortcut(_ shortcut: CLIShortcut) {
        guard let session = sessions.first(where: { $0.id == selectedSessionID }), !shortcut.command.isEmpty else { return }
        session.client.sendInput(Data((shortcut.command + "\r").utf8))
    }

    func showTerminalList() {
        presentedScreen = .terminalList
        if let macID = selectedMacID { recordDestination(RestorableDestination(screen: .terminalList, macID: macID)) }
    }

    func showSettings() { presentedScreen = .settings }
    func showConnections() { presentedScreen = .connectionMenu }

    func dismissPresentedScreen() {
        presentedScreen = nil
        if let id = selectedSessionID, let macID = selectedMacID {
            recordDestination(RestorableDestination(screen: .terminal, macID: macID, sessionID: id))
        }
    }

    func addShell() {
        guard let mac = selectedMac, let identity else { return }
        let routes = routes(for: mac)
        guard !routes.isEmpty else { recovery = .unavailableMac(mac.displayName); return }
        recovery = nil
        let descriptor = SessionDescriptor(label: "Shell \(sessions.count + 1)")
        let configuration = WorkspaceTerminalLaunchResolver.resolve(action: .newTerminal, preferences: preferences.value)
        let session = makeSession(descriptor: descriptor, mac: mac, routes: routes, identity: identity, workingDirectory: configuration.workingDirectory, initialCommand: configuration.initialCommand)
        sessions.append(session); selectSession(session.id); saveCurrentDescriptors(); persist()
    }

    func close(_ session: WorkspaceSession) {
        session.close(); sessions.removeAll { $0.id == session.id }
        if selectedSessionID == session.id { selectSession(sessions.last?.id) }
        saveCurrentDescriptors(); persist()
        if sessions.isEmpty { clearDestination() }
    }

    func end(_ session: WorkspaceSession) {
        session.terminate(); sessions.removeAll { $0.id == session.id }
        if selectedSessionID == session.id { selectSession(sessions.last?.id) }
        saveCurrentDescriptors(); persist()
        if sessions.isEmpty { clearDestination() }
    }

    func rename(_ session: WorkspaceSession, to label: String) {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        session.descriptor.label = trimmed
        saveCurrentDescriptors(); persist()
    }

    func disconnectCurrentMac() async {
        guard !isDisconnecting, let mac = selectedMac, let identity else { return }
        isDisconnecting = true
        disconnectError = nil
        defer { isDisconnecting = false }
        do {
            try await UnpairingClient().revoke(device: mac, routes: routes(for: mac), identity: identity.identity)
            try macs.forget(mac)
            closeLiveSessions()
            snapshot.sessionsByMac.removeValue(forKey: mac.id)
            selectedMacID = nil
            snapshot.selectedMacID = nil
            persist()
            clearDestination()
            recovery = .noPairedMac
            presentedScreen = nil
        } catch {
            disconnectError = error.localizedDescription
        }
    }

    func retryConnection() {
        guard state == .active, let mac = selectedMac else { showConnections(); return }
        Task { await macs.refreshRendezvous(); startFreshTerminal(on: mac) }
    }

    func sceneWillLeaveForeground() {
        guard isSceneActive, !hasCapturedForeground else { return }
        isSceneActive = false
        hasCapturedForeground = true
        if !sessions.isEmpty { saveCurrentDescriptors(); persist() }
        sessions.forEach { $0.clearTransientActivity() }
        detachLiveSessions()
        presentedScreen = nil
        state = .locked
    }

    func cellularPreferenceChanged() { updateLiveSessionRoutes() }

    private func resolveExternalLaunch() {
        let resolution = WorkspaceLaunchResolver.resolve(
            destination: restorableDestination,
            selectedMacID: snapshot.selectedMacID,
            pairedMacIDs: macs.devices.map(\.id),
            descriptorsByMac: snapshot.sessionsByMac
        )
        switch resolution {
        case .restoreTerminal(let macID, let sessionID):
            activateMac(macID, selectedSessionID: sessionID, showList: false)
        case .restoreTerminalList(let macID):
            activateMac(macID, selectedSessionID: nil, showList: true)
        case .startTerminal(let macID):
            guard let mac = macs.devices.first(where: { $0.id == macID }) else { return }
            selectedMacID = mac.id; snapshot.selectedMacID = mac.id
            startFreshTerminal(on: mac)
        case .connectionSetup:
            closeLiveSessions(); recovery = .noPairedMac; presentedScreen = .connectionMenu
        }
    }

    private func activateMac(_ macID: String, selectedSessionID: UUID?, showList: Bool) {
        guard let mac = macs.devices.first(where: { $0.id == macID }), let identity else { return }
        let routes = routes(for: mac)
        selectedMacID = macID; snapshot.selectedMacID = macID
        guard !routes.isEmpty else {
            closeLiveSessions(); recovery = .unavailableMac(mac.displayName); presentedScreen = showList ? .terminalList : nil
            return
        }
        suppressDestinationUpdates = true
        closeLiveSessions()
        sessions = (snapshot.sessionsByMac[macID] ?? []).map { makeSession(descriptor: $0, mac: mac, routes: routes, identity: identity) }
        self.selectedSessionID = selectedSessionID ?? sessions.first?.id
        presentedScreen = showList ? .terminalList : nil
        recovery = nil
        suppressDestinationUpdates = false
        saveCurrentDescriptors(); persist()
    }

    private func startFreshTerminal(on mac: PairedMac, action: ExternalLaunchURL.Action = .newTerminal) {
        guard let identity else { return }
        let routes = routes(for: mac)
        selectedMacID = mac.id; snapshot.selectedMacID = mac.id; presentedScreen = nil
        guard !routes.isEmpty else {
            closeLiveSessions(); recovery = .unavailableMac(mac.displayName); persist(); return
        }
        closeLiveSessions()
        let descriptor = SessionDescriptor(label: "Shell 1")
        let configuration = WorkspaceTerminalLaunchResolver.resolve(action: action, preferences: preferences.value)
        let session = makeSession(
            descriptor: descriptor,
            mac: mac,
            routes: routes,
            identity: identity,
            workingDirectory: configuration.workingDirectory,
            initialCommand: configuration.initialCommand
        )
        sessions = [session]
        snapshot.sessionsByMac[mac.id] = [descriptor]
        recovery = nil
        selectSession(session.id); persist()
    }

    private func performExternalLaunch(_ action: ExternalLaunchURL.Action) {
        guard action != .resumeOrStart else { resolveExternalLaunch(); return }
        guard let mac = selectedMac ?? macs.devices.first else {
            recovery = .noPairedMac; presentedScreen = .connectionMenu; return
        }
        switch action {
        case .resumeOrStart: resolveExternalLaunch()
        case .newTerminal: startFreshTerminal(on: mac)
        case .shortcut: startFreshTerminal(on: mac, action: action)
        }
    }

    private func routes(for mac: PairedMac) -> [MacRoute] {
        var values: [MacRoute] = []
        if let lan = macs.route(for: mac) { values.append(lan) }
        if let remote = mac.remoteEndpoint {
            let remoteRoute = MacRoute(host: remote.host, port: remote.port, kind: .privateVPN)
            if !values.contains(remoteRoute) { values.append(remoteRoute) }
        }
        if preferences.value.allowsCellularConnections {
            for route in macs.cellularRoutes(for: mac) where !values.contains(route) { values.append(route) }
        }
        return values
    }

    private func makeSession(descriptor: SessionDescriptor, mac: PairedMac, routes: [MacRoute], identity: IPhoneIdentity, workingDirectory: String? = nil, initialCommand: String? = nil) -> WorkspaceSession {
        return WorkspaceSession(descriptor: descriptor, device: mac, routes: routes, identity: identity, workingDirectory: workingDirectory, initialCommand: initialCommand, localRendezvousCapability: macs.localRendezvousCapability, refreshRoutes: { [weak self] in await self?.macs.refreshRendezvous() }) { [weak self] certificate, capability in
            self?.macs.upgrade(macID: mac.id, certificate: certificate, capability: capability)
        }
    }

    private func updateLiveSessionRoutes() {
        guard let mac = selectedMac else { return }
        let current = routes(for: mac)
        sessions.forEach { $0.updateRoutes(current) }
    }

    private func recordDestination(_ destination: RestorableDestination) {
        restorableDestination = destination
        try? RestorableDestinationStore().save(destination)
    }

    private func clearDestination() {
        restorableDestination = nil
        try? RestorableDestinationStore().remove()
    }

    private func closeLiveSessions() { sessions.forEach { $0.close() }; sessions.removeAll(); selectedSessionID = nil }
    private func detachLiveSessions() { sessions.forEach { $0.detach() }; sessions.removeAll(); selectedSessionID = nil }
    private func saveCurrentDescriptors() { guard let id = selectedMacID else { return }; snapshot.sessionsByMac[id] = sessions.map(\.descriptor); snapshot.selectedMacID = id }
    private func persist() { try? WorkspaceStore().save(snapshot) }
}

struct WorkspaceStore {
    private let rootURL: URL

    init(rootURL: URL? = nil) {
        self.rootURL = rootURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "Clive")
    }

    private var url: URL { rootURL.appending(path: "workspace.json") }
    func load() throws -> WorkspaceSnapshot { try JSONDecoder().decode(WorkspaceSnapshot.self, from: Data(contentsOf: url)) }
    func save(_ snapshot: WorkspaceSnapshot) throws {
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try JSONEncoder().encode(snapshot).write(to: url, options: [.atomic, .completeFileProtection])
    }
}

struct RestorableDestinationStore {
    private let rootURL: URL

    init(rootURL: URL? = nil) {
        self.rootURL = rootURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "Clive")
    }

    private var url: URL { rootURL.appending(path: "last-screen.json") }
    func load() throws -> RestorableDestination {
        let destination = try JSONDecoder().decode(RestorableDestination.self, from: Data(contentsOf: url))
        guard destination.isSupported else { throw CocoaError(.fileReadCorruptFile) }
        return destination
    }
    func save(_ destination: RestorableDestination) throws {
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try JSONEncoder().encode(destination).write(to: url, options: [.atomic, .completeFileProtection])
    }
    func remove() throws { if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) } }
}
