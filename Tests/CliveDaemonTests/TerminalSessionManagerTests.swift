import Foundation
import XCTest
@testable import CliveDaemon
import CliveCore

private final class FakeTerminalProcess: TerminalProcess, @unchecked Sendable {
    private(set) var writes: [Data] = []
    private(set) var sizes: [TerminalSize] = []
    private(set) var suspendCount = 0
    private(set) var resumeCount = 0
    private(set) var terminateCount = 0
    var output: ((Data) -> Void)?
    var exit: (() -> Void)?

    func write(_ bytes: Data) throws { writes.append(bytes) }
    func resize(to size: TerminalSize) { sizes.append(size) }
    func suspendOutput() { suspendCount += 1 }
    func resumeOutput() { resumeCount += 1 }
    func terminate() { terminateCount += 1 }
}
private final class Box<Value>: @unchecked Sendable {
    var value: Value
    init(_ value: Value) { self.value = value }
}

final class TerminalSessionManagerTests: XCTestCase {
    private let size = TerminalSize(columns: 80, rows: 24)

    func testSecondAttachmentDoesNotSupersedeFirstAttachment() throws {
        let process = FakeTerminalProcess()
        let superseded = Box(false)
        let manager = makeManager(process)
        let clientID = UUID(), first = UUID(), second = UUID()
        _ = try attach(manager, clientID: clientID, attachmentID: first, superseded: { superseded.value = true })
        let resumed = try attach(manager, clientID: clientID, attachmentID: second)

        try manager.input(deviceID: "phone", clientSessionID: clientID, attachmentID: first, bytes: Data("first".utf8))
        manager.resize(deviceID: "phone", clientSessionID: clientID, attachmentID: first, size: TerminalSize(columns: 1, rows: 1))
        manager.detach(deviceID: "phone", clientSessionID: clientID, attachmentID: first)
        manager.synchronize()
        try manager.input(deviceID: "phone", clientSessionID: clientID, attachmentID: second, bytes: Data("current".utf8))

        XCTAssertFalse(superseded.value)
        XCTAssertEqual(resumed.disposition, .resumed)
        XCTAssertEqual(process.writes, [Data("first".utf8), Data("current".utf8)])
        XCTAssertEqual(process.terminateCount, 0)
    }

    func testDetachedOutputReplaysInOrderAndEvictsOldestBytes() throws {
        let process = FakeTerminalProcess()
        let manager = makeManager(process, replayLimit: 5)
        let clientID = UUID(), attachmentID = UUID()
        _ = try attach(manager, clientID: clientID, attachmentID: attachmentID)
        manager.detach(deviceID: "phone", clientSessionID: clientID, attachmentID: attachmentID)
        manager.synchronize()
        process.output?(Data("abc".utf8)); process.output?(Data("def".utf8)); manager.synchronize()

        let resumed = try attach(manager, clientID: clientID, attachmentID: UUID())

        XCTAssertEqual(String(decoding: resumed.replay, as: UTF8.self), "bcdef")
        XCTAssertTrue(resumed.replayTruncated)
    }

    func testShellExitNotifiesCurrentAttachmentAndTerminatesSession() throws {
        let process = FakeTerminalProcess()
        let manager = makeManager(process)
        let exited = Box(false)
        _ = try attach(manager, clientID: UUID(), attachmentID: UUID(), exited: { exited.value = true })

        process.exit?(); manager.synchronize()

        XCTAssertTrue(exited.value)
        XCTAssertEqual(process.terminateCount, 1)
    }

    func testSlowAttachmentIsEvictedWithoutSuspendingPTY() throws {
        let process = FakeTerminalProcess()
        let manager = makeManager(process)
        let evicted = Box(false)
        _ = try attach(manager, clientID: UUID(), attachmentID: UUID(), output: { _, _ in }, superseded: { evicted.value = true })

        process.output?(Data(repeating: 1, count: OutputBackpressure.defaultHighWaterMark)); manager.synchronize()
        XCTAssertTrue(evicted.value)
        XCTAssertEqual(process.suspendCount, 0)
        XCTAssertEqual(process.resumeCount, 0)
    }

    func testMultipleAttachmentsReceiveOrderedOutputAndInputTransfersResizeOwnership() throws {
        let process = FakeTerminalProcess(); let manager = makeManager(process); let clientID = UUID()
        let first = UUID(), second = UUID(); let firstOutput = Box<[String]>([]), secondOutput = Box<[String]>([])
        _ = try attach(manager, clientID: clientID, attachmentID: first, output: { chunk, done in firstOutput.value.append(String(decoding: chunk.bytes, as: UTF8.self)); done() })
        _ = try attach(manager, clientID: clientID, attachmentID: second, output: { chunk, done in secondOutput.value.append(String(decoding: chunk.bytes, as: UTF8.self)); done() })
        process.output?(Data("a".utf8)); process.output?(Data("b".utf8)); manager.synchronize()
        try manager.input(deviceID: "phone", clientSessionID: clientID, attachmentID: second, bytes: Data("x".utf8))
        manager.resize(deviceID: "phone", clientSessionID: clientID, attachmentID: first, size: TerminalSize(columns: 10, rows: 10))
        manager.resize(deviceID: "phone", clientSessionID: clientID, attachmentID: second, size: TerminalSize(columns: 20, rows: 20)); manager.synchronize()
        XCTAssertEqual(firstOutput.value, ["a", "b"]); XCTAssertEqual(secondOutput.value, ["a", "b"])
        XCTAssertEqual(process.writes, [Data("x".utf8)]); XCTAssertEqual(process.sizes.last, TerminalSize(columns: 20, rows: 20))
    }

    func testExplicitCloseRevocationAndShutdownTerminateOwnedProcesses() throws {
        let first = FakeTerminalProcess(), second = FakeTerminalProcess(), third = FakeTerminalProcess()
        let processes = Box([first, second, third])
        let manager = TerminalSessionManager(registry: SessionRegistry(), processFactory: { _, _, output, exit in
            let process = processes.value.removeFirst(); process.output = output; process.exit = exit; return process
        })
        let firstClient = UUID(), firstAttachment = UUID()
        _ = try attach(manager, clientID: firstClient, attachmentID: firstAttachment)
        _ = try manager.attach(deviceID: "other-phone", clientSessionID: UUID(), size: size, workingDirectory: nil, attachmentID: UUID(), output: { _, completion in completion() }, onSuperseded: {}, onShellExit: {})
        _ = try attach(manager, clientID: UUID(), attachmentID: UUID())

        manager.close(deviceID: "phone", clientSessionID: firstClient, attachmentID: firstAttachment)
        manager.closeAll(deviceID: "other-phone")
        manager.synchronize()
        manager.shutdown()

        XCTAssertEqual([first.terminateCount, second.terminateCount, third.terminateCount], [1, 1, 1])
    }

    func testDetachedSessionExpiresAfterGraceInterval() throws {
        let process = FakeTerminalProcess()
        let manager = TerminalSessionManager(registry: SessionRegistry(), graceInterval: 0.01, processFactory: { _, _, output, exit in
            process.output = output; process.exit = exit; return process
        })
        let clientID = UUID(), attachmentID = UUID()
        _ = try attach(manager, clientID: clientID, attachmentID: attachmentID)
        manager.detach(deviceID: "phone", clientSessionID: clientID, attachmentID: attachmentID)

        let deadline = Date().addingTimeInterval(1)
        while process.terminateCount == 0 && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }

        XCTAssertEqual(process.terminateCount, 1)
    }

    func testRepeatedRouteRacesKeepOnePTYAndOneLogicalSession() throws {
        let process = FakeTerminalProcess()
        let creations = Box(0)
        let manager = TerminalSessionManager(registry: SessionRegistry(), processFactory: { _, _, output, exit in
            creations.value += 1; process.output = output; process.exit = exit; return process
        })
        let clientID = UUID()
        var attachmentID = UUID()
        let original = try attach(manager, clientID: clientID, attachmentID: attachmentID)

        for _ in 0..<20 {
            let staleID = attachmentID
            attachmentID = UUID()
            let resumed = try attach(manager, clientID: clientID, attachmentID: attachmentID)
            XCTAssertEqual(resumed.serverSessionID, original.serverSessionID)
            XCTAssertEqual(resumed.disposition, .resumed)
            manager.detach(deviceID: "phone", clientSessionID: clientID, attachmentID: staleID)
        }
        manager.synchronize()

        XCTAssertEqual(creations.value, 1)
        XCTAssertEqual(process.terminateCount, 0)
        manager.close(deviceID: "phone", clientSessionID: clientID, attachmentID: attachmentID)
        manager.synchronize()
        XCTAssertEqual(process.terminateCount, 1)
    }

    func testAttachExistingNeverCreatesReplacementPTY() throws {
        let process = FakeTerminalProcess(), creations = Box(0)
        let manager = TerminalSessionManager(registry: SessionRegistry(), processFactory: { _, _, output, exit in creations.value += 1; process.output = output; process.exit = exit; return process })
        let original = try attach(manager, clientID: UUID(), attachmentID: UUID())
        let resumed = try manager.attachExisting(deviceID: "phone", serverSessionID: original.serverSessionID, size: size, attachmentID: UUID(), attachmentKind: .macCLI, lastReceivedOffset: 0, output: { _, done in done() }, onDetached: { _ in }, onShellExit: {})
        let unavailable = try manager.attachExisting(deviceID: "phone", serverSessionID: UUID(), size: size, attachmentID: UUID(), attachmentKind: .iPhone, lastReceivedOffset: 0, output: { _, done in done() }, onDetached: { _ in }, onShellExit: {})
        XCTAssertEqual(resumed?.serverSessionID, original.serverSessionID)
        XCTAssertNil(unavailable); XCTAssertEqual(creations.value, 1)
    }

    func testCatalogSubscriptionTracksAttachmentsWithoutCountingSubscriber() throws {
        let process = FakeTerminalProcess(), manager = makeManager(process), snapshots = Box<[[SessionDescriptor]]>([])
        manager.subscribe(deviceID: "phone", identifier: UUID()) { snapshots.value.append($0) }; manager.synchronize()
        let client = UUID(), attachment = UUID(); _ = try attach(manager, clientID: client, attachmentID: attachment); manager.synchronize()
        manager.detach(deviceID: "phone", clientSessionID: client, attachmentID: attachment); manager.synchronize()
        XCTAssertEqual(snapshots.value.first, [])
        XCTAssertEqual(snapshots.value.dropFirst().first?.first?.attachmentCount, 1)
        XCTAssertEqual(snapshots.value.last?.first?.attachmentCount, 0)
    }

    func testNonOwnerViewportIsStoredAndAppliedWhenInputClaimsOwnership() throws {
        let process = FakeTerminalProcess(), manager = makeManager(process), client = UUID(), first = UUID(), second = UUID()
        _ = try attach(manager, clientID: client, attachmentID: first)
        _ = try attach(manager, clientID: client, attachmentID: second)
        let secondSize = TerminalSize(columns: 120, rows: 50)
        manager.resize(deviceID: "phone", clientSessionID: client, attachmentID: second, size: secondSize); manager.synchronize()
        try manager.input(deviceID: "phone", clientSessionID: client, attachmentID: second, bytes: Data("x".utf8))
        XCTAssertEqual(process.sizes.last, secondSize)
    }

    func testResizeOwnerLossFallsBackToMostRecentlyActiveAttachment() throws {
        let process = FakeTerminalProcess(), manager = makeManager(process), client = UUID()
        let first = UUID(), second = UUID(), third = UUID()
        _ = try attach(manager, clientID: client, attachmentID: first)
        _ = try attach(manager, clientID: client, attachmentID: second)
        _ = try attach(manager, clientID: client, attachmentID: third)
        let secondSize = TerminalSize(columns: 111, rows: 33)
        manager.resize(deviceID: "phone", clientSessionID: client, attachmentID: second, size: secondSize)
        manager.claimResize(deviceID: "phone", clientSessionID: client, attachmentID: second)
        manager.claimResize(deviceID: "phone", clientSessionID: client, attachmentID: third)
        manager.detach(deviceID: "phone", clientSessionID: client, attachmentID: third)
        manager.synchronize()
        XCTAssertEqual(process.sizes.last, secondSize)
    }

    private func makeManager(_ process: FakeTerminalProcess, replayLimit: Int = 1_048_576) -> TerminalSessionManager {
        TerminalSessionManager(registry: SessionRegistry(), replayLimit: replayLimit, processFactory: { _, _, output, exit in
            process.output = output; process.exit = exit; return process
        })
    }

    @discardableResult private func attach(
        _ manager: TerminalSessionManager,
        clientID: UUID,
        attachmentID: UUID,
        output: @escaping TerminalSessionManager.Output = { _, completion in completion() },
        superseded: @escaping @Sendable () -> Void = {},
        exited: @escaping @Sendable () -> Void = {}
    ) throws -> TerminalSessionManager.Attachment {
        try manager.attach(deviceID: "phone", clientSessionID: clientID, size: size, workingDirectory: nil, attachmentID: attachmentID, output: output, onSuperseded: superseded, onShellExit: exited)
    }
}
