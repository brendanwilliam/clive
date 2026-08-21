import Foundation

public enum ControlCommand: String, Codable, Sendable {
    case pair, status, revoke, stop, approvePairing, cancelPairing, setCellularAccess, configureCellular, beginCellularVerification
}

public enum CellularEndpointMode: String, Codable, Equatable, Sendable { case automatic, manual }

public struct CellularConfiguration: Codable, Equatable, Sendable {
    public let listenerPort: UInt16
    public let endpointMode: CellularEndpointMode
    public let manualEndpoint: RemoteEndpoint?
    public let allowsRouterMapping: Bool
    public init(listenerPort: UInt16 = 64236, endpointMode: CellularEndpointMode = .automatic, manualEndpoint: RemoteEndpoint? = nil, allowsRouterMapping: Bool = false) {
        self.listenerPort = listenerPort; self.endpointMode = endpointMode
        self.manualEndpoint = manualEndpoint; self.allowsRouterMapping = allowsRouterMapping
    }
}

public struct ControlRequest: Codable, Equatable, Sendable {
    public let command: ControlCommand
    public let deviceID: String?
    public let approved: Bool?
    public let cellularEnabled: Bool?
    public let manualEndpoint: RemoteEndpoint?
    public let cellularConfiguration: CellularConfiguration?

    public init(command: ControlCommand, deviceID: String? = nil, approved: Bool? = nil, cellularEnabled: Bool? = nil, manualEndpoint: RemoteEndpoint? = nil, cellularConfiguration: CellularConfiguration? = nil) {
        self.command = command
        self.deviceID = deviceID
        self.approved = approved
        self.cellularEnabled = cellularEnabled
        self.manualEndpoint = manualEndpoint
        self.cellularConfiguration = cellularConfiguration
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
    public let cellularStatus: CellularAccessStatus?

    public init(kind: Kind = .result, success: Bool, message: String? = nil, devices: [ControlDevice]? = nil, pairingTicket: PairingTicket? = nil, pairingPrompt: PairingPrompt? = nil, cellularStatus: CellularAccessStatus? = nil) {
        self.kind = kind
        self.success = success
        self.message = message
        self.devices = devices
        self.pairingTicket = pairingTicket
        self.pairingPrompt = pairingPrompt
        self.cellularStatus = cellularStatus
    }
}

public enum CellularAccessState: String, Codable, Equatable, Sendable { case disabled, preparing, verifying, available, configurationRequired, blocked }

public struct CellularAccessStatus: Codable, Equatable, Sendable {
    public let enabled: Bool
    public let state: CellularAccessState
    public let diagnostic: String?
    public let publishedUntil: Date?
    public let configuration: CellularConfiguration?
    public let advertisedEndpoint: RemoteEndpoint?
    public let verifiedAt: Date?
    public let mappingMethod: String?
    public init(enabled: Bool, state: CellularAccessState, diagnostic: String? = nil, publishedUntil: Date? = nil, configuration: CellularConfiguration? = nil, advertisedEndpoint: RemoteEndpoint? = nil, verifiedAt: Date? = nil, mappingMethod: String? = nil) {
        self.enabled = enabled; self.state = state; self.diagnostic = diagnostic; self.publishedUntil = publishedUntil
        self.configuration = configuration; self.advertisedEndpoint = advertisedEndpoint; self.verifiedAt = verifiedAt
        self.mappingMethod = mappingMethod
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
