import CryptoKit
import Foundation

public struct PairingTicket: Codable, Equatable, Sendable {
    public let endpoint: String
    public let port: UInt16
    public let protocolVersion: UInt16
    public let expiresAt: Date
    public let oneTimeSecret: String
    /// SHA-256 fingerprint of the persistent daemon identity used for pairing and sessions.
    public let daemonCertificateFingerprint: String

    public init(endpoint: String, port: UInt16, expiresAt: Date, oneTimeSecret: String, daemonCertificateFingerprint: String, protocolVersion: UInt16 = ProtocolFrame.version) {
        self.endpoint = endpoint
        self.port = port
        self.protocolVersion = protocolVersion
        self.expiresAt = expiresAt
        self.oneTimeSecret = oneTimeSecret
        self.daemonCertificateFingerprint = daemonCertificateFingerprint
    }
}

public struct PairingRequest: Codable, Equatable, Sendable {
    public let oneTimeSecret: String
    public let deviceID: String
    public let deviceName: String
    /// DER-encoded, self-signed device certificate. The Mac pins its fingerprint after approval.
    public let certificate: Data

    public init(oneTimeSecret: String, deviceID: String, deviceName: String, certificate: Data) {
        self.oneTimeSecret = oneTimeSecret
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.certificate = certificate
    }
}

public struct PairingAcceptance: Codable, Equatable, Sendable {
    public let macID: String
    public let displayName: String
    public let serviceID: String
    public let certificate: Data

    public init(macID: String, displayName: String, serviceID: String, certificate: Data) {
        self.macID = macID
        self.displayName = displayName
        self.serviceID = serviceID
        self.certificate = certificate
    }
}

public enum PairingPayload {
    /// URL-safe, unpadded JSON so the same ticket can be passed to a QR encoder and scanner.
    public static func encode(_ ticket: PairingTicket) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(ticket).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func decode(_ payload: String) throws -> PairingTicket {
        let allowedCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        guard payload.unicodeScalars.allSatisfy({ allowedCharacters.contains($0) }) else {
            throw PairingPayloadError.malformed
        }
        let remainder = payload.count % 4
        let padded = payload.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/") + String(repeating: "=", count: remainder == 0 ? 0 : 4 - remainder)
        guard let data = Data(base64Encoded: padded) else { throw PairingPayloadError.malformed }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(PairingTicket.self, from: data)
        } catch {
            throw PairingPayloadError.malformed
        }
    }
}

public enum PairingPayloadError: Error, Equatable, Sendable {
    case malformed
}

public enum PairingError: Error, Equatable, Sendable {
    case expired
    case consumed
    case secretMismatch
    case malformedRequest
    case rejected
}

public actor PairingCoordinator {
    private let secret: PairingSecret
    private let trustStore: TrustStore
    private let macID: String
    private let macCertificate: Data
    private let displayName: String
    private let serviceID: String
    private let approval: @Sendable (PairingRequest) async -> Bool
    private let didPair: @Sendable () async -> Void
    private var requestInProgress = false

    public init(secret: PairingSecret, trustStore: TrustStore, macID: String, displayName: String, serviceID: String, macCertificate: Data, approval: @escaping @Sendable (PairingRequest) async -> Bool, didPair: @escaping @Sendable () async -> Void = {}) {
        self.secret = secret
        self.trustStore = trustStore
        self.macID = macID
        self.macCertificate = macCertificate
        self.displayName = displayName
        self.serviceID = serviceID
        self.approval = approval
        self.didPair = didPair
    }

    public func accept(_ request: PairingRequest, now: Date = .now) async throws -> PairingAcceptance {
        guard !requestInProgress else { throw PairingError.consumed }
        requestInProgress = true
        defer { requestInProgress = false }
        try await secret.validate(request: request, now: now)
        guard await approval(request) else { throw PairingError.rejected }
        let device = PairedDevice(id: request.deviceID, displayName: request.deviceName, certificateFingerprint: Fingerprint.sha256(of: request.certificate), createdAt: now)
        try await trustStore.upsert(device)
        try await secret.consume(secret: request.oneTimeSecret, now: now)
        await didPair()
        return PairingAcceptance(macID: macID, displayName: displayName, serviceID: serviceID, certificate: macCertificate)
    }
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

    public func validate(request: PairingRequest, now: Date = .now) throws {
        guard !request.deviceID.isEmpty, !request.deviceName.isEmpty, !request.certificate.isEmpty else {
            throw PairingError.malformedRequest
        }
        try verify(secret: request.oneTimeSecret, now: now)
    }

    public func verify(secret: String, now: Date = .now) throws {
        guard now <= ticket.expiresAt else { throw PairingError.expired }
        guard !consumed else { throw PairingError.consumed }
        guard secret == ticket.oneTimeSecret else { throw PairingError.secretMismatch }
    }
}

public enum ProtocolPayloadError: Error, Equatable, Sendable {
    case malformed
}

public enum ProtocolPayload {
    public static func encode<Value: Encodable>(_ value: Value) throws -> Data {
        try JSONEncoder().encode(value)
    }

    public static func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw ProtocolPayloadError.malformed
        }
    }
}

public struct PairedIPhone: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let displayName: String
    public let certificateFingerprint: String
    public let createdAt: Date

    public init(id: String, displayName: String, certificateFingerprint: String, createdAt: Date) {
        self.id = id; self.displayName = displayName
        self.certificateFingerprint = certificateFingerprint; self.createdAt = createdAt
    }
}


public struct PairedMac: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let displayName: String
    public let serviceID: String
    public let certificateFingerprint: String
    public let createdAt: Date

    public init(id: String, displayName: String, serviceID: String, certificateFingerprint: String, createdAt: Date) {
        self.id = id; self.displayName = displayName; self.serviceID = serviceID
        self.certificateFingerprint = certificateFingerprint; self.createdAt = createdAt
    }
}

public typealias PairedDevice = PairedIPhone

public enum Fingerprint {
    public static func sha256(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
