import Foundation

public enum PairingLinkRoute: Equatable, Sendable {
    case pairing(PairingTicket)
    case updateRequired
    case unsupported
    case invalid
}

public enum PairingLinkError: Error, Equatable, Sendable {
    case malformed
}

/// HTTPS envelope for a short-lived QR pairing ticket. The fragment is never
/// included in an HTTP request, protecting the ticket on the missing-app path.
public enum PairingLink {
    public static let domain = "pair.clive.app"
    public static let path = "/pair"
    public static let currentVersion = 1

    public static func makeURL(for ticket: PairingTicket) throws -> URL {
        let payload = try PairingPayload.encode(ticket)
        var components = URLComponents()
        components.scheme = "https"
        components.host = domain
        components.path = path
        components.fragment = "v=\(currentVersion)&ticket=\(payload)"
        guard let url = components.url else { throw PairingLinkError.malformed }
        return url
    }

    public static func route(_ url: URL, supportsCurrentVersion: Bool = true, supportsPlatform: Bool = true, now: Date = .now) -> PairingLinkRoute {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.host?.lowercased() == domain,
              components.path == path,
              components.query == nil else { return .invalid }
        guard supportsPlatform else { return .unsupported }
        guard supportsCurrentVersion else { return .updateRequired }
        guard let fragment = components.fragment else { return .invalid }
        var values: [String: String] = [:]
        for item in fragment.split(separator: "&", omittingEmptySubsequences: false) {
            let parts = item.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2, values[parts[0]] == nil else { return .invalid }
            values[parts[0]] = parts[1]
        }
        guard values.count == 2, values["v"] == String(currentVersion),
              let payload = values["ticket"], let ticket = try? PairingPayload.decode(payload), ticket.expiresAt >= now else { return .invalid }
        return .pairing(ticket)
    }
}
