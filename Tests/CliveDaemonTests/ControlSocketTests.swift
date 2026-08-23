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
}
