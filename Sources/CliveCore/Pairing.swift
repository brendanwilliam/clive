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
    public let remoteEndpoint: RemoteEndpoint?

    public init(endpoint: String, port: UInt16, expiresAt: Date, oneTimeSecret: String, daemonCertificateFingerprint: String, remoteEndpoint: RemoteEndpoint? = nil, protocolVersion: UInt16 = ProtocolFrame.version) {
        self.endpoint = endpoint
        self.port = port
        self.protocolVersion = protocolVersion
        self.expiresAt = expiresAt
        self.oneTimeSecret = oneTimeSecret
        self.daemonCertificateFingerprint = daemonCertificateFingerprint
        self.remoteEndpoint = remoteEndpoint
    }
}

/// Routing metadata supplied by the Mac owner. TLS certificate pinning remains the authority.
public struct RemoteEndpoint: Codable, Equatable, Sendable {
    public let host: String
    public let port: UInt16
    public init(host: String, port: UInt16) { self.host = host; self.port = port }
}

public struct PairingRequest: Codable, Equatable, Sendable {
    public let oneTimeSecret: String
    public let deviceID: String
    public let deviceName: String
    /// DER-encoded, self-signed device certificate. The Mac pins its fingerprint after approval.
    public let certificate: Data
    public let rendezvousCapability: RendezvousCapability?

    public init(oneTimeSecret: String, deviceID: String, deviceName: String, certificate: Data, rendezvousCapability: RendezvousCapability? = nil) {
        self.oneTimeSecret = oneTimeSecret
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.certificate = certificate
        self.rendezvousCapability = rendezvousCapability
    }
}

public struct PairingAcceptance: Codable, Equatable, Sendable {
    public let macID: String
    public let displayName: String
    public let serviceID: String
    public let certificate: Data
    public let rendezvousCapability: RendezvousCapability?

    public init(macID: String, displayName: String, serviceID: String, certificate: Data, rendezvousCapability: RendezvousCapability? = nil) {
        self.macID = macID
        self.displayName = displayName
        self.serviceID = serviceID
        self.certificate = certificate
        self.rendezvousCapability = rendezvousCapability
    }
}

public enum PairingPayload {
    private static let v2Prefix = "CL2:"
    private static let base45Alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ $%*+-./:")

    /// Encodes a compact binary record using QR alphanumeric mode.
    public static func encode(_ ticket: PairingTicket) throws -> String {
        guard ticket.protocolVersion == ProtocolFrame.version,
              let secret = base64URLDecode(ticket.oneTimeSecret), secret.count == 32,
              let fingerprint = hexDecode(ticket.daemonCertificateFingerprint), fingerprint.count == 32,
              let endpoint = ticket.endpoint.data(using: .utf8), !endpoint.isEmpty, endpoint.count <= 255,
              ticket.port > 0 else { throw PairingPayloadError.malformed }
        var record = Data([2]); record.appendUInt16(ticket.protocolVersion)
        record.appendUInt64(UInt64(ticket.expiresAt.timeIntervalSince1970))
        record.append(UInt8(endpoint.count)); record.append(endpoint); record.appendUInt16(ticket.port)
        record.append(secret); record.append(fingerprint)
        if let remote = ticket.remoteEndpoint {
            guard let host = remote.host.data(using: .utf8), !host.isEmpty, host.count <= 255, remote.port > 0 else { throw PairingPayloadError.malformed }
            record.append(1); record.append(UInt8(host.count)); record.append(host); record.appendUInt16(remote.port)
        } else { record.append(0) }
        return v2Prefix + base45Encode(record)
    }

    public static func decode(_ payload: String) throws -> PairingTicket {
        guard payload.hasPrefix(v2Prefix) else { throw PairingPayloadError.malformed }
        return try decodeV2(String(payload.dropFirst(v2Prefix.count)))
    }

    private static func decodeV2(_ encoded: String) throws -> PairingTicket {
        let data = try base45Decode(encoded); var offset = 0
        func take(_ count: Int) throws -> Data { guard count >= 0, offset + count <= data.count else { throw PairingPayloadError.malformed }; defer { offset += count }; return data.subdata(in: offset..<(offset + count)) }
        func byte() throws -> UInt8 { try take(1)[0] }
        guard try byte() == 2 else { throw PairingPayloadError.malformed }
        let versionData = try take(2); let protocolVersion = versionData.uint16(at: 0)
        guard protocolVersion == ProtocolFrame.version else { throw PairingPayloadError.malformed }
        let expiryData = try take(8); let seconds = expiryData.uint64(at: 0)
        guard seconds <= UInt64(Int64.max), let expiry = Date(timeIntervalSince1970: TimeInterval(seconds)) as Date? else { throw PairingPayloadError.malformed }
        let hostLength = Int(try byte()); let hostData = try take(hostLength)
        guard !hostData.isEmpty, let endpoint = String(data: hostData, encoding: .utf8) else { throw PairingPayloadError.malformed }
        let portData = try take(2); let port = portData.uint16(at: 0); guard port > 0 else { throw PairingPayloadError.malformed }
        let secret = try take(32); let fingerprint = try take(32)
        let flags = try byte(); guard flags & ~1 == 0 else { throw PairingPayloadError.malformed }
        let remote: RemoteEndpoint?
        if flags == 1 {
            let length = Int(try byte()); let host = try take(length); let remotePort = try take(2).uint16(at: 0)
            guard !host.isEmpty, let remoteHost = String(data: host, encoding: .utf8), remotePort > 0 else { throw PairingPayloadError.malformed }
            remote = RemoteEndpoint(host: remoteHost, port: remotePort)
        } else { remote = nil }
        guard offset == data.count else { throw PairingPayloadError.malformed }
        return PairingTicket(endpoint: endpoint, port: port, expiresAt: expiry, oneTimeSecret: base64URLEncode(secret), daemonCertificateFingerprint: fingerprint.map { String(format: "%02x", $0) }.joined(), remoteEndpoint: remote, protocolVersion: protocolVersion)
    }

    private static func base45Encode(_ data: Data) -> String {
        var result = ""; var index = data.startIndex
        while index < data.endIndex {
            let first = Int(data[index]); index += 1
            if index < data.endIndex {
                let value = first * 256 + Int(data[index]); index += 1
                result.append(base45Alphabet[value % 45]); result.append(base45Alphabet[(value / 45) % 45]); result.append(base45Alphabet[value / 2025])
            } else { result.append(base45Alphabet[first % 45]); result.append(base45Alphabet[first / 45]) }
        }
        return result
    }

    private static func base45Decode(_ text: String) throws -> Data {
        let values = try text.map { character -> Int in guard let value = base45Alphabet.firstIndex(of: character) else { throw PairingPayloadError.malformed }; return value }
        guard !values.isEmpty, values.count % 3 != 1 else { throw PairingPayloadError.malformed }
        var data = Data(); var index = 0
        while index < values.count {
            if index + 2 < values.count {
                let value = values[index] + values[index + 1] * 45 + values[index + 2] * 2025
                guard value <= 0xffff else { throw PairingPayloadError.malformed }; data.append(UInt8(value / 256)); data.append(UInt8(value % 256)); index += 3
            } else {
                let value = values[index] + values[index + 1] * 45
                guard value <= 0xff else { throw PairingPayloadError.malformed }; data.append(UInt8(value)); index += 2
            }
        }
        return data
    }

    private static func base64URLEncode(_ data: Data) -> String { data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
    private static func base64URLDecode(_ value: String) -> Data? {
        let padded = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + String(repeating: "=", count: (4 - value.count % 4) % 4)
        return Data(base64Encoded: padded)
    }
    private static func hexDecode(_ value: String) -> Data? {
        guard value.count == 64 else { return nil }; var data = Data(); var index = value.startIndex
        while index < value.endIndex { let end = value.index(index, offsetBy: 2); guard let byte = UInt8(value[index..<end], radix: 16) else { return nil }; data.append(byte); index = end }
        return data
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
    private let rendezvousCapability: RendezvousCapability?
    private let approval: @Sendable (PairingRequest) async -> Bool
    private let didPair: @Sendable () async -> Void
    private var requestInProgress = false

    public init(secret: PairingSecret, trustStore: TrustStore, macID: String, displayName: String, serviceID: String, macCertificate: Data, rendezvousCapability: RendezvousCapability? = nil, approval: @escaping @Sendable (PairingRequest) async -> Bool, didPair: @escaping @Sendable () async -> Void = {}) {
        self.secret = secret
        self.trustStore = trustStore
        self.macID = macID
        self.macCertificate = macCertificate
        self.displayName = displayName
        self.serviceID = serviceID
        self.rendezvousCapability = rendezvousCapability
        self.approval = approval
        self.didPair = didPair
    }

    public func accept(_ request: PairingRequest, now: Date = .now) async throws -> PairingAcceptance {
        guard !requestInProgress else { throw PairingError.consumed }
        requestInProgress = true
        defer { requestInProgress = false }
        try await secret.validate(request: request, now: now)
        guard await approval(request) else { throw PairingError.rejected }
        let device = PairedDevice(id: request.deviceID, displayName: request.deviceName, certificateFingerprint: Fingerprint.sha256(of: request.certificate), createdAt: now, certificate: request.certificate, rendezvousCapability: request.rendezvousCapability)
        try await trustStore.upsert(device)
        try await secret.consume(secret: request.oneTimeSecret, now: now)
        await didPair()
        return PairingAcceptance(macID: macID, displayName: displayName, serviceID: serviceID, certificate: macCertificate, rendezvousCapability: rendezvousCapability)
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
    public let certificate: Data?
    public let rendezvousCapability: RendezvousCapability?

    public init(id: String, displayName: String, certificateFingerprint: String, createdAt: Date, certificate: Data? = nil, rendezvousCapability: RendezvousCapability? = nil) {
        self.id = id; self.displayName = displayName
        self.certificateFingerprint = certificateFingerprint; self.createdAt = createdAt
        self.certificate = certificate; self.rendezvousCapability = rendezvousCapability
    }
}


public struct PairedMac: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let displayName: String
    public let serviceID: String
    public let certificateFingerprint: String
    public let createdAt: Date
    public let remoteEndpoint: RemoteEndpoint?
    public let certificate: Data?
    public let rendezvousCapability: RendezvousCapability?

    public init(id: String, displayName: String, serviceID: String, certificateFingerprint: String, createdAt: Date, remoteEndpoint: RemoteEndpoint? = nil, certificate: Data? = nil, rendezvousCapability: RendezvousCapability? = nil) {
        self.id = id; self.displayName = displayName; self.serviceID = serviceID
        self.certificateFingerprint = certificateFingerprint; self.createdAt = createdAt
        self.remoteEndpoint = remoteEndpoint
        self.certificate = certificate; self.rendezvousCapability = rendezvousCapability
    }
}

public typealias PairedDevice = PairedIPhone

public enum Fingerprint {
    public static func sha256(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
