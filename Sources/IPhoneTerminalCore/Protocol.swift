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
}

public struct SessionOpenRequest: Codable, Equatable, Sendable {
    /// Stable across reconnects. It identifies a workspace shell, not a daemon PTY.
    public let clientSessionID: UUID
    public let initialSize: TerminalSize
    public init(clientSessionID: UUID, initialSize: TerminalSize) {
        self.clientSessionID = clientSessionID
        self.initialSize = initialSize
    }
}

public struct SessionOpened: Codable, Equatable, Sendable {
    /// Ephemeral ID allocated by the daemon for this particular PTY.
    public let serverSessionID: UUID
    public init(serverSessionID: UUID) { self.serverSessionID = serverSessionID }
}

public struct SessionError: Codable, Equatable, Sendable {
    public enum Code: String, Codable, Sendable {
        case authenticationFailed, invalidFrameOrder, shellCreationFailed, revoked, protocolError
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
    public static let version: UInt16 = 2
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

    func uint16(at offset: Int) -> UInt16 {
        (UInt16(self[offset]) << 8) | UInt16(self[offset + 1])
    }

    func uint32(at offset: Int) -> UInt32 {
        (UInt32(self[offset]) << 24) | (UInt32(self[offset + 1]) << 16) | (UInt32(self[offset + 2]) << 8) | UInt32(self[offset + 3])
    }
}
