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

final class PTYProcessTests: XCTestCase {
    func testCodexScriptQuotesArgumentsAndReturnsToShell() {
        let script = PTYProcess.codexScript(arguments: ["resume", "a b", "it's-safe"])
        XCTAssertTrue(script.contains("'resume' 'a b' 'it'\\''s-safe'"))
        XCTAssertTrue(script.hasSuffix("exec zsh -l"))
        XCTAssertTrue(script.contains("command -v codex"))
    }

    func testCodexSessionIsClassifiedAndCanHandoffFromMacToIPhone() throws {
        let process = FakeTerminalProcess()
        let directories = Box<[String?]>([])
        let manager = TerminalSessionManager(
            registry: SessionRegistry(),
            processFactory: { _, _, output, exit in
                process.output = output; process.exit = exit; return process
            },
            codexProcessFactory: { _, directory, output, exit in
                directories.value.append(directory)
                process.output = output; process.exit = exit; return process
            }
        )
        let clientID = UUID()
        let original = try manager.attach(
            deviceID: "phone", clientSessionID: clientID, size: TerminalSize(columns: 80, rows: 24), workingDirectory: "/tmp",
            command: .codex(arguments: ["resume", "run-1"], label: "Project work"),
            attachmentID: UUID(), attachmentKind: .macCLI, output: { _, done in done() },
            onSuperseded: {}, onShellExit: {}
        )

        let descriptor = manager.descriptors(deviceID: "phone").first
        XCTAssertEqual(descriptor?.kind, .codex)
        XCTAssertEqual(descriptor?.label, "Project work")
        XCTAssertEqual(directories.value, ["/tmp"])

        let handoff = try manager.attachExisting(
            deviceID: "phone", serverSessionID: original.serverSessionID, size: TerminalSize(columns: 80, rows: 24),
            attachmentID: UUID(), attachmentKind: .iPhone, lastReceivedOffset: 0,
            output: { _, done in done() }, onDetached: { _ in }, onShellExit: {}
        )
        XCTAssertEqual(handoff?.disposition, .resumed)
        XCTAssertEqual(manager.descriptors(deviceID: "phone").first?.attachmentCount, 1)
        XCTAssertEqual(process.terminateCount, 0)
    }
}

final class TerminalSessionManagerTests: XCTestCase {
    private let size = TerminalSize(columns: 80, rows: 24)

    func testSameEndpointReconnectReplacesExistingAttachment() throws {
        let process = FakeTerminalProcess()
        let superseded = Box(false)
        let manager = makeManager(process)
        let clientID = UUID(), first = UUID(), second = UUID()
        _ = try attach(manager, clientID: clientID, attachmentID: first, superseded: { superseded.value = true })
        let resumed = try attach(manager, clientID: clientID, attachmentID: second)

        try manager.input(deviceID: "phone", clientSessionID: clientID, attachmentID: second, bytes: Data("current".utf8))
        manager.synchronize()

        XCTAssertTrue(superseded.value)
        XCTAssertEqual(resumed.disposition, .resumed)
        XCTAssertGreaterThan(resumed.generation, 1)
        XCTAssertEqual(manager.descriptors(deviceID: "phone").first?.attachmentCount, 1)
        XCTAssertEqual(process.writes, [Data("current".utf8)])
        XCTAssertEqual(process.terminateCount, 0)
    }

    func testDifferentEndpointCannotAttachToAnAttachedSession() throws {
        let manager = makeManager(FakeTerminalProcess())
        let original = try attach(manager, clientID: UUID(), attachmentID: UUID())

        XCTAssertThrowsError(try manager.attachExisting(deviceID: "phone", serverSessionID: original.serverSessionID, size: size, attachmentID: UUID(), attachmentKind: .macCLI, lastReceivedOffset: 0, output: { _, done in done() }, onDetached: { _ in }, onShellExit: {})) { error in
            XCTAssertEqual(error as? TerminalSessionManager.AttachmentError, .attachedByDifferentEndpoint)
            XCTAssertEqual(error.localizedDescription, "The requested session is still attached to an active terminal on a different endpoint. Disconnect it before trying again.")
        }
        XCTAssertEqual(manager.descriptors(deviceID: "phone").first?.attachmentCount, 1)
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

    func testTerminalInputExecutesInPTYAndReturnsShellOutputAndErrors() throws {
        let manager = TerminalSessionManager(registry: SessionRegistry())
        let clientID = UUID(), attachmentID = UUID()
        let marker = "clive-command-\(UUID().uuidString)"
        let received = Box(Data())
        _ = try attach(manager, clientID: clientID, attachmentID: attachmentID, output: { chunk, completion in
            received.value.append(chunk.bytes)
            completion()
        })
        defer { manager.close(deviceID: "phone", clientSessionID: clientID, attachmentID: attachmentID); manager.synchronize() }

        try manager.input(deviceID: "phone", clientSessionID: clientID, attachmentID: attachmentID, bytes: Data("printf '%s\\n' '\(marker)'\r".utf8))

        let deadline = Date().addingTimeInterval(5)
        while !String(decoding: received.value, as: UTF8.self).contains(marker), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }

        XCTAssertTrue(String(decoding: received.value, as: UTF8.self).contains(marker), "Typed command output did not return from the shell.")

        let diagnostic = "clive-shell-diagnostic-\(UUID().uuidString)"
        try manager.input(deviceID: "phone", clientSessionID: clientID, attachmentID: attachmentID, bytes: Data("printf '%s\\n' '\(diagnostic)' >&2\r".utf8))
        let diagnosticDeadline = Date().addingTimeInterval(5)
        while !String(decoding: received.value, as: UTF8.self).contains(diagnostic), Date() < diagnosticDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }

        XCTAssertTrue(String(decoding: received.value, as: UTF8.self).contains(diagnostic), "Shell stderr should be returned to the terminal.")
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

    func testReplacementAttachmentReceivesTerminalOutputAndInput() throws {
        let process = FakeTerminalProcess(); let manager = makeManager(process); let clientID = UUID()
        let first = UUID(), second = UUID(); let firstOutput = Box<[String]>([]), secondOutput = Box<[String]>([])
        _ = try attach(manager, clientID: clientID, attachmentID: first, output: { chunk, done in firstOutput.value.append(String(decoding: chunk.bytes, as: UTF8.self)); done() })
        _ = try attach(manager, clientID: clientID, attachmentID: second, output: { chunk, done in secondOutput.value.append(String(decoding: chunk.bytes, as: UTF8.self)); done() })
        process.output?(Data("a".utf8)); process.output?(Data("b".utf8)); manager.synchronize()
        try manager.input(deviceID: "phone", clientSessionID: clientID, attachmentID: second, bytes: Data("x".utf8))
        manager.resize(deviceID: "phone", clientSessionID: clientID, attachmentID: first, size: TerminalSize(columns: 10, rows: 10))
        manager.resize(deviceID: "phone", clientSessionID: clientID, attachmentID: second, size: TerminalSize(columns: 20, rows: 20)); manager.synchronize()
        XCTAssertEqual(firstOutput.value, []); XCTAssertEqual(secondOutput.value, ["a", "b"])
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

    func testRepeatedDisconnectCleanupLeavesSessionAvailableForLocalResume() throws {
        let process = FakeTerminalProcess()
        let manager = TerminalSessionManager(registry: SessionRegistry(), graceInterval: 60, processFactory: { _, _, output, exit in
            process.output = output; process.exit = exit; return process
        })
        let clientID = UUID()
        let originalAttachment = UUID()
        let original = try attach(manager, clientID: clientID, attachmentID: originalAttachment)

        // A crashed local control socket can report disconnect more than once. The
        // cleanup must release only its attachment and retain the underlying PTY.
        manager.detach(deviceID: "phone", clientSessionID: clientID, attachmentID: originalAttachment)
        manager.detach(deviceID: "phone", clientSessionID: clientID, attachmentID: originalAttachment)
        manager.synchronize()

        XCTAssertEqual(manager.descriptors(deviceID: "phone").first?.attachmentCount, 0)
        let resumed = try manager.attachExisting(
            deviceID: "phone",
            serverSessionID: original.serverSessionID,
            size: size,
            attachmentID: UUID(),
            attachmentKind: .macCLI,
            lastReceivedOffset: 0,
            output: { _, completion in completion() },
            onDetached: { _ in },
            onShellExit: {}
        )

        XCTAssertEqual(resumed?.serverSessionID, original.serverSessionID)
        XCTAssertEqual(resumed?.disposition, .resumed)
        XCTAssertEqual(manager.descriptors(deviceID: "phone").first?.attachmentCount, 1)
        XCTAssertEqual(process.terminateCount, 0)
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
        let resumed = try manager.attachExisting(deviceID: "phone", serverSessionID: original.serverSessionID, size: size, attachmentID: UUID(), attachmentKind: .iPhone, lastReceivedOffset: 0, output: { _, done in done() }, onDetached: { _ in }, onShellExit: {})
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

    func testBulkTerminationOnlyEndsOwnedKnownSessions() throws {
        let first = FakeTerminalProcess(), other = FakeTerminalProcess()
        let processes = Box([first, other])
        let manager = TerminalSessionManager(registry: SessionRegistry(), processFactory: { _, _, output, exit in
            let process = processes.value.removeFirst(); process.output = output; process.exit = exit; return process
        })
        let owned = try attach(manager, clientID: UUID(), attachmentID: UUID())
        let foreign = try manager.attach(deviceID: "other-phone", clientSessionID: UUID(), size: size, workingDirectory: nil, attachmentID: UUID(), output: { _, done in done() }, onSuperseded: {}, onShellExit: {})
        let terminated = manager.endMany(deviceID: "phone", serverSessionIDs: [owned.serverSessionID, foreign.serverSessionID, UUID()])
        XCTAssertEqual(terminated, [owned.serverSessionID])
        XCTAssertEqual(first.terminateCount, 1)
        XCTAssertEqual(other.terminateCount, 0)
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
