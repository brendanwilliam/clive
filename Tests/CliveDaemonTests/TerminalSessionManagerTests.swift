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

    func testReplacementMakesStaleAttachmentUnableToMutateOrCloseSession() throws {
        let process = FakeTerminalProcess()
        let superseded = Box(false)
        let manager = makeManager(process)
        let clientID = UUID(), first = UUID(), second = UUID()
        _ = try attach(manager, clientID: clientID, attachmentID: first, superseded: { superseded.value = true })
        let resumed = try attach(manager, clientID: clientID, attachmentID: second)

        try manager.input(deviceID: "phone", clientSessionID: clientID, attachmentID: first, bytes: Data("stale".utf8))
        manager.resize(deviceID: "phone", clientSessionID: clientID, attachmentID: first, size: TerminalSize(columns: 1, rows: 1))
        manager.close(deviceID: "phone", clientSessionID: clientID, attachmentID: first)
        manager.synchronize()
        try manager.input(deviceID: "phone", clientSessionID: clientID, attachmentID: second, bytes: Data("current".utf8))

        XCTAssertTrue(superseded.value)
        XCTAssertEqual(resumed.disposition, .resumed)
        XCTAssertEqual(process.writes, [Data("current".utf8)])
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

    func testLiveOutputSuspendsUntilNetworkCompletionDropsBelowLowWaterMark() throws {
        let process = FakeTerminalProcess()
        let manager = makeManager(process)
        let completions = Box<[@Sendable () -> Void]>([])
        _ = try attach(manager, clientID: UUID(), attachmentID: UUID(), output: { _, completion in completions.value.append(completion) })

        process.output?(Data(repeating: 1, count: OutputBackpressure.defaultHighWaterMark)); manager.synchronize()
        XCTAssertEqual(process.suspendCount, 1)
        completions.value.removeFirst()(); manager.synchronize()
        XCTAssertEqual(process.resumeCount, 1)
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
            manager.close(deviceID: "phone", clientSessionID: clientID, attachmentID: staleID)
        }
        manager.synchronize()

        XCTAssertEqual(creations.value, 1)
        XCTAssertEqual(process.terminateCount, 0)
        manager.close(deviceID: "phone", clientSessionID: clientID, attachmentID: attachmentID)
        manager.synchronize()
        XCTAssertEqual(process.terminateCount, 1)
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
