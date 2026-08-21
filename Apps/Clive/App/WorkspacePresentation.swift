import Foundation

enum ConnectionHealth: String, Equatable {
    case connecting, connected, reconnecting, disconnected, attention

    var label: String {
        switch self {
        case .connecting: "Connecting"
        case .connected: "Connected"
        case .reconnecting: "Reconnecting"
        case .disconnected: "Disconnected"
        case .attention: "Needs attention"
        }
    }
}

enum ConnectionPresentation {
    static func status(for state: SessionClient.State?) -> ConnectionHealth {
        guard let state else { return .disconnected }
        return switch state {
        case .connecting: ConnectionHealth.connecting
        case .active: ConnectionHealth.connected
        case .reconnecting: ConnectionHealth.reconnecting
        case .disconnected, .resumeUnavailable: ConnectionHealth.disconnected
        case .revoked, .workingDirectoryUnavailable, .certificateChanged, .protocolError, .networkError: ConnectionHealth.attention
        }
    }

    static func routeLabel(for kind: MacRouteKind?) -> String {
        switch kind {
        case .lan: "Local network"
        case .privateVPN: "Private VPN"
        case .publicIPv6: "Direct IPv6"
        case .manualPublicEndpoint: "Public endpoint"
        case nil: "Establishing route"
        }
    }
}

enum FingerprintFormatter {
    static func formatted(_ fingerprint: String) -> String {
        let compact = String(fingerprint.filter(\.isHexDigit)).uppercased()
        var groups: [String] = []
        var start = compact.startIndex
        while start < compact.endIndex {
            let end = compact.index(start, offsetBy: 2, limitedBy: compact.endIndex) ?? compact.endIndex
            groups.append(String(compact[start..<end]))
            start = end
        }
        return groups.joined(separator: ":")
    }
}

enum ShortcutExecutionPolicy {
    static func payload(for command: String) -> Data { Data((command + "\r").utf8) }
}

enum DrawerRowRevealPolicy {
    static let actionWidth: CGFloat = 56
    static let revealWidth = actionWidth * 2

    static func toggle(current: UUID?, row: UUID) -> UUID? { current == row ? nil : row }

    static func revealedRow(current: UUID?, row: UUID, translation: CGFloat) -> UUID? {
        if translation < -30 { return row }
        if translation > 30, current == row { return nil }
        return current
    }
}
