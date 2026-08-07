import CryptoKit
import Foundation

public struct PairingTicket: Codable, Equatable, Sendable {
    public let endpoint: String
    public let port: UInt16
    public let protocolVersion: UInt16
    public let expiresAt: Date
    public let oneTimeSecret: String
    /// SHA-256 fingerprint of the ephemeral TLS identity used only for this pairing exchange.
    public let pairingCertificateFingerprint: String

    public init(endpoint: String, port: UInt16, expiresAt: Date, oneTimeSecret: String, pairingCertificateFingerprint: String, protocolVersion: UInt16 = ProtocolFrame.version) {
        self.endpoint = endpoint
        self.port = port
        self.protocolVersion = protocolVersion
        self.expiresAt = expiresAt
        self.oneTimeSecret = oneTimeSecret
        self.pairingCertificateFingerprint = pairingCertificateFingerprint
    }
}

public enum PairingError: Error, Equatable, Sendable {
    case expired
    case consumed
    case secretMismatch
}

public actor PairingSecret {
    public let ticket: PairingTicket
    private var consumed = false

    public init(ticket: PairingTicket) { self.ticket = ticket }

    public func consume(secret: String, now: Date = .now) throws {
        guard now <= ticket.expiresAt else { throw PairingError.expired }
        guard !consumed else { throw PairingError.consumed }
        guard secret == ticket.oneTimeSecret else { throw PairingError.secretMismatch }
        consumed = true
    }
}

public struct PairedDevice: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let displayName: String
    public let certificateFingerprint: String
    public let createdAt: Date
}

public enum Fingerprint {
    public static func sha256(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
