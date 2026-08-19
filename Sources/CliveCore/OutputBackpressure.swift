import Foundation

/// Accounts for bytes accepted by Network.framework without retaining terminal contents.
public struct OutputBackpressure: Equatable, Sendable {
    public static let defaultHighWaterMark = 256 * 1024
    public static let defaultLowWaterMark = 128 * 1024

    public private(set) var pendingBytes = 0
    public private(set) var isSuspended = false
    public let highWaterMark: Int
    public let lowWaterMark: Int

    public init(highWaterMark: Int = defaultHighWaterMark, lowWaterMark: Int = defaultLowWaterMark) {
        precondition(lowWaterMark >= 0 && lowWaterMark < highWaterMark)
        self.highWaterMark = highWaterMark
        self.lowWaterMark = lowWaterMark
    }

    @discardableResult public mutating func enqueue(_ count: Int) -> Bool {
        pendingBytes += max(0, count)
        if pendingBytes >= highWaterMark { isSuspended = true }
        return isSuspended
    }

    @discardableResult public mutating func complete(_ count: Int) -> Bool {
        pendingBytes = max(0, pendingBytes - max(0, count))
        if isSuspended && pendingBytes < lowWaterMark { isSuspended = false }
        return isSuspended
    }
}
