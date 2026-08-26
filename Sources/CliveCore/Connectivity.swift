import Foundation

/// The route classes supported by the connectivity orchestrator, in preference order.
public enum RouteKind: Int, Codable, CaseIterable, Comparable, Sendable {
    case lan = 0
    case privateVPN = 1
    case directWANCellular = 2
    case relay = 3

    public static func < (lhs: RouteKind, rhs: RouteKind) -> Bool { lhs.rawValue < rhs.rawValue }
}

public enum RouteAuthorization: String, Codable, Sendable {
    case unauthorized
    case authorized
}

public enum RouteHealth: String, Codable, Sendable {
    case unknown
    case healthy
    case degraded
    case failed
}

public enum RouteState: String, Codable, Sendable {
    case unavailable
    case available
    case selected
    case failed
}

/// A transport-independent description of one possible path to the Mac daemon.
public struct RouteCandidate: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let kind: RouteKind
    public let host: String
    public let port: UInt16
    public let availability: Bool
    public let authorization: RouteAuthorization
    public let lastVerifiedAt: Date?
    public let expiresAt: Date?
    public let health: RouteHealth

    public init(
        id: UUID = UUID(),
        kind: RouteKind,
        host: String,
        port: UInt16,
        availability: Bool = true,
        authorization: RouteAuthorization = .authorized,
        lastVerifiedAt: Date? = nil,
        expiresAt: Date? = nil,
        health: RouteHealth = .unknown
    ) {
        self.id = id
        self.kind = kind
        self.host = host
        self.port = port
        self.availability = availability
        self.authorization = authorization
        self.lastVerifiedAt = lastVerifiedAt
        self.expiresAt = expiresAt
        self.health = health
    }

    public func isUsable(at now: Date) -> Bool {
        availability && authorization == .authorized && health == .healthy && (expiresAt == nil || now < expiresAt!)
    }

    public func state(at now: Date, selected: Bool = false) -> RouteState {
        if health == .failed { return .failed }
        if !isUsable(at: now) { return .unavailable }
        return selected ? .selected : .available
    }
}

public protocol RouteProvider: Sendable {
    var kind: RouteKind { get }
    func candidates() async -> [RouteCandidate]
}

public enum RouteSelectionDecision: Equatable, Sendable {
    case noChange
    case selected(RouteCandidate)
    case handedOff(from: UUID, to: RouteCandidate)
    case lostSelection
}

/// Deterministic route selection. Network probing is performed by providers; this
/// type only applies ranking, debounce, hysteresis, and selection transitions.
public struct ConnectivityRouteStateMachine: Sendable {
    public static let higherPriorityDebounce: TimeInterval = 5
    public static let candidateStaleness: TimeInterval = 30
    public static let retryBaseDelay: TimeInterval = 1
    public static let retryMaximumDelay: TimeInterval = 60

    public private(set) var selectedRouteID: UUID?
    private var pendingRouteID: UUID?
    private var pendingSince: Date?

    public init(selectedRouteID: UUID? = nil) {
        self.selectedRouteID = selectedRouteID
    }

    public mutating func evaluate(_ candidates: [RouteCandidate], at now: Date) -> RouteSelectionDecision {
        let usable = candidates.filter { $0.isUsable(at: now) }.sorted { $0.kind < $1.kind }

        guard let selectedRouteID else {
            pendingRouteID = nil
            pendingSince = nil
            guard let best = usable.first else { return .lostSelection }
            self.selectedRouteID = best.id
            return .selected(best)
        }

        guard let current = candidates.first(where: { $0.id == selectedRouteID }), current.isUsable(at: now) else {
            self.selectedRouteID = usable.first?.id
            pendingRouteID = nil
            pendingSince = nil
            guard let replacement = usable.first else { return .lostSelection }
            return .handedOff(from: selectedRouteID, to: replacement)
        }

        guard let better = usable.first, better.kind < current.kind else {
            pendingRouteID = nil
            pendingSince = nil
            return .noChange
        }

        if pendingRouteID != better.id {
            pendingRouteID = better.id
            pendingSince = now
            return .noChange
        }
        guard let pendingSince, now.timeIntervalSince(pendingSince) >= Self.higherPriorityDebounce else { return .noChange }
        self.selectedRouteID = better.id
        self.pendingRouteID = nil
        self.pendingSince = nil
        return .handedOff(from: current.id, to: better)
    }
}
