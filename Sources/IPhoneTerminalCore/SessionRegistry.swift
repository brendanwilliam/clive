import Foundation

public struct TerminalSession: Equatable, Identifiable, Sendable {
    public let id: UUID
    public let deviceID: String
    public let size: TerminalSize
    public let clientSessionID: UUID

    public init(id: UUID = UUID(), deviceID: String, clientSessionID: UUID = UUID(), size: TerminalSize) {
        self.id = id
        self.deviceID = deviceID
        self.size = size
        self.clientSessionID = clientSessionID
    }
}

/// Tracks session ownership independently from network or PTY implementation so revocation
/// can always terminate every connection authenticated by a device certificate.
public actor SessionRegistry {
    private var sessions: [UUID: TerminalSession] = [:]

    public init() {}

    public func open(deviceID: String, clientSessionID: UUID, size: TerminalSize) -> TerminalSession {
        // A duplicate key is a replacement, never a second persistent shell.
        sessions = sessions.filter { !($0.value.deviceID == deviceID && $0.value.clientSessionID == clientSessionID) }
        let session = TerminalSession(deviceID: deviceID, clientSessionID: clientSessionID, size: size)
        sessions[session.id] = session
        return session
    }

    public func close(id: UUID) {
        sessions.removeValue(forKey: id)
    }

    public func sessions(forDeviceID deviceID: String) -> [TerminalSession] {
        sessions.values.filter { $0.deviceID == deviceID }
    }

    public func all() -> [TerminalSession] { Array(sessions.values) }

    @discardableResult
    public func closeAll(forDeviceID deviceID: String) -> [TerminalSession] {
        let removed = sessions(forDeviceID: deviceID)
        for session in removed { sessions.removeValue(forKey: session.id) }
        return removed
    }
}
