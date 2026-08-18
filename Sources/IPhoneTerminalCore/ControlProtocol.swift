import Foundation

public enum ControlCommand: String, Codable, Sendable {
    case pair, status, revoke, stop, approvePairing
}

public struct ControlRequest: Codable, Equatable, Sendable {
    public let command: ControlCommand
    public let deviceID: String?
    public let approved: Bool?

    public init(command: ControlCommand, deviceID: String? = nil, approved: Bool? = nil) {
        self.command = command
        self.deviceID = deviceID
        self.approved = approved
    }
}

public struct ControlDevice: Codable, Equatable, Sendable {
    public let id: String
    public let displayName: String
    public let certificateFingerprint: String
    public let activeSessionCount: Int

    public init(id: String, displayName: String, certificateFingerprint: String, activeSessionCount: Int) {
        self.id = id
        self.displayName = displayName
        self.certificateFingerprint = certificateFingerprint
        self.activeSessionCount = activeSessionCount
    }
}

public struct PairingPrompt: Codable, Equatable, Sendable {
    public let deviceID: String
    public let displayName: String
    public let certificateFingerprint: String

    public init(deviceID: String, displayName: String, certificateFingerprint: String) {
        self.deviceID = deviceID
        self.displayName = displayName
        self.certificateFingerprint = certificateFingerprint
    }
}

public struct ControlResponse: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case result, pairingTicket, pairingPrompt }
    public let kind: Kind
    public let success: Bool
    public let message: String?
    public let devices: [ControlDevice]?
    public let pairingTicket: PairingTicket?
    public let pairingPrompt: PairingPrompt?

    public init(kind: Kind = .result, success: Bool, message: String? = nil, devices: [ControlDevice]? = nil, pairingTicket: PairingTicket? = nil, pairingPrompt: PairingPrompt? = nil) {
        self.kind = kind
        self.success = success
        self.message = message
        self.devices = devices
        self.pairingTicket = pairingTicket
        self.pairingPrompt = pairingPrompt
    }
}

public enum ControlCodec {
    public static let maximumMessageSize = 64 * 1024

    public static func encode<Value: Encodable>(_ value: Value) throws -> Data {
        var data = try JSONEncoder().encode(value)
        guard data.count < maximumMessageSize else { throw ProtocolError.frameTooLarge(data.count) }
        data.append(0x0a)
        return data
    }
}
