#if os(iOS)
import ActivityKit
import Foundation

/// The complete public data contract for Clive's single Live Activity. Never
/// add terminal names, host information, commands, output, or credentials.
@available(iOS 17.0, *)
public struct CliveTerminalActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable, Sendable {
        public let activeTerminalCount: Int
        public let requiresAttention: Bool
        public let attentionTerminalID: UUID?

        public init(activeTerminalCount: Int, requiresAttention: Bool, attentionTerminalID: UUID?) {
            self.activeTerminalCount = max(0, activeTerminalCount)
            self.requiresAttention = requiresAttention
            self.attentionTerminalID = requiresAttention ? attentionTerminalID : nil
        }
    }

    public init() {}
}
#endif
