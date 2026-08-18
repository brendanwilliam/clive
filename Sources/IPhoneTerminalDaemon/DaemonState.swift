import Foundation

struct DaemonState: Codable, Sendable {
    let macID: String
    let serviceID: String

    static func loadOrCreate(url: URL) throws -> DaemonState {
        if FileManager.default.fileExists(atPath: url.path) {
            return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        }
        let state = Self(macID: UUID().uuidString.lowercased(), serviceID: UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(state).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return state
    }
}
