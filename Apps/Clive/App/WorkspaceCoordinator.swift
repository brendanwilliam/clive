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

struct RestorableDestination: Codable, Equatable, Sendable {
    static let currentVersion = 1

    enum Screen: String, Codable, Sendable { case terminal, terminalList }

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
        let trimmedCommand = shortcut?.command.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return TerminalLaunchConfiguration(
            workingDirectory: nil,
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

struct SessionReconnectNoticePolicy: Equatable {
    static let standard = SessionReconnectNoticePolicy()
    let duration: TimeInterval

    init(duration: TimeInterval = 3) { self.duration = duration }
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

    func shouldBeginRetryAfterRouteChange(hasOpened: Bool, reconnecting: Bool) -> Bool { !hasOpened && !reconnecting }
    func expectsResumption(hasOpened: Bool) -> Bool { hasOpened }
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
    var showsReconnectNotice = false
    private var accumulator = TerminalPreviewAccumulator()

    private var routes: [MacRoute]
    private let device: PairedMac?
    private let identity: IPhoneIdentity?
    private var routeIndex = 0
    private var initialCommand: InitialCommandBuffer
    private let localRendezvousCapability: RendezvousCapability?
    private let onUpgrade: (Data, RendezvousCapability) -> Void
    private(set) var activeRouteKind: MacRouteKind?
    private var hasOpened = false
    private var reconnecting = false
    private var reconnectStartedAt: Date?
    private var retryIndex = 0
    private var retryTask: Task<Void, Never>?
    private var reconnectNoticeTask: Task<Void, Never>?
    private var lastRouteRefresh: Date?
    private let refreshRoutes: @MainActor () async -> Void
    private let reconnectPolicy = SessionReconnectPolicy.standard
    private let reconnectNoticePolicy = SessionReconnectNoticePolicy.standard
    private let now: () -> Date
    private let schedule: (TimeInterval, @escaping @MainActor () -> Void) -> Task<Void, Never>

    init(descriptor: SessionDescriptor, device: PairedMac, routes: [MacRoute], identity: IPhoneIdentity, initialCommand: String? = nil, localRendezvousCapability: RendezvousCapability?, refreshRoutes: @escaping @MainActor () async -> Void = {}, now: @escaping () -> Date = Date.init, schedule: @escaping (TimeInterval, @escaping @MainActor () -> Void) -> Task<Void, Never> = { delay, action in Task { try? await Task.sleep(for: .seconds(delay)); guard !Task.isCancelled else { return }; await action() } }, onUpgrade: @escaping (Data, RendezvousCapability) -> Void) {
        self.descriptor = descriptor
        self.id = descriptor.id
        self.routes = routes
        self.device = device
        self.identity = identity
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

#if DEBUG
    init(fixture descriptor: SessionDescriptor, state: SessionClient.State, route: MacRouteKind = .lan, schedule: @escaping (TimeInterval, @escaping @MainActor () -> Void) -> Task<Void, Never> = { _, _ in Task {} }) {
        self.descriptor = descriptor; id = descriptor.id; routes = []
        device = nil; identity = nil
        initialCommand = InitialCommandBuffer(nil); localRendezvousCapability = nil
        refreshRoutes = {}; now = Date.init
        self.schedule = schedule; onUpgrade = { _, _ in }
        self.state = state; activeRouteKind = route; hasOpened = true; lastActivityAt = .now
    }
#endif

    func noteInput() { lastActivityAt = .now }
    func run(command: String) { client.sendInput(ShortcutExecutionPolicy.payload(for: command)); noteInput() }
    func clearTransientActivity() { accumulator.clear(); preview = nil; lastActivityAt = nil }
    func close() { retryTask?.cancel(); reconnectNoticeTask?.cancel(); clearTransientActivity(); client.close() }
    func terminate() { retryTask?.cancel(); reconnectNoticeTask?.cancel(); clearTransientActivity(); client.terminate() }
    func detach() { retryTask?.cancel(); reconnectNoticeTask?.cancel(); client.detach() }
    func disconnect() {
        retryTask?.cancel()
        reconnectNoticeTask?.cancel()
        reconnecting = false
        client.close()
        state = .disconnected
    }
    func reconnect() {
        retryTask?.cancel()
        reconnectNoticeTask?.cancel()
        reconnecting = false
        routeIndex = 0
        guard !routes.isEmpty else {
            state = .reconnecting(waitingForWiFi: true)
            return
        }
        state = .connecting
        connectCurrentRoute(expectsResumption: hasOpened)
    }

    func updateRoutes(_ newRoutes: [MacRoute]) {
        let changed = newRoutes != routes
        routes = newRoutes
        guard changed else { return }
        retryTask?.cancel()
        if reconnecting { routeIndex = 0; attemptReconnect() }
        else if reconnectPolicy.shouldBeginRetryAfterRouteChange(hasOpened: hasOpened, reconnecting: reconnecting) { beginReconnect() }
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
            if let command = initialCommand.take() {
                client.sendInput(Data((command + "\r").utf8))
                noteInput()
            }
            if disposition == .resumed { showReconnectNotice() }
        }
        switch value {
        case .networkError, .disconnected:
            if reconnecting { advanceReconnect() }
            else if routeIndex + 1 < routes.count {
                routeIndex += 1; connectCurrentRoute()
            } else { beginReconnect() }
        case .certificateChanged, .revoked, .protocolError, .resumeUnavailable, .workingDirectoryUnavailable:
            retryTask?.cancel(); reconnecting = false
        default: break
        }
    }

    func showReconnectNotice() {
        reconnectNoticeTask?.cancel()
        showsReconnectNotice = true
        reconnectNoticeTask = schedule(reconnectNoticePolicy.duration) { [weak self] in
            self?.showsReconnectNotice = false
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
        connectCurrentRoute(expectsResumption: reconnectPolicy.expectsResumption(hasOpened: hasOpened))
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
        guard let device, let identity, routes.indices.contains(routeIndex) else { return }
        let route = routes[routeIndex]
        client.connect(host: route.host, port: route.port, pinnedFingerprint: device.certificateFingerprint, identity: identity.identity, clientSessionID: descriptor.id, serverSessionID: descriptor.serverSessionID, size: TerminalSize(columns: 80, rows: 24), rendezvousCapability: localRendezvousCapability, wanGateToken: route.wanGateToken, expectsResumption: expectsResumption)
    }
}

struct LocalStateResetter {
    let removePairedMacs: () throws -> Void
    let removeWorkspace: () throws -> Void
    let removeRestoration: () throws -> Void
    let removePreferences: () throws -> Void

    init(
        removePairedMacs: @escaping () throws -> Void = { try PairedMacStore().removeAll() },
        removeWorkspace: @escaping () throws -> Void = { try WorkspaceStore().remove() },
        removeRestoration: @escaping () throws -> Void = { try RestorableDestinationStore().remove() },
        removePreferences: @escaping () throws -> Void = { try AppPreferencesStore().remove() }
    ) {
        self.removePairedMacs = removePairedMacs
        self.removeWorkspace = removeWorkspace
        self.removeRestoration = removeRestoration
        self.removePreferences = removePreferences
    }

    func reset() throws {
        try removePairedMacs()
        try removeWorkspace()
        try removeRestoration()
        try removePreferences()
    }
}

@MainActor @Observable final class WorkspaceCoordinator {
    enum State: Equatable { case locked, authenticating, active, authenticationCancelled, unsupportedLocalState, failed(String) }
    enum PresentedScreen: Equatable { case terminalList, settings }
    enum Recovery: Equatable { case unavailableMac(String), noPairedMac, disconnected }

    let macs = PairedMacsModel()
    let preferences = AppPreferencesModel()
    var state: State = .locked
    var selectedMacID: String?
    var sessions: [WorkspaceSession] = []
    var catalogSessions: [CliveCore.SessionDescriptor] = []
    var selectedSessionID: UUID?
    var presentedScreen: PresentedScreen?
    var recovery: Recovery?
    var isDisconnecting = false
    var disconnectError: String?
    var isDeletingAllVisibleSessions = false
    var deleteAllError: String?

    private var snapshot = WorkspaceSnapshot(selectedMacID: nil, sessionsByMac: [:])
    private var restorableDestination: RestorableDestination?
    private var identity: IPhoneIdentity?
    private var suppressDestinationUpdates = false
    private var pendingExternalAction: ExternalLaunchURL.Action?
    private let sessionCatalog = SessionCatalogClient()
    private let authenticate: @Sendable () async throws -> Void
    private let provideIdentity: @MainActor () throws -> IPhoneIdentity
    private let authenticationGracePolicy: AuthenticationGracePolicy
    private let now: () -> Date
    private let localStateResetter: LocalStateResetter
    private var lastSuccessfulAuthentication: Date?
    private var isSceneActive = false
    private var hasCapturedForeground = false
    private var authenticationInFlight = false
    private let isUITestFixture: Bool

    init(
        authenticate: @escaping @Sendable () async throws -> Void = { try await LocalAuthenticator.authorizeConnection() },
        provideIdentity: @escaping @MainActor () throws -> IPhoneIdentity = { try IPhoneIdentityProvider().loadOrCreate() },
        authenticationGracePolicy: AuthenticationGracePolicy = .standard,
        now: @escaping () -> Date = Date.init,
        localStateResetter: LocalStateResetter = LocalStateResetter(),
        isUITestFixture: Bool = false
    ) {
        self.authenticate = authenticate
        self.provideIdentity = provideIdentity
        self.authenticationGracePolicy = authenticationGracePolicy
        self.now = now
        self.localStateResetter = localStateResetter
        self.isUITestFixture = isUITestFixture
        sessionCatalog.onSessions = { [weak self] sessions in
            DispatchQueue.main.async { self?.applyCatalog(sessions) }
        }
    }

    func start() {
        if isUITestFixture { return }
        do {
            snapshot = try WorkspaceStore().loadIfPresent() ?? snapshot
            restorableDestination = try RestorableDestinationStore().loadIfPresent()
            _ = try AppPreferencesStore().loadIfPresent()
        } catch {
            state = .unsupportedLocalState
            return
        }
        macs.start()
        macs.onRoutesChanged = { [weak self] in self?.updateLiveSessionRoutes() }
        selectedMacID = snapshot.selectedMacID
    }

    func resetUnsupportedLocalState() {
        guard state == .unsupportedLocalState else { return }
        do {
            try localStateResetter.reset()
            snapshot = WorkspaceSnapshot(selectedMacID: nil, sessionsByMac: [:])
            restorableDestination = nil
            selectedMacID = nil
            sessions = []
            catalogSessions = []
            state = .locked
            macs.start()
            macs.onRoutesChanged = { [weak self] in self?.updateLiveSessionRoutes() }
        } catch {
            state = .unsupportedLocalState
        }
    }

    func stop() { sessionCatalog.close(); detachLiveSessions(); macs.stop() }
    var selectedMac: PairedMac? { macs.devices.first { $0.id == selectedMacID } }
    var selectedSession: WorkspaceSession? { sessions.first { $0.id == selectedSessionID } }

    func authorize() async {
        if isUITestFixture { return }
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
        if isUITestFixture { return }
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
    func showConnections() { showTerminalList() }

    func dismissPresentedScreen() {
        presentedScreen = nil
        if let id = selectedSessionID, let macID = selectedMacID {
            recordDestination(RestorableDestination(screen: .terminal, macID: macID, sessionID: id))
        }
    }

    func addShell() {
#if DEBUG
        if isUITestFixture {
            let descriptor = SessionDescriptor(label: "Shell \(sessions.count + 1)")
            let session = WorkspaceSession(fixture: descriptor, state: .active(UUID(), .created, false))
            sessions.append(session); selectSession(session.id); return
        }
#endif
        guard let mac = selectedMac, let identity else { return }
        let routes = routes(for: mac)
        guard !routes.isEmpty else { recovery = .unavailableMac(mac.displayName); return }
        recovery = nil
        let descriptor = SessionDescriptor(label: "Shell \(sessions.count + 1)")
        let configuration = WorkspaceTerminalLaunchResolver.resolve(action: .newTerminal, preferences: preferences.value)
        let session = makeSession(descriptor: descriptor, mac: mac, routes: routes, identity: identity, initialCommand: configuration.initialCommand)
        sessions.append(session); selectSession(session.id); saveCurrentDescriptors(); persist()
    }

    var unrepresentedCatalogSessions: [CliveCore.SessionDescriptor] {
        catalogSessions.filter { catalog in
            !sessions.contains { $0.descriptor.serverSessionID == catalog.id }
        }
    }

    var openSessionCount: Int {
        Set(catalogSessions.map(\.id)).union(sessions.compactMap(\.descriptor.serverSessionID)).count
            + sessions.filter { $0.descriptor.serverSessionID == nil }.count
    }

    var activeSessionCount: Int {
        let activeCatalog = Set(catalogSessions.filter { $0.attachmentCount > 0 }.map(\.id))
        let activeLocal = sessions.filter { session in
            guard case .active = session.state else { return false }
            return session.descriptor.serverSessionID.map { !activeCatalog.contains($0) } ?? true
        }.count
        return activeCatalog.count + activeLocal
    }

    func reconnect(_ catalogSession: CliveCore.SessionDescriptor) {
        guard catalogSession.attachmentCount == 0,
              let mac = selectedMac,
              let identity else { return }
        let routes = routes(for: mac)
        guard !routes.isEmpty else { recovery = .unavailableMac(mac.displayName); return }
        let descriptor = SessionDescriptor(label: "Reconnected terminal", serverSessionID: catalogSession.id)
        let session = makeSession(descriptor: descriptor, mac: mac, routes: routes, identity: identity)
        sessions.append(session)
        selectSession(session.id)
        saveCurrentDescriptors()
        persist()
        presentedScreen = nil
    }

    func disconnect(_ session: WorkspaceSession) {
        session.disconnect()
        saveCurrentDescriptors()
        persist()
    }

    func reconnect(_ session: WorkspaceSession) {
        session.reconnect()
    }

    @discardableResult
    func runShortcut(_ shortcut: CLIShortcut) -> Bool {
        let command = shortcut.command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let session = sessions.first(where: { $0.id == selectedSessionID }),
              ShortcutExecutionPolicy.canRun(command: command, state: session.state) else { return false }
        session.run(command: command)
        return true
    }

    func close(_ session: WorkspaceSession) {
        session.close(); sessions.removeAll { $0.id == session.id }
        if selectedSessionID == session.id { selectSession(sessions.last?.id) }
        saveCurrentDescriptors(); persist()
        if sessions.isEmpty { clearDestination() }
    }

    func disconnectAll() {
        sessions.forEach { $0.disconnect() }
        saveCurrentDescriptors(); persist()
    }

    func deleteAllVisibleSessions() async {
        guard !isDeletingAllVisibleSessions else { return }
        let visibleIDs = Array(Set(catalogSessions.map(\.id)).union(sessions.compactMap(\.descriptor.serverSessionID)))
        isDeletingAllVisibleSessions = true; deleteAllError = nil
        defer { isDeletingAllVisibleSessions = false }
#if DEBUG
        if isUITestFixture { sessions.forEach { $0.terminate() }; sessions.removeAll(); catalogSessions.removeAll(); selectSession(nil); return }
#endif
        if visibleIDs.isEmpty {
            sessions.forEach { $0.terminate() }; sessions.removeAll(); selectSession(nil)
            saveCurrentDescriptors(); persist(); clearDestination()
            return
        }
        let result: Result<[UUID], Error> = await withCheckedContinuation { continuation in
            sessionCatalog.terminate(sessionIDs: visibleIDs) { result in continuation.resume(returning: result) }
        }
        switch result {
        case .success(let terminated) where Set(terminated) == Set(visibleIDs):
            sessions.filter { $0.descriptor.serverSessionID == nil }.forEach { $0.terminate() }
            sessions.removeAll(); catalogSessions.removeAll(); selectSession(nil)
            saveCurrentDescriptors(); persist(); clearDestination()
        case .success(let terminated):
            deleteAllError = "Deleted \(terminated.count) of \(visibleIDs.count) terminals. Refresh and try again."
        case .failure:
            deleteAllError = "Couldn’t delete all terminals. Check the connection and try again."
        }
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
        sessionCatalog.close()
        catalogSessions.removeAll()
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
            closeLiveSessions(); recovery = .noPairedMac; presentedScreen = .terminalList
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
        startSessionCatalog(for: mac, routes: routes, identity: identity)
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
            initialCommand: configuration.initialCommand
        )
        sessions = [session]
        startSessionCatalog(for: mac, routes: routes, identity: identity)
        snapshot.sessionsByMac[mac.id] = [descriptor]
        recovery = nil
        selectSession(session.id); persist()
    }

    private func performExternalLaunch(_ action: ExternalLaunchURL.Action) {
        guard action != .resumeOrStart else { resolveExternalLaunch(); return }
        guard let mac = selectedMac ?? macs.devices.first else {
            recovery = .noPairedMac; presentedScreen = .terminalList; return
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

    private func makeSession(descriptor: SessionDescriptor, mac: PairedMac, routes: [MacRoute], identity: IPhoneIdentity, initialCommand: String? = nil) -> WorkspaceSession {
        return WorkspaceSession(descriptor: descriptor, device: mac, routes: routes, identity: identity, initialCommand: initialCommand, localRendezvousCapability: macs.localRendezvousCapability, refreshRoutes: { [weak self] in await self?.macs.refreshRendezvous() }) { [weak self] certificate, capability in
            self?.macs.upgrade(macID: mac.id, certificate: certificate, capability: capability)
        }
    }

    private func updateLiveSessionRoutes() {
        guard let mac = selectedMac else { return }
        let current = routes(for: mac)
        if Self.shouldRetryUnavailableMac(recovery: recovery, state: state, routesAvailable: !current.isEmpty) {
            recovery = nil
            resolveExternalLaunch()
            return
        }
        sessions.forEach { $0.updateRoutes(current) }
        if let identity { startSessionCatalog(for: mac, routes: current, identity: identity) }
    }

    nonisolated static func shouldRetryUnavailableMac(recovery: Recovery?, state: State, routesAvailable: Bool) -> Bool {
        guard state == .active, routesAvailable else { return false }
        if case .unavailableMac = recovery { return true }
        return false
    }

    private func recordDestination(_ destination: RestorableDestination) {
        restorableDestination = destination
        Task { await RestorableDestinationPersistence.shared.save(destination) }
    }

    private func clearDestination() {
        restorableDestination = nil
        Task { await RestorableDestinationPersistence.shared.remove() }
    }

    private func startSessionCatalog(for mac: PairedMac, routes: [MacRoute], identity: IPhoneIdentity) {
        guard let route = routes.first else { catalogSessions.removeAll(); sessionCatalog.close(); return }
        sessionCatalog.connect(host: route.host, port: route.port, pinnedFingerprint: mac.certificateFingerprint, identity: identity.identity, wanGateToken: route.wanGateToken)
    }

    private func applyCatalog(_ catalog: [CliveCore.SessionDescriptor]) {
        catalogSessions = catalog
        let liveServerSessionIDs = Set(catalog.map(\.id))
        let staleSessionIDs: [UUID] = sessions.compactMap { session -> UUID? in
            guard let serverSessionID = session.descriptor.serverSessionID,
                  !liveServerSessionIDs.contains(serverSessionID) else { return nil }
            return session.id
        }
        guard !staleSessionIDs.isEmpty else { return }
        sessions.filter { staleSessionIDs.contains($0.id) }.forEach { $0.close() }
        sessions.removeAll { staleSessionIDs.contains($0.id) }
        if let selectedSessionID, staleSessionIDs.contains(selectedSessionID) {
            selectSession(sessions.first?.id)
        }
        saveCurrentDescriptors()
        persist()
    }

    private func closeLiveSessions() { sessionCatalog.close(); sessions.forEach { $0.close() }; sessions.removeAll(); selectedSessionID = nil; catalogSessions.removeAll() }
    private func detachLiveSessions() { sessions.forEach { $0.detach() }; sessions.removeAll(); selectedSessionID = nil }
    private func saveCurrentDescriptors() { guard let id = selectedMacID else { return }; snapshot.sessionsByMac[id] = sessions.map(\.descriptor); snapshot.selectedMacID = id }
    private func persist() { try? WorkspaceStore().save(snapshot) }

#if DEBUG
    static func uiTestFixture() -> WorkspaceCoordinator {
        let coordinator = WorkspaceCoordinator(authenticate: {}, provideIdentity: { throw CocoaError(.userCancelled) }, isUITestFixture: true)
        let mac = PairedMac(
            id: "ui-test-mac", displayName: "Test Mac", serviceID: "ui-test-service",
            certificateFingerprint: String(repeating: "ab", count: 32), createdAt: Date(timeIntervalSince1970: 0)
        )
        coordinator.macs.installUITestFixture(device: mac, route: MacRoute(host: "127.0.0.1", port: 8022))
        coordinator.preferences.value = AppPreferences(shortcuts: [CLIShortcut(name: "Status", command: "git status --short")])
        coordinator.state = .active; coordinator.selectedMacID = mac.id
        coordinator.sessions = [
            WorkspaceSession(fixture: SessionDescriptor(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, label: "Shell 1"), state: .active(UUID(), .resumed, true)),
            WorkspaceSession(fixture: SessionDescriptor(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, label: "Shell 2"), state: .active(UUID(), .created, false))
        ]
        coordinator.catalogSessions = [
            CliveCore.SessionDescriptor(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
                label: "Detached shell",
                attachmentCount: 0,
                resizeOwner: nil,
                outputOffset: 0
            )
        ]
        coordinator.selectedSessionID = coordinator.sessions.first?.id
        return coordinator
    }
#endif
}

struct WorkspaceStore {
    private let rootURL: URL

    init(rootURL: URL? = nil) {
        self.rootURL = rootURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "Clive")
    }

    private var url: URL { rootURL.appending(path: "workspace.json") }
    func load() throws -> WorkspaceSnapshot { try JSONDecoder().decode(WorkspaceSnapshot.self, from: Data(contentsOf: url)) }
    func loadIfPresent() throws -> WorkspaceSnapshot? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try load()
    }
    func save(_ snapshot: WorkspaceSnapshot) throws {
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try JSONEncoder().encode(snapshot).write(to: url, options: [.atomic, .completeFileProtection])
    }
    func remove() throws { if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) } }
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
    func loadIfPresent() throws -> RestorableDestination? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try load()
    }
    func save(_ destination: RestorableDestination) throws {
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try JSONEncoder().encode(destination).write(to: url, options: [.atomic, .completeFileProtection])
    }
    func remove() throws { if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) } }
}

/// Keeps restoration-file I/O out of navigation actions while preserving write order.
actor RestorableDestinationPersistence {
    static let shared = RestorableDestinationPersistence()

    func save(_ destination: RestorableDestination) {
        try? RestorableDestinationStore().save(destination)
    }

    func remove() {
        try? RestorableDestinationStore().remove()
    }
}
