import Foundation

public enum ProtocolError: Error, Equatable, Sendable {
    case unsupportedVersion(UInt16)
    case malformedFrame
    case frameTooLarge(Int)
    case unknownMandatoryFrame(UInt8)
}

public enum FrameKind: UInt8, Sendable, CaseIterable {
    case sessionOpen = 0x01
    case sessionClose = 0x02
    case terminalInput = 0x03
    case terminalOutput = 0x04
    case terminalResize = 0x05
    case sessionError = 0x06
    case pairingRequest = 0x10
    case pairingAccept = 0x11
    case sessionOpened = 0x12
    case pairingRevoke = 0x13
    case pairingRevoked = 0x14
    case reachabilityProbe = 0x15
    case reachabilityVerified = 0x16
    case sessionList = 0x20
    case sessionListResult = 0x21
    case sessionAttach = 0x22
    case attachmentState = 0x23
    case resizeClaim = 0x24
    case sessionTerminate = 0x25
    case sessionTerminateMany = 0x26
    case sessionTerminateManyResult = 0x27
}

public enum AttachmentKind: String, Codable, Equatable, Sendable { case iPhone, macCLI }

public enum SessionKind: String, Codable, Equatable, Sendable { case shell, codex }

public struct SessionDescriptor: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let kind: SessionKind
    public let label: String?
    public let attachmentCount: Int
    public let resizeOwner: AttachmentKind?
    public let outputOffset: UInt64
    public init(id: UUID, kind: SessionKind = .shell, label: String? = nil, attachmentCount: Int, resizeOwner: AttachmentKind?, outputOffset: UInt64) {
        self.id = id; self.kind = kind; self.label = label; self.attachmentCount = attachmentCount
        self.resizeOwner = resizeOwner; self.outputOffset = outputOffset
    }

    private enum CodingKeys: String, CodingKey { case id, kind, label, attachmentCount, resizeOwner, outputOffset }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        kind = try values.decodeIfPresent(SessionKind.self, forKey: .kind) ?? .shell
        label = try values.decodeIfPresent(String.self, forKey: .label)
        attachmentCount = try values.decode(Int.self, forKey: .attachmentCount)
        resizeOwner = try values.decodeIfPresent(AttachmentKind.self, forKey: .resizeOwner)
        outputOffset = try values.decode(UInt64.self, forKey: .outputOffset)
    }
}

public struct SessionListRequest: Codable, Equatable, Sendable {
    public let wanGateToken: Data?
    public init(wanGateToken: Data? = nil) { self.wanGateToken = wanGateToken }
}
public struct SessionListResult: Codable, Equatable, Sendable {
    public let sessions: [SessionDescriptor]
    public init(sessions: [SessionDescriptor]) { self.sessions = sessions }
}
public struct SessionTerminateManyRequest: Codable, Equatable, Sendable {
    public static let maximumSessionCount = 256
    public let sessionIDs: [UUID]
    public init(sessionIDs: [UUID]) { self.sessionIDs = sessionIDs }
    public var isValid: Bool { !sessionIDs.isEmpty && sessionIDs.count <= Self.maximumSessionCount }
}
public struct SessionTerminateManyResult: Codable, Equatable, Sendable {
    public let terminatedSessionIDs: [UUID]
    public init(terminatedSessionIDs: [UUID]) { self.terminatedSessionIDs = terminatedSessionIDs }
}
public struct SessionAttachRequest: Codable, Equatable, Sendable {
    public let serverSessionID: UUID
    public let lastReceivedOffset: UInt64
    public let attachmentKind: AttachmentKind
    public let initialSize: TerminalSize
    public let wanGateToken: Data?
    public init(serverSessionID: UUID, lastReceivedOffset: UInt64 = 0, attachmentKind: AttachmentKind, initialSize: TerminalSize, wanGateToken: Data? = nil) {
        self.serverSessionID = serverSessionID; self.lastReceivedOffset = lastReceivedOffset
        self.attachmentKind = attachmentKind; self.initialSize = initialSize; self.wanGateToken = wanGateToken
    }
}
public struct AttachmentState: Codable, Equatable, Sendable {
    public let sessionID: UUID
    public let attachmentCount: Int
    public let resizeOwner: AttachmentKind?
    public let outputOffset: UInt64
    public init(sessionID: UUID, attachmentCount: Int, resizeOwner: AttachmentKind?, outputOffset: UInt64) {
        self.sessionID = sessionID; self.attachmentCount = attachmentCount
        self.resizeOwner = resizeOwner; self.outputOffset = outputOffset
    }
}
public struct TerminalOutputChunk: Codable, Equatable, Sendable {
    public let offset: UInt64
    public let bytes: Data
    public init(offset: UInt64, bytes: Data) { self.offset = offset; self.bytes = bytes }
    public var endOffset: UInt64 { offset + UInt64(bytes.count) }
}

public struct ReachabilityProbe: Codable, Equatable, Sendable {
    public let challenge: UUID
    public let wanGateToken: Data
    public init(challenge: UUID, wanGateToken: Data) { self.challenge = challenge; self.wanGateToken = wanGateToken }
}

public struct ReachabilityVerified: Codable, Equatable, Sendable {
    public let challenge: UUID
    public init(challenge: UUID) { self.challenge = challenge }
}

public struct SessionOpenRequest: Codable, Equatable, Sendable {
    /// Stable across reconnects. It identifies a workspace shell, not a daemon PTY.
    public let clientSessionID: UUID
    public let initialSize: TerminalSize
    public let rendezvousCapability: RendezvousCapability?
    public let wanGateToken: Data?
    public let workingDirectory: String?
    public let lastReceivedOffset: UInt64
    public let attachmentKind: AttachmentKind
    public init(clientSessionID: UUID, initialSize: TerminalSize, rendezvousCapability: RendezvousCapability? = nil, wanGateToken: Data? = nil, workingDirectory: String? = nil, lastReceivedOffset: UInt64 = 0, attachmentKind: AttachmentKind = .iPhone) {
        self.clientSessionID = clientSessionID
        self.initialSize = initialSize
        self.rendezvousCapability = rendezvousCapability
        self.wanGateToken = wanGateToken
        self.workingDirectory = workingDirectory
        self.lastReceivedOffset = lastReceivedOffset; self.attachmentKind = attachmentKind
    }

    private enum CodingKeys: String, CodingKey { case clientSessionID, initialSize, rendezvousCapability, wanGateToken, workingDirectory, lastReceivedOffset, attachmentKind }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        clientSessionID = try values.decode(UUID.self, forKey: .clientSessionID)
        initialSize = try values.decode(TerminalSize.self, forKey: .initialSize)
        rendezvousCapability = try values.decodeIfPresent(RendezvousCapability.self, forKey: .rendezvousCapability)
        wanGateToken = try values.decodeIfPresent(Data.self, forKey: .wanGateToken)
        workingDirectory = try values.decodeIfPresent(String.self, forKey: .workingDirectory)
        lastReceivedOffset = try values.decode(UInt64.self, forKey: .lastReceivedOffset)
        attachmentKind = try values.decode(AttachmentKind.self, forKey: .attachmentKind)
    }
}

public struct SessionOpened: Codable, Equatable, Sendable {
    public enum Disposition: String, Codable, Sendable { case created, resumed }
    /// Ephemeral ID allocated by the daemon for this particular PTY.
    public let serverSessionID: UUID
    public let rendezvousCapability: RendezvousCapability?
    public let disposition: Disposition
    public let replayTruncated: Bool
    public init(serverSessionID: UUID, rendezvousCapability: RendezvousCapability? = nil, disposition: Disposition = .created, replayTruncated: Bool = false) {
        self.serverSessionID = serverSessionID
        self.rendezvousCapability = rendezvousCapability
        self.disposition = disposition
        self.replayTruncated = replayTruncated
    }

    private enum CodingKeys: String, CodingKey { case serverSessionID, rendezvousCapability, disposition, replayTruncated }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        serverSessionID = try values.decode(UUID.self, forKey: .serverSessionID)
        rendezvousCapability = try values.decodeIfPresent(RendezvousCapability.self, forKey: .rendezvousCapability)
        disposition = try values.decode(Disposition.self, forKey: .disposition)
        replayTruncated = try values.decode(Bool.self, forKey: .replayTruncated)
    }
}

public struct SessionError: Codable, Equatable, Sendable {
    public enum Code: String, Codable, Sendable {
        case authenticationFailed, invalidFrameOrder, shellCreationFailed, workingDirectoryUnavailable, revoked, protocolError
        case sessionUnavailable, slowConsumer
    }
    public let code: Code
    public let message: String
    public init(code: Code, message: String) { self.code = code; self.message = message }
}

public struct TerminalSize: Codable, Equatable, Sendable {
    public let columns: UInt16
    public let rows: UInt16

    public init(columns: UInt16, rows: UInt16) {
        self.columns = columns
        self.rows = rows
    }

    public var isValid: Bool { columns > 0 && rows > 0 }
}

public struct ProtocolFrame: Equatable, Sendable {
    public static let version: UInt16 = 3
    public static let defaultMaximumPayloadSize = 1_048_576

    public let version: UInt16
    public let kind: FrameKind
    public let payload: Data

    public init(version: UInt16 = ProtocolFrame.version, kind: FrameKind, payload: Data = Data()) {
        self.version = version
        self.kind = kind
        self.payload = payload
    }

    public func encoded(maximumPayloadSize: Int = defaultMaximumPayloadSize) throws -> Data {
        guard payload.count <= maximumPayloadSize else { throw ProtocolError.frameTooLarge(payload.count) }
        var data = Data()
        data.appendUInt32(UInt32(payload.count + 3))
        data.appendUInt16(version)
        data.append(kind.rawValue)
        data.append(payload)
        return data
    }
}

public struct FrameDecoder: Sendable {
    private var buffer = Data()
    private let maximumPayloadSize: Int

    public init(maximumPayloadSize: Int = ProtocolFrame.defaultMaximumPayloadSize) {
        self.maximumPayloadSize = maximumPayloadSize
    }

    public mutating func append(_ data: Data) throws -> [ProtocolFrame] {
        buffer.append(data)
        var frames: [ProtocolFrame] = []
        while buffer.count >= 4 {
            let bodyLength = Int(buffer.uint32(at: 0))
            guard bodyLength >= 3 else { throw ProtocolError.malformedFrame }
            guard bodyLength - 3 <= maximumPayloadSize else { throw ProtocolError.frameTooLarge(bodyLength - 3) }
            guard buffer.count >= bodyLength + 4 else { break }
            let version = buffer.uint16(at: 4)
            guard version == ProtocolFrame.version else { throw ProtocolError.unsupportedVersion(version) }
            guard let kind = FrameKind(rawValue: buffer[6]) else { throw ProtocolError.unknownMandatoryFrame(buffer[6]) }
            let payload = buffer.subdata(in: 7..<(4 + bodyLength))
            frames.append(ProtocolFrame(version: version, kind: kind, payload: payload))
            buffer.removeSubrange(0..<(4 + bodyLength))
        }
        return frames
    }
}

public extension Data {
    mutating func appendUInt16(_ value: UInt16) {
        append(contentsOf: [UInt8(value >> 8), UInt8(value & 0xff)])
    }

    mutating func appendUInt32(_ value: UInt32) {
        append(contentsOf: [UInt8(value >> 24), UInt8((value >> 16) & 0xff), UInt8((value >> 8) & 0xff), UInt8(value & 0xff)])
    }

    mutating func appendUInt64(_ value: UInt64) {
        append(contentsOf: (0..<8).reversed().map { UInt8((value >> UInt64($0 * 8)) & 0xff) })
    }

    func uint16(at offset: Int) -> UInt16 {
        (UInt16(self[offset]) << 8) | UInt16(self[offset + 1])
    }

    func uint32(at offset: Int) -> UInt32 {
        (UInt32(self[offset]) << 24) | (UInt32(self[offset + 1]) << 16) | (UInt32(self[offset + 2]) << 8) | UInt32(self[offset + 3])
    }

    func uint64(at offset: Int) -> UInt64 {
        (0..<8).reduce(0) { ($0 << 8) | UInt64(self[offset + $1]) }
    }
}
