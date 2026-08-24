import Foundation
import Testing
import CliveCore
@testable import CliveDaemon

@Suite("Control socket")
struct ControlSocketTests {
    @Test("filters detached sessions for CLI recovery")
    func filtersDetachedSessionsForRecovery() {
        let detached = SessionDescriptor(id: UUID(), attachmentCount: 0, resizeOwner: nil, outputOffset: 12)
        let attached = SessionDescriptor(id: UUID(), attachmentCount: 1, resizeOwner: .iPhone, outputOffset: 24)

        #expect(CliveDaemon.detachedSessions([attached, detached]) == [detached])
    }

    @Test("selects an active session from the interactive attach picker")
    func selectsActiveSessionForAttach() {
        let first = SessionDescriptor(id: UUID(), attachmentCount: 0, resizeOwner: nil, outputOffset: 0)
        let second = SessionDescriptor(id: UUID(), attachmentCount: 1, resizeOwner: .macCLI, outputOffset: 20)

        #expect(CliveDaemon.session(at: "2", in: [first, second]) == second)
        #expect(CliveDaemon.session(at: "0", in: [first, second]) == nil)
        #expect(CliveDaemon.session(at: "q", in: [first, second]) == nil)
    }

    @Test("reset refuses an active daemon and removes only configured local state after confirmation")
    func resetRequiresConfirmationAndPreservesUnrelatedFiles() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let stateDirectory = root.appending(path: "clive", directoryHint: .isDirectory)
        let unrelatedFile = root.appending(path: "keep.txt")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        try Data("state".utf8).write(to: stateDirectory.appending(path: "daemon.json"))
        try Data("keep".utf8).write(to: unrelatedFile)
        let paths = RuntimePaths(baseURL: stateDirectory)

        #expect(throws: (any Error).self) {
            try CliveDaemon.resetLocalState(paths: paths, daemonIsRunning: true, confirmed: true)
        }
        #expect(FileManager.default.fileExists(atPath: stateDirectory.path))
        #expect(try CliveDaemon.resetLocalState(paths: paths, daemonIsRunning: false, confirmed: false) == false)
        #expect(FileManager.default.fileExists(atPath: stateDirectory.path))
        #expect(try CliveDaemon.resetLocalState(paths: paths, daemonIsRunning: false, confirmed: true))
        #expect(!FileManager.default.fileExists(atPath: stateDirectory.path))
        #expect(FileManager.default.fileExists(atPath: unrelatedFile.path))
    }

    @Test("accepts repeated clients without blocking its dispatch queue")
    func acceptsRepeatedClients() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let socketURL = directory.appending(path: "control.sock")
        let server = try ControlSocketServer(url: socketURL) { _, channel in
            try? channel.send(ControlResponse(success: true))
        }
        server.start()
        defer {
            server.stop()
            try? FileManager.default.removeItem(at: directory)
        }

        for _ in 0..<50 {
            let channel = try ControlSocketClient.connect(url: socketURL)
            try channel.send(ControlRequest(command: .status))
            #expect(try channel.readResponse().success)
        }
    }

    @Test("stopping a server preserves a replacement at its socket path")
    func stopPreservesReplacementSocketPath() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let socketURL = directory.appending(path: "control.sock")
        let server = try ControlSocketServer(url: socketURL) { _, _ in }
        server.start()
        defer { try? FileManager.default.removeItem(at: directory) }

        try FileManager.default.removeItem(at: socketURL)
        let replacement = Data("replacement".utf8)
        try replacement.write(to: socketURL)

        server.stop()

        #expect(try Data(contentsOf: socketURL) == replacement)
    }
}
