import Foundation
import XCTest
@testable import Clive

final class WorkspaceRestorationTests: XCTestCase {
    @MainActor func testDeleteAllEndsEveryOpenWorkspaceSession() async {
        let coordinator = WorkspaceCoordinator.uiTestFixture()

        await coordinator.deleteAllVisibleSessions()

        XCTAssertTrue(coordinator.sessions.isEmpty)
        XCTAssertNil(coordinator.selectedSessionID)
    }

    func testInitialOpeningRequiresAuthentication() {
        let policy = AuthenticationGracePolicy.standard

        XCTAssertFalse(policy.permitsAccess(lastSuccessfulAuthentication: nil, now: Date()))
    }

    func testBiometricGraceIncludesExactlyFiveMinutes() {
        let policy = AuthenticationGracePolicy.standard
        let verified = Date(timeIntervalSince1970: 1_000)

        XCTAssertTrue(policy.permitsAccess(lastSuccessfulAuthentication: verified, now: verified.addingTimeInterval(299)))
        XCTAssertTrue(policy.permitsAccess(lastSuccessfulAuthentication: verified, now: verified.addingTimeInterval(300)))
        XCTAssertFalse(policy.permitsAccess(lastSuccessfulAuthentication: verified, now: verified.addingTimeInterval(300.001)))
    }

    func testClockRollbackRequiresAuthentication() {
        let policy = AuthenticationGracePolicy.standard
        let verified = Date(timeIntervalSince1970: 1_000)

        XCTAssertFalse(policy.permitsAccess(lastSuccessfulAuthentication: verified, now: verified.addingTimeInterval(-1)))
    }

    func testFaceIDPresentationDoesNotSuspendLiveSessions() {
        XCTAssertFalse(SceneTransitionPolicy.shouldSuspendLiveSessions(
            isSceneActive: true,
            hasCapturedForeground: false,
            authenticationInFlight: true
        ))
        XCTAssertTrue(SceneTransitionPolicy.shouldSuspendLiveSessions(
            isSceneActive: true,
            hasCapturedForeground: false,
            authenticationInFlight: false
        ))
    }

    func testWorkspaceRestorationContainsNoAuthenticationOrTerminalContent() throws {
        let sessionID = UUID()
        let snapshot = WorkspaceSnapshot(
            selectedMacID: "mac-1",
            sessionsByMac: ["mac-1": [SessionDescriptor(id: sessionID, label: "Shell 1")]]
        )

        let json = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)

        XCTAssertTrue(json.contains(sessionID.uuidString))
        XCTAssertFalse(json.localizedCaseInsensitiveContains("biometric"))
        XCTAssertFalse(json.localizedCaseInsensitiveContains("preview"))
        XCTAssertFalse(json.localizedCaseInsensitiveContains("terminalContent"))
        XCTAssertFalse(json.localizedCaseInsensitiveContains("authentication"))
    }

    func testValidTerminalDestinationRestoresDescriptor() {
        let descriptor = SessionDescriptor(label: "Shell 1")
        let destination = RestorableDestination(screen: .terminal, macID: "mac-1", sessionID: descriptor.id)

        let resolution = WorkspaceLaunchResolver.resolve(
            destination: destination,
            selectedMacID: "mac-2",
            pairedMacIDs: ["mac-1", "mac-2"],
            descriptorsByMac: ["mac-1": [descriptor]]
        )

        XCTAssertEqual(resolution, .restoreTerminal(macID: "mac-1", sessionID: descriptor.id))
    }

    func testMissingDescriptorStartsOneTerminalOnLastSelectedMac() {
        let destination = RestorableDestination(screen: .terminal, macID: "mac-1", sessionID: UUID())

        let resolution = WorkspaceLaunchResolver.resolve(
            destination: destination,
            selectedMacID: "mac-2",
            pairedMacIDs: ["mac-1", "mac-2"],
            descriptorsByMac: [:]
        )

        XCTAssertEqual(resolution, .startTerminal(macID: "mac-2"))
    }

    func testTerminalListRestoresWithoutSessionDescriptors() {
        let destination = RestorableDestination(screen: .terminalList, macID: "mac-1")

        let resolution = WorkspaceLaunchResolver.resolve(
            destination: destination,
            selectedMacID: nil,
            pairedMacIDs: ["mac-1"],
            descriptorsByMac: [:]
        )

        XCTAssertEqual(resolution, .restoreTerminalList(macID: "mac-1"))
    }

    func testDestinationForRemovedMacFallsBackToLastSelectedPairedMac() {
        let destination = RestorableDestination(screen: .terminalList, macID: "removed")

        let resolution = WorkspaceLaunchResolver.resolve(
            destination: destination,
            selectedMacID: "mac-2",
            pairedMacIDs: ["mac-1", "mac-2"],
            descriptorsByMac: [:]
        )

        XCTAssertEqual(resolution, .startTerminal(macID: "mac-2"))
    }

    func testRemovedLastSelectedMacUsesFirstPairedMacAsDefault() {
        let resolution = WorkspaceLaunchResolver.resolve(
            destination: nil,
            selectedMacID: "removed",
            pairedMacIDs: ["alpha", "beta"],
            descriptorsByMac: [:]
        )

        XCTAssertEqual(resolution, .startTerminal(macID: "alpha"))
    }

    func testNoPairedMacOpensConnectionSetup() {
        XCTAssertEqual(
            WorkspaceLaunchResolver.resolve(destination: nil, selectedMacID: nil, pairedMacIDs: [], descriptorsByMac: [:]),
            .connectionSetup
        )
    }

    func testRemovingActiveLANRouteStartsCellularReconnect() {
        XCTAssertTrue(WorkspaceSession.shouldReconnectAfterRouteChange(
            activeRouteKind: .lan,
            newRoutes: [MacRoute(host: "198.51.100.10", port: 64236, kind: .manualPublicEndpoint)],
            hasOpened: true
        ))
    }

    func testAddingPreferredLANRouteStartsReconnectFromWAN() {
        XCTAssertTrue(WorkspaceSession.shouldReconnectAfterRouteChange(
            activeRouteKind: .manualPublicEndpoint,
            newRoutes: [MacRoute(host: "mac.local", port: 64236, kind: .lan)],
            hasOpened: true
        ))
    }

    func testRouteChangesDoNotReconnectBeforeSessionOpens() {
        XCTAssertFalse(WorkspaceSession.shouldReconnectAfterRouteChange(
            activeRouteKind: .lan,
            newRoutes: [],
            hasOpened: false
        ))
    }

    func testDestinationStoreRejectsUnsupportedVersion() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let json = #"{"version":2,"screen":"terminalList","macID":"mac-1","sessionID":null}"#
        try Data(json.utf8).write(to: root.appending(path: "last-screen.json"))

        XCTAssertThrowsError(try RestorableDestinationStore(rootURL: root).load())
    }

    func testDestinationStoreRejectsMalformedData() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("not-json".utf8).write(to: root.appending(path: "last-screen.json"))

        XCTAssertThrowsError(try RestorableDestinationStore(rootURL: root).load())
    }

    func testWorkspaceStoreRejectsOldShape() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(#"{"selectedMacID":"mac-1"}"#.utf8).write(to: root.appending(path: "workspace.json"))

        XCTAssertThrowsError(try WorkspaceStore(rootURL: root).load())
    }

    func testLocalStateResetterClearsOnlyCliveLocalRecords() throws {
        var removed: [String] = []
        let resetter = LocalStateResetter(
            removePairedMacs: { removed.append("paired-macs") },
            removeWorkspace: { removed.append("workspace") },
            removeRestoration: { removed.append("restoration") },
            removePreferences: { removed.append("preferences") }
        )

        try resetter.reset()

        XCTAssertEqual(removed, ["paired-macs", "workspace", "restoration", "preferences"])
    }

    func testDestinationStoreRoundTripsWithoutWorkspaceContent() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = RestorableDestination(screen: .terminalList, macID: "mac-1")
        let store = RestorableDestinationStore(rootURL: root)

        try store.save(destination)

        XCTAssertEqual(try store.load(), destination)
        let data = try Data(contentsOf: root.appending(path: "last-screen.json"))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("label"))
    }

    func testExternalLaunchURLAcceptsOnlyFixedDataFreeRoute() {
        XCTAssertTrue(ExternalLaunchURL.matches(URL(string: "clive://resume-or-start")!))
        XCTAssertTrue(ExternalLaunchURL.matches(URL(string: "clive://resume-or-start/")!))
        XCTAssertEqual(ExternalLaunchURL.action(for: URL(string: "clive://new-terminal")!), .newTerminal)
        let shortcutID = UUID()
        XCTAssertEqual(ExternalLaunchURL.action(for: URL(string: "clive://shortcut/\(shortcutID)")!), .shortcut(shortcutID))
        XCTAssertFalse(ExternalLaunchURL.matches(URL(string: "clive://resume-or-start?mac=secret")!))
        XCTAssertFalse(ExternalLaunchURL.matches(URL(string: "clive://shortcut/not-a-uuid")!))
        XCTAssertFalse(ExternalLaunchURL.matches(URL(string: "clive://other")!))
        XCTAssertFalse(ExternalLaunchURL.matches(URL(string: "https://resume-or-start")!))
    }

    func testExternalLaunchRequestIsConsumedOnce() {
        let suiteName = "WorkspaceRestorationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = ExternalLaunchRequestStore(defaults: defaults)

        XCTAssertFalse(store.consumePending())
        store.request()
        XCTAssertTrue(store.consumePending())
        XCTAssertFalse(store.consumePending())
    }

    func testShortcutLaunchIsCommandOnly() {
        let shortcut = CLIShortcut(name: "Status", command: "git status --short")
        let preferences = AppPreferences(shortcuts: [shortcut])

        XCTAssertEqual(
            WorkspaceTerminalLaunchResolver.resolve(action: .shortcut(shortcut.id), preferences: preferences),
            TerminalLaunchConfiguration(workingDirectory: nil, initialCommand: "git status --short")
        )
    }

    func testNewTerminalDefaultLaunchIsCommandOnly() {
        let shortcut = CLIShortcut(name: "Status", command: "git status --short")
        let preferences = AppPreferences(shortcuts: [shortcut], newTerminalDefaultShortcutID: shortcut.id)

        XCTAssertEqual(
            WorkspaceTerminalLaunchResolver.resolve(action: .newTerminal, preferences: preferences),
            TerminalLaunchConfiguration(workingDirectory: nil, initialCommand: "git status --short")
        )
    }

    func testMissingWidgetShortcutFallsBackToNewTerminal() {
        let configuration = WorkspaceTerminalLaunchResolver.resolve(action: .shortcut(UUID()), preferences: AppPreferences())

        XCTAssertEqual(configuration, TerminalLaunchConfiguration(workingDirectory: nil, initialCommand: nil))
    }

    func testInitialCommandCanOnlyBeConsumedOnce() {
        var buffer = InitialCommandBuffer("swift test")

        XCTAssertEqual(buffer.take(), "swift test")
        XCTAssertNil(buffer.take())
    }

    func testConnectionAttemptAllowsTimeForInteractiveAuthentication() {
        XCTAssertEqual(SessionClient.connectionAttemptTimeout, 60)
    }

    func testStateUpdateFromSupersededConnectionAttemptIsIgnored() {
        XCTAssertFalse(WorkspaceSession.shouldApplyStateUpdate(generation: 1, currentGeneration: 2))
        XCTAssertTrue(WorkspaceSession.shouldApplyStateUpdate(generation: 2, currentGeneration: 2))
    }

    func testReconnectBackoffIsImmediateThenBoundedAtFifteenSeconds() {
        let policy = SessionReconnectPolicy.standard

        XCTAssertEqual((0...7).map(policy.retryDelay(afterCycle:)), [1, 2, 4, 8, 15, 15, 15, 15])
    }

    func testInitialConnectionRetriesWithoutRequiringResumption() {
        let policy = SessionReconnectPolicy.standard

        XCTAssertTrue(policy.shouldBeginRetryAfterRouteChange(hasOpened: false, reconnecting: false))
        XCTAssertFalse(policy.expectsResumption(hasOpened: false))
        XCTAssertTrue(policy.expectsResumption(hasOpened: true))
    }

    func testReconnectDeadlineIsNinetyMinutes() {
        let policy = SessionReconnectPolicy.standard
        let start = Date(timeIntervalSince1970: 1_000)

        XCTAssertFalse(policy.isExpired(startedAt: start, now: start.addingTimeInterval(5_399)))
        XCTAssertTrue(policy.isExpired(startedAt: start, now: start.addingTimeInterval(5_400)))
    }

    @MainActor
    func testReconnectNoticeDismissesAfterItsScheduledDuration() {
        var scheduledAction: (@MainActor () -> Void)?
        let session = WorkspaceSession(
            fixture: SessionDescriptor(label: "Shell 1"),
            state: .active(UUID(), .resumed, false),
            schedule: { duration, action in
                XCTAssertEqual(duration, SessionReconnectNoticePolicy.standard.duration)
                scheduledAction = action
                return Task {}
            }
        )

        session.showReconnectNotice()
        XCTAssertTrue(session.showsReconnectNotice)

        scheduledAction?()
        XCTAssertFalse(session.showsReconnectNotice)
    }

    func testCloudRoutesRefreshNoMoreThanEveryThirtySeconds() {
        let policy = SessionReconnectPolicy.standard
        let now = Date(timeIntervalSince1970: 1_000)

        XCTAssertTrue(policy.shouldRefreshCloud(lastRefresh: nil, now: now))
        XCTAssertFalse(policy.shouldRefreshCloud(lastRefresh: now.addingTimeInterval(-29), now: now))
        XCTAssertTrue(policy.shouldRefreshCloud(lastRefresh: now.addingTimeInterval(-30), now: now))
    }

    func testUnavailableMacRetriesWhenFirstRouteArrives() {
        XCTAssertTrue(WorkspaceCoordinator.shouldRetryUnavailableMac(
            recovery: .unavailableMac("Mac"),
            state: .active,
            routesAvailable: true
        ))
        XCTAssertFalse(WorkspaceCoordinator.shouldRetryUnavailableMac(
            recovery: .unavailableMac("Mac"),
            state: .active,
            routesAvailable: false
        ))
        XCTAssertFalse(WorkspaceCoordinator.shouldRetryUnavailableMac(
            recovery: nil,
            state: .active,
            routesAvailable: true
        ))
    }
}
