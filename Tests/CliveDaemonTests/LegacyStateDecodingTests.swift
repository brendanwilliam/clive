import Foundation
import Testing
import CliveCore
@testable import CliveDaemon

@Suite("Legacy daemon state")
struct LegacyStateDecodingTests {
    @Test("daemon state defaults a missing listener port")
    func daemonStateDefaultsMissingListenerPort() throws {
        let data = Data(#"{"macID":"mac","serviceID":"service","remoteEndpoint":null}"#.utf8)

        let state = try JSONDecoder().decode(DaemonState.self, from: data)

        #expect(state.macID == "mac")
        #expect(state.serviceID == "service")
        #expect(state.remoteEndpoint == nil)
        #expect(state.listenerPort == 64236)
    }

    @Test("rendezvous settings reject missing current fields")
    func rendezvousSettingsRejectMissingCurrentFields() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(#"{"enabled":true,"manualEndpoint":null}"#.utf8).write(to: root.appending(path: "cellular.json"))
        let state = DaemonState(macID: "mac", serviceID: "service", remoteEndpoint: nil, listenerPort: 64236)
        let trustStore = try TrustStore(url: root.appending(path: "devices.json"))

        #expect(throws: (any Error).self) {
            try MacRendezvousController(state: state, trustStore: trustStore, baseURL: root)
        }
    }
}
