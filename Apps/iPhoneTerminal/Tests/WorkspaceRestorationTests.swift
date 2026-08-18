import Foundation
import XCTest
@testable import iPhoneTerminal

final class WorkspaceRestorationTests: XCTestCase {
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
        XCTAssertFalse(ExternalLaunchURL.matches(URL(string: "clive://resume-or-start?mac=secret")!))
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
}
