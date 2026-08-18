import Foundation
import IPhoneTerminalCore

struct DaemonState: Codable, Sendable {
    let macID: String
    let serviceID: String
    var remoteEndpoint: RemoteEndpoint?

    static func loadOrCreate(url: URL) throws -> DaemonState {
        if FileManager.default.fileExists(atPath: url.path) {
            return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        }
        let state = Self(macID: UUID().uuidString.lowercased(), serviceID: UUID().uuidString.lowercased(), remoteEndpoint: nil)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(state).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return state
    }

    static func updateRemoteEndpoint(url: URL, endpoint: RemoteEndpoint?) throws {
        var state = try loadOrCreate(url: url)
        state.remoteEndpoint = endpoint
        try JSONEncoder().encode(state).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
