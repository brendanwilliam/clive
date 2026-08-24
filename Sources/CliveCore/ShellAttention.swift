import Crypto
import Foundation

/// Authenticates the minimal state emitted by the optional Bash/Zsh prompt
/// integration. It deliberately has no terminal-text parser: a marker is
/// accepted only when its MAC and strictly increasing sequence both verify.
public struct SessionAttentionAuthenticator: Sendable {
    public let capability: Data

    public init(capability: Data) {
        precondition(capability.count >= 16, "Attention capabilities must be unguessable")
        self.capability = capability
    }

    public func tag(sessionID: UUID, sequence: UInt64, requiresAttention: Bool) -> Data {
        var message = Data(sessionID.uuidString.utf8)
        message.append(0)
        message.appendUInt64(sequence)
        message.append(requiresAttention ? 1 : 0)
        return Data(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: capability)))
    }

    public func validates(_ marker: SessionAttentionMarker) -> Bool {
        let expected = tag(sessionID: marker.sessionID, sequence: marker.sequence, requiresAttention: marker.requiresAttention)
        return expected.count == marker.authenticationTag.count &&
            expected.withUnsafeBytes { expectedBytes in
                marker.authenticationTag.withUnsafeBytes { actualBytes in
                    safeCompare(expectedBytes, actualBytes)
                }
            }
    }

    private func safeCompare(_ lhs: UnsafeRawBufferPointer, _ rhs: UnsafeRawBufferPointer) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for index in 0..<lhs.count { difference |= lhs[index] ^ rhs[index] }
        return difference == 0
    }
}
