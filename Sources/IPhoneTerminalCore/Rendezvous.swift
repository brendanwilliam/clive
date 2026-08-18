import Crypto
import Foundation

public enum RendezvousError: Error, Equatable, Sendable {
    case invalidEnvelope, invalidSignature, wrongRecipient, expired, replayed, unsupportedVersion
}

public struct RendezvousPublicKeys: Codable, Equatable, Sendable {
    public let agreement: Data
    public let signing: Data
    public init(agreement: Data, signing: Data) { self.agreement = agreement; self.signing = signing }
}

public struct RendezvousCapability: Codable, Equatable, Sendable {
    public let keys: RendezvousPublicKeys
    public let accountBinding: String
    public init(keys: RendezvousPublicKeys, accountBinding: String) { self.keys = keys; self.accountBinding = accountBinding }
}

public struct RendezvousKeyPair: Equatable, Sendable {
    public let agreementPrivateKey: Data
    public let signingPrivateKey: Data

    public init() {
        agreementPrivateKey = P256.KeyAgreement.PrivateKey().rawRepresentation
        signingPrivateKey = P256.Signing.PrivateKey().rawRepresentation
    }

    public init(agreementPrivateKey: Data, signingPrivateKey: Data) throws {
        _ = try P256.KeyAgreement.PrivateKey(rawRepresentation: agreementPrivateKey)
        _ = try P256.Signing.PrivateKey(rawRepresentation: signingPrivateKey)
        self.agreementPrivateKey = agreementPrivateKey
        self.signingPrivateKey = signingPrivateKey
    }

    public var publicKeys: RendezvousPublicKeys {
        get throws {
            let agreement = try P256.KeyAgreement.PrivateKey(rawRepresentation: agreementPrivateKey)
            let signing = try P256.Signing.PrivateKey(rawRepresentation: signingPrivateKey)
            return RendezvousPublicKeys(agreement: agreement.publicKey.x963Representation, signing: signing.publicKey.x963Representation)
        }
    }
}

public enum RendezvousEndpointKind: String, Codable, Sendable { case publicIPv6, manualPublicEndpoint }

public struct RendezvousEndpoint: Codable, Equatable, Sendable {
    public let host: String
    public let port: UInt16
    public let kind: RendezvousEndpointKind
    public init(host: String, port: UInt16, kind: RendezvousEndpointKind) { self.host = host; self.port = port; self.kind = kind }
}

public struct RendezvousAdvertisement: Codable, Equatable, Sendable {
    public let generation: UUID
    public let gateToken: Data
    public let endpoints: [RendezvousEndpoint]
    public init(generation: UUID, gateToken: Data, endpoints: [RendezvousEndpoint]) { self.generation = generation; self.gateToken = gateToken; self.endpoints = endpoints }
}

public struct RendezvousReachabilityHint: Codable, Equatable, Sendable {
    public let requestID: UUID
    public init(requestID: UUID = UUID()) { self.requestID = requestID }
}

public struct WANGateRegistry: Sendable {
    private struct Entry: Sendable { let token: Data; let expiresAt: Date }
    private var entries: [String: Entry] = [:]
    public init() {}
    public mutating func issue(deviceID: String, token: Data, expiresAt: Date) { entries[deviceID] = Entry(token: token, expiresAt: expiresAt) }
    public mutating func revoke(deviceID: String) { entries.removeValue(forKey: deviceID) }
    public mutating func invalidateAll() { entries.removeAll() }
    public func validate(deviceID: String, token: Data?, now: Date = .now) -> Bool {
        guard let token, let entry = entries[deviceID], now <= entry.expiresAt else { return false }
        return entry.token == token
    }
}

public struct RendezvousEnvelope: Codable, Equatable, Sendable {
    public static let currentVersion: UInt16 = 1
    public let version: UInt16
    public let senderID: String
    public let recipientID: String
    public let sequence: UInt64
    public let issuedAt: Date
    public let expiresAt: Date
    public let ephemeralPublicKey: Data
    public let ciphertext: Data
    public let signature: Data

    public init(version: UInt16 = currentVersion, senderID: String, recipientID: String, sequence: UInt64, issuedAt: Date, expiresAt: Date, ephemeralPublicKey: Data, ciphertext: Data, signature: Data) {
        self.version = version; self.senderID = senderID; self.recipientID = recipientID
        self.sequence = sequence; self.issuedAt = issuedAt; self.expiresAt = expiresAt
        self.ephemeralPublicKey = ephemeralPublicKey; self.ciphertext = ciphertext; self.signature = signature
    }
}

public enum RendezvousCrypto {
    public static let maximumEnvelopeSize = 64 * 1024

    public static func accountBinding(containerIdentifier: String, userRecordName: String) -> String {
        hexDigest(Data("\(containerIdentifier)\u{0}\(userRecordName)".utf8))
    }

    public static func recordName(macID: String, deviceID: String, purpose: String) -> String {
        hexDigest(Data("\(purpose)\u{0}\(macID)\u{0}\(deviceID)".utf8))
    }

    public static func seal<Payload: Encodable>(_ payload: Payload, senderID: String, recipientID: String, sequence: UInt64, issuedAt: Date = .now, expiresAt: Date, recipientAgreementKey: Data, senderSigningKey: Data) throws -> RendezvousEnvelope {
        let recipient = try P256.KeyAgreement.PublicKey(x963Representation: recipientAgreementKey)
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let header = EnvelopeHeader(version: RendezvousEnvelope.currentVersion, senderID: senderID, recipientID: recipientID, sequence: sequence, issuedAt: issuedAt, expiresAt: expiresAt, ephemeralPublicKey: ephemeral.publicKey.x963Representation)
        let headerData = try encode(header)
        let secret = try ephemeral.sharedSecretFromKeyAgreement(with: recipient)
        let key = secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data("iphone-terminal-rendezvous-v1".utf8), sharedInfo: headerData, outputByteCount: 32)
        let box = try AES.GCM.seal(try encode(payload), using: key, authenticating: headerData)
        guard let ciphertext = box.combined else { throw RendezvousError.invalidEnvelope }
        let unsigned = UnsignedEnvelope(header: header, ciphertext: ciphertext)
        let signer = try P256.Signing.PrivateKey(rawRepresentation: senderSigningKey)
        let signature = try signer.signature(for: encode(unsigned)).derRepresentation
        let envelope = RendezvousEnvelope(senderID: senderID, recipientID: recipientID, sequence: sequence, issuedAt: issuedAt, expiresAt: expiresAt, ephemeralPublicKey: header.ephemeralPublicKey, ciphertext: ciphertext, signature: signature)
        guard try encode(envelope).count <= maximumEnvelopeSize else { throw RendezvousError.invalidEnvelope }
        return envelope
    }

    public static func open<Payload: Decodable>(_ envelope: RendezvousEnvelope, as: Payload.Type, recipientID: String, recipientAgreementKey: Data, senderSigningKey: Data, minimumSequence: UInt64? = nil, now: Date = .now) throws -> Payload {
        guard envelope.version == RendezvousEnvelope.currentVersion else { throw RendezvousError.unsupportedVersion }
        guard envelope.recipientID == recipientID else { throw RendezvousError.wrongRecipient }
        guard envelope.issuedAt <= now, now <= envelope.expiresAt else { throw RendezvousError.expired }
        if let minimumSequence, envelope.sequence <= minimumSequence { throw RendezvousError.replayed }
        guard try encode(envelope).count <= maximumEnvelopeSize else { throw RendezvousError.invalidEnvelope }
        let header = EnvelopeHeader(envelope)
        let unsigned = UnsignedEnvelope(header: header, ciphertext: envelope.ciphertext)
        let signer = try P256.Signing.PublicKey(x963Representation: senderSigningKey)
        let signature = try P256.Signing.ECDSASignature(derRepresentation: envelope.signature)
        guard signer.isValidSignature(signature, for: try encode(unsigned)) else { throw RendezvousError.invalidSignature }
        let ephemeral = try P256.KeyAgreement.PublicKey(x963Representation: envelope.ephemeralPublicKey)
        let recipient = try P256.KeyAgreement.PrivateKey(rawRepresentation: recipientAgreementKey)
        let headerData = try encode(header)
        let secret = try recipient.sharedSecretFromKeyAgreement(with: ephemeral)
        let key = secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data("iphone-terminal-rendezvous-v1".utf8), sharedInfo: headerData, outputByteCount: 32)
        let box = try AES.GCM.SealedBox(combined: envelope.ciphertext)
        return try JSONDecoder().decode(Payload.self, from: AES.GCM.open(box, using: key, authenticating: headerData))
    }

    private static func hexDigest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func encode<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970; encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
}

private struct EnvelopeHeader: Codable {
    let version: UInt16; let senderID: String; let recipientID: String; let sequence: UInt64
    let issuedAt: Date; let expiresAt: Date; let ephemeralPublicKey: Data
    init(version: UInt16, senderID: String, recipientID: String, sequence: UInt64, issuedAt: Date, expiresAt: Date, ephemeralPublicKey: Data) {
        self.version = version; self.senderID = senderID; self.recipientID = recipientID; self.sequence = sequence
        self.issuedAt = issuedAt; self.expiresAt = expiresAt; self.ephemeralPublicKey = ephemeralPublicKey
    }
    init(_ envelope: RendezvousEnvelope) { self.init(version: envelope.version, senderID: envelope.senderID, recipientID: envelope.recipientID, sequence: envelope.sequence, issuedAt: envelope.issuedAt, expiresAt: envelope.expiresAt, ephemeralPublicKey: envelope.ephemeralPublicKey) }
}

private struct UnsignedEnvelope: Codable { let header: EnvelopeHeader; let ciphertext: Data }
