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

struct ConnectionStatusPresentation: Equatable {
    let health: ConnectionHealth
    let icon: String
    let text: String
    let accessibilityValue: String
    let certificatePin: String
    let activity: String
    let replayWarning: String?

    static func make(state: SessionClient.State?, deviceName: String?, route: MacRouteKind?) -> Self {
        let name = deviceName ?? "No Mac selected"
        guard let state else {
            return Self(health: .disconnected, icon: "network.slash", text: "Offline", accessibilityValue: "\(name), offline", certificatePin: "Not checked", activity: "No active session", replayWarning: nil)
        }
        switch state {
        case .connecting:
            return Self(health: .connecting, icon: "ellipsis", text: "Connecting", accessibilityValue: "\(name), connecting", certificatePin: "Checking", activity: "Opening session", replayWarning: nil)
        case .reconnecting(let waiting):
            let activity = waiting ? "Waiting for Wi-Fi to resume" : "Resuming session"
            return Self(health: .reconnecting, icon: "arrow.triangle.2.circlepath", text: "Reconnecting", accessibilityValue: "\(name), reconnecting, \(activity.lowercased())", certificatePin: "Verified previously", activity: activity, replayWarning: nil)
        case .active(_, let disposition, let truncated):
            let activity = disposition == .resumed ? "Existing session resumed" : "New session active"
            return Self(health: .connected, icon: "checkmark.circle.fill", text: "Connected", accessibilityValue: "\(name), connected by \(ConnectionPresentation.routeLabel(for: route)), \(activity.lowercased())", certificatePin: "Verified", activity: activity, replayWarning: truncated ? "Some output produced while disconnected was discarded." : nil)
        case .disconnected, .resumeUnavailable, .networkError:
            return Self(health: .disconnected, icon: "network.slash", text: "Offline", accessibilityValue: "\(name), offline", certificatePin: "Verified previously", activity: "Session inactive", replayWarning: nil)
        case .revoked:
            return Self(health: .attention, icon: "lock.slash", text: "Revoked", accessibilityValue: "\(name), access revoked", certificatePin: "Not trusted", activity: "Session blocked", replayWarning: nil)
        case .certificateChanged:
            return Self(health: .attention, icon: "exclamationmark.shield", text: "Certificate changed", accessibilityValue: "\(name), certificate changed, verify locally", certificatePin: "Mismatch", activity: "Connection blocked", replayWarning: nil)
        case .protocolError:
            return Self(health: .attention, icon: "exclamationmark.triangle", text: "Protocol error", accessibilityValue: "\(name), protocol error", certificatePin: "Connection ended safely", activity: "Session ended", replayWarning: nil)
        case .workingDirectoryUnavailable:
            return Self(health: .attention, icon: "folder.badge.questionmark", text: "Directory unavailable", accessibilityValue: "\(name), working directory unavailable", certificatePin: "Verified", activity: "Session not opened", replayWarning: nil)
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
    static func canRun(command: String, state: SessionClient.State?) -> Bool {
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              case .active = state else { return false }
        return true
    }
}

enum TerminalTwoFingerNavigationPolicy {
    static func adjacentIndex(current: Int, count: Int, forward: Bool) -> Int? {
        let adjacent = forward ? current + 1 : current - 1
        return (0..<count).contains(adjacent) ? adjacent : nil
    }
}

enum DrawerRowRevealPolicy {
    static let actionWidth: CGFloat = 56
    static let revealWidth = actionWidth * 2
    static let minimumRowHeight: CGFloat = 48
    static let rowSpacing: CGFloat = 0

    static func toggle(current: UUID?, row: UUID) -> UUID? { current == row ? nil : row }

    static func revealedRow(current: UUID?, row: UUID, translation: CGFloat) -> UUID? {
        if translation < -30 { return row }
        if translation > 30, current == row { return nil }
        return current
    }
}
